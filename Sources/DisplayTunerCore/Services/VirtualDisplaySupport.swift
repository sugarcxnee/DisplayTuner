import Foundation
import CoreGraphics
import Darwin
import ObjectiveC

/// 虚拟屏规格。
public struct VirtualDisplaySpec: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let refreshRate: Double

    public init(width: Int, height: Int, refreshRate: Double = 60) {
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
    }

    public var key: String { "\(width)x\(height)" }
    public var title: String { "\(width)×\(height)" }
    static let displayName = "DisplayTuner Virtual"
}

/// 运行中的虚拟屏句柄:持有私有对象引用(释放即销毁),记录 CGDisplayID。
public final class VirtualDisplayHandle {
    public let displayID: UInt32
    public let spec: VirtualDisplaySpec
    /// CGVirtualDisplay 实例;置 nil 即触发 ARC release → 虚拟屏拔出。
    var retainedObject: AnyObject?

    public var isDestroyed: Bool { retainedObject == nil }

    init(displayID: UInt32, spec: VirtualDisplaySpec, object: AnyObject) {
        self.displayID = displayID
        self.spec = spec
        self.retainedObject = object
    }
}

public enum VirtualDisplayError: Error, Equatable, CustomStringConvertible {
    /// CoreDisplay 私有类不可用(加载失败或系统移除)。
    case classesUnavailable([String])
    /// 私有创建步骤失败。
    case createFailed(String)
    /// 公共 CG API 激活目标模式失败。
    case activationFailed(String)
    /// 激活后验证失败。
    case verificationFailed(expected: String, actual: String)

    public var description: String {
        switch self {
        case .classesUnavailable(let missing):
            return "private virtual display classes unavailable: \(missing.joined(separator: ", "))"
        case .createFailed(let detail):
            return "virtual display creation failed: \(detail)"
        case .activationFailed(let detail):
            return "activating virtual display mode failed: \(detail)"
        case .verificationFailed(let expected, let actual):
            return "virtual display verification failed: expected \(expected), got \(actual)"
        }
    }
}

/// 私有类可用性报告。
public struct VirtualDisplayAvailability: Equatable, Sendable {
    public let isAvailable: Bool
    public let missingClasses: [String]

    public init(isAvailable: Bool, missingClasses: [String]) {
        self.isAvailable = isAvailable
        self.missingClasses = missingClasses
    }

    public var statusDescription: String {
        isAvailable ? "虚拟屏可用" : "虚拟屏不可用(缺少私有类)"
    }
}

/// 虚拟屏工厂协议。测试注入 Mock;生产实现走 CoreDisplay 私有类的 ObjC 运行时桥。
public protocol VirtualDisplayCreating: AnyObject {
    /// 只读探测:所需私有类是否已注册(无副作用)。
    func availability() -> VirtualDisplayAvailability
    /// 创建并激活虚拟屏。任何失败都不留残留对象。
    func create(spec: VirtualDisplaySpec) throws -> VirtualDisplayHandle
    /// 销毁虚拟屏(幂等)。
    func destroy(_ handle: VirtualDisplayHandle)
}

/// 基于 CoreDisplay 私有框架 `CGVirtualDisplay*` 类族的运行时实现。
///
/// 隔离规则(与 PrivateDisplayServices 同一原则):
/// - 不链接任何私有框架:先 dlopen CoreDisplay 使类注册,再 NSClassFromString 取类,
///   经 dlsym 得到的 `objc_msgSend` 动态派发;
/// - 所有私有调用收敛在本文件;**激活目标模式用公共 CG API**;
/// - 框架/类缺失时如实报告 unavailable,绝不编造能力。
public final class CoreDisplayVirtualDisplayFactory: VirtualDisplayCreating {

    public static let coreDisplayPath =
        "/System/Library/PrivateFrameworks/CoreDisplay.framework/CoreDisplay"
    static let requiredClasses = [
        "CGVirtualDisplayDescriptor",
        "CGVirtualDisplay",
        "CGVirtualDisplayMode",
        "CGVirtualDisplaySettings",
    ]

    private let frameworkLoader: (String) -> Bool
    private let logger: DTLogger
    private let queue: DispatchQueue
    private var frameworkLoaded = false

    /// - Parameters:
    ///   - frameworkLoader: 返回 false 时直接判定不可用(测试注入用)。
    public init(
        frameworkLoader: @escaping (String) -> Bool = { path in
            dlopen(path, RTLD_LAZY | RTLD_LOCAL) != nil
        },
        queue: DispatchQueue = .main,
        logger: DTLogger = DTLogger()
    ) {
        self.frameworkLoader = frameworkLoader
        self.queue = queue
        self.logger = logger
    }

    public func availability() -> VirtualDisplayAvailability {
        guard ensureFrameworkLoaded() else {
            return VirtualDisplayAvailability(isAvailable: false, missingClasses: Self.requiredClasses)
        }
        let missing = Self.requiredClasses.filter { NSClassFromString($0) == nil }
        return VirtualDisplayAvailability(isAvailable: missing.isEmpty, missingClasses: missing)
    }

    public func create(spec: VirtualDisplaySpec) throws -> VirtualDisplayHandle {
        let available = availability()
        guard available.isAvailable else {
            throw VirtualDisplayError.classesUnavailable(available.missingClasses)
        }

        var displayObject: AnyObject?
        do {
            let object = try buildDisplay(spec: spec)
            displayObject = object
            let displayID = try Self.activate(object: object, spec: spec)
            logger.info(
                "virtual display created: \(spec.key) (id \(displayID))",
                context: "VirtualDisplay"
            )
            return VirtualDisplayHandle(displayID: displayID, spec: spec, object: object)
        } catch {
            // 失败清理:不留半成品虚拟屏
            if let object = displayObject {
                var release: AnyObject? = object
                release = nil
            }
            logger.error("virtual display create failed: \(error)", context: "VirtualDisplay")
            throw error
        }
    }

    public func destroy(_ handle: VirtualDisplayHandle) {
        guard !handle.isDestroyed else { return }
        logger.info("destroying virtual display \(handle.spec.key) (id \(handle.displayID))", context: "VirtualDisplay")
        handle.retainedObject = nil
    }

    // MARK: - 私有创建流程

    private func ensureFrameworkLoaded() -> Bool {
        if frameworkLoaded { return true }
        frameworkLoaded = frameworkLoader(Self.coreDisplayPath)
        if !frameworkLoaded {
            logger.info("CoreDisplay private framework not loadable — virtual display unavailable", context: "VirtualDisplay")
        }
        return frameworkLoaded
    }

    private func buildDisplay(spec: VirtualDisplaySpec) throws -> AnyObject {
        let descriptor = try Self.instantiate("CGVirtualDisplayDescriptor")
        Self.send(descriptor, "setName:", VirtualDisplaySpec.displayName as NSString)
        Self.send(descriptor, "setMaxPixelsWide:", max(spec.width * 2, 4096))
        Self.send(descriptor, "setMaxPixelsHigh:", max(spec.height * 2, 4096))
        let mmHeight = 300.0 * Double(spec.height) / Double(spec.width)
        Self.send(descriptor, "setSizeInMillimeters:", NSSize(width: 300, height: mmHeight))
        Self.send(descriptor, "setProductID:", 0x9D9D)
        Self.send(descriptor, "setSerialNum:", Int(Date().timeIntervalSince1970) % 1_000_000_000)
        Self.send(descriptor, "setVendorID:", 0x0610)
        Self.send(descriptor, "setQueue:", queue)
        Self.send(descriptor, "setTerminationHandler:", { [logger] in
            logger.info("virtual display terminated by system", context: "VirtualDisplay")
        } as @convention(block) () -> Void)

        let display = try Self.sendObject(
            Self.alloc("CGVirtualDisplay"), "initWithDescriptor:", descriptor
        )

        let mode = try Self.sendObject(
            Self.alloc("CGVirtualDisplayMode"),
            "initWithWidth:height:refreshRate:",
            spec.width, spec.height, spec.refreshRate
        )
        let settings = try Self.instantiate("CGVirtualDisplaySettings")
        Self.send(settings, "setHiDPI:", false)
        Self.send(settings, "setModes:", [mode] as NSArray)

        guard Self.sendBool(display, "applySettings:", settings) else {
            throw VirtualDisplayError.createFailed("applySettings returned false")
        }
        return display
    }

    /// 用公共 CG API 激活目标模式并验证(实验验证的事实:applySettings 只定义模式表,
    /// 激活模式必须显式切换)。
    private static func activate(object: AnyObject, spec: VirtualDisplaySpec) throws -> UInt32 {
        // 轮询等待 WindowServer 分配 displayID
        var displayID: UInt32 = 0
        for _ in 0..<20 {
            displayID = sendU32(object, "displayID")
            if displayID != 0, CGDisplayCopyDisplayMode(displayID) != nil { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard displayID != 0 else {
            throw VirtualDisplayError.createFailed("displayID not assigned")
        }

        guard let modes = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode],
              let target = modes.first(where: {
                  Int($0.width) == spec.width && Int($0.height) == spec.height
              }) else {
            throw VirtualDisplayError.activationFailed("mode \(spec.key) not in virtual display mode list")
        }

        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success else {
            throw VirtualDisplayError.activationFailed("begin: \(begin.rawValue)")
        }
        let configure = CGConfigureDisplayWithDisplayMode(config, displayID, target, nil)
        guard configure == .success else {
            CGCancelDisplayConfiguration(config)
            throw VirtualDisplayError.activationFailed("configure: \(configure.rawValue)")
        }
        let complete = CGCompleteDisplayConfiguration(config, .permanently)
        guard complete == .success else {
            throw VirtualDisplayError.activationFailed("complete: \(complete.rawValue)")
        }

        guard let actual = CGDisplayCopyDisplayMode(displayID),
              Int(actual.width) == spec.width, Int(actual.height) == spec.height else {
            let actualKey = CGDisplayCopyDisplayMode(displayID)
                .map { "\($0.width)x\($0.height)" } ?? "<none>"
            throw VirtualDisplayError.verificationFailed(expected: spec.key, actual: actualKey)
        }
        return displayID
    }

    // MARK: - objc_msgSend 桥(签名固定,逐个声明)

    /// Swift 6 SDK 将 objc_msgSend 标记 unavailable,经 dlsym(libobjc)获取。
    private static let msgSendPtr: UnsafeMutableRawPointer = {
        let handle = dlopen("/usr/lib/libobjc.A.dylib", RTLD_LAZY | RTLD_LOCAL)!
        return dlsym(handle, "objc_msgSend")!
    }()

    private static func selector(_ name: String) -> Selector { NSSelectorFromString(name) }

    private static func send(_ target: AnyObject, _ name: String, _ arg: AnyObject) {
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        unsafeBitCast(msgSendPtr, to: Fn.self)(target, selector(name), arg)
    }
    private static func send(_ target: AnyObject, _ name: String, _ arg: Int) {
        typealias Fn = @convention(c) (AnyObject, Selector, Int) -> Void
        unsafeBitCast(msgSendPtr, to: Fn.self)(target, selector(name), arg)
    }
    private static func send(_ target: AnyObject, _ name: String, _ arg: Bool) {
        typealias Fn = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(msgSendPtr, to: Fn.self)(target, selector(name), arg)
    }
    private static func send(_ target: AnyObject, _ name: String, _ arg: NSSize) {
        typealias Fn = @convention(c) (AnyObject, Selector, NSSize) -> Void
        unsafeBitCast(msgSendPtr, to: Fn.self)(target, selector(name), arg)
    }
    private static func send(_ target: AnyObject, _ name: String, _ arg: DispatchQueue) {
        typealias Fn = @convention(c) (AnyObject, Selector, DispatchQueue) -> Void
        unsafeBitCast(msgSendPtr, to: Fn.self)(target, selector(name), arg)
    }
    private static func send(_ target: AnyObject, _ name: String, _ arg: (@convention(block) () -> Void)) {
        typealias Fn = @convention(c) (AnyObject, Selector, (@convention(block) () -> Void)) -> Void
        unsafeBitCast(msgSendPtr, to: Fn.self)(target, selector(name), arg)
    }
    private static func sendBool(_ target: AnyObject, _ name: String, _ arg: AnyObject) -> Bool {
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        return unsafeBitCast(msgSendPtr, to: Fn.self)(target, selector(name), arg)
    }
    private static func sendU32(_ target: AnyObject, _ name: String) -> UInt32 {
        typealias Fn = @convention(c) (AnyObject, Selector) -> UInt32
        return unsafeBitCast(msgSendPtr, to: Fn.self)(target, selector(name))
    }

    private static func alloc(_ className: String) throws -> AnyObject {
        guard let cls = NSClassFromString(className) else {
            throw VirtualDisplayError.classesUnavailable([className])
        }
        typealias Fn = @convention(c) (AnyObject, Selector) -> AnyObject?
        guard let allocated = unsafeBitCast(msgSendPtr, to: Fn.self)(cls as AnyObject, selector("alloc")) else {
            throw VirtualDisplayError.createFailed("\(className) alloc returned nil")
        }
        return allocated
    }
    private static func instantiate(_ className: String) throws -> AnyObject {
        let allocated = try alloc(className)
        typealias Fn = @convention(c) (AnyObject, Selector) -> AnyObject?
        guard let object = unsafeBitCast(msgSendPtr, to: Fn.self)(allocated, selector("init")) else {
            throw VirtualDisplayError.createFailed("\(className) init returned nil")
        }
        return object
    }
    private static func sendObject(_ target: AnyObject, _ name: String, _ arg: AnyObject) throws -> AnyObject {
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject) -> AnyObject?
        guard let object = unsafeBitCast(msgSendPtr, to: Fn.self)(target, selector(name), arg) else {
            throw VirtualDisplayError.createFailed("\(name) returned nil")
        }
        return object
    }
    private static func sendObject(
        _ target: AnyObject, _ name: String,
        _ w: Int, _ h: Int, _ r: Double
    ) throws -> AnyObject {
        typealias Fn = @convention(c) (AnyObject, Selector, Int, Int, Double) -> AnyObject?
        guard let object = unsafeBitCast(msgSendPtr, to: Fn.self)(target, selector(name), w, h, r) else {
            throw VirtualDisplayError.createFailed("\(name) returned nil")
        }
        return object
    }
}
