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
    /// 当前激活规格(切档后由工厂更新)。
    public internal(set) var activeSpec: VirtualDisplaySpec
    /// 创建时声明的完整模式表。系统会在镜像/切换后动态改写 CG 层的模式表
    /// (档位会消失/新增),切档时用它重新声明,保证目标档可用。
    let declaredModeTable: [VirtualDisplaySpec]
    /// CGVirtualDisplay 实例;置 nil 即触发 ARC release → 虚拟屏拔出。
    var retainedObject: AnyObject?

    public var isDestroyed: Bool { retainedObject == nil }

    init(
        displayID: UInt32,
        spec: VirtualDisplaySpec,
        declaredModeTable: [VirtualDisplaySpec],
        object: AnyObject
    ) {
        self.displayID = displayID
        self.activeSpec = spec
        self.declaredModeTable = declaredModeTable
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
    /// 创建并激活虚拟屏:`spec` 为首选档,`additionalModes` 一并注册进模式表,
    /// 之后可在表内任意切档。任何失败都不留残留对象。
    func create(spec: VirtualDisplaySpec, additionalModes: [VirtualDisplaySpec]) throws -> VirtualDisplayHandle
    /// 原地把虚拟屏切到模式表内的另一档(公共 CG API,无需重建)。
    func activateSpec(_ handle: VirtualDisplayHandle, spec: VirtualDisplaySpec) throws
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
    ///   - frameworkLoader: 显式加载框架的补救路径(类不可见时才使用;测试注入用)。
    public init(
        frameworkLoader: @escaping (String) -> Bool = { _ in
            // 新系统上框架实体不在磁盘、dyld 缓存也不按此路径注册,dlopen 可能失败;
            // 这不是错误 —— 类多半已由依赖链加载,availability 以类查找为准。
            let candidates = [
                CoreDisplayVirtualDisplayFactory.coreDisplayPath,
                "/System/Library/PrivateFrameworks/CoreDisplay.framework/Versions/A/CoreDisplay",
            ]
            return candidates.contains { dlopen($0, RTLD_LAZY | RTLD_LOCAL) != nil }
        },
        queue: DispatchQueue? = nil,
        logger: DTLogger = DTLogger()
    ) {
        self.frameworkLoader = frameworkLoader
        // 默认用独立串行队列:CGVirtualDisplay 的事件派发到 descriptor.queue,
        // 若用 main queue,创建/切档流程中主线程的轮询等待会阻塞它,
        // 模式表的发布会被卡住(真机表现为"not published within 3s")。
        self.queue = queue ?? DispatchQueue(label: "dev.displaytuner.virtualdisplay")
        self.logger = logger
    }

    public func availability() -> VirtualDisplayAvailability {
        // 类通常已通过进程依赖链加载(Foundation/AppKit 传递依赖 CoreDisplay),
        // dlopen 在新系统上反而会失败(框架实体不在磁盘、dyld 缓存按不同路径注册)。
        // 因此以类查找为准;dlopen 仅作为类不可见时的补救手段。
        let initiallyMissing = Self.requiredClasses.filter { NSClassFromString($0) == nil }
        if initiallyMissing.isEmpty {
            return VirtualDisplayAvailability(isAvailable: true, missingClasses: [])
        }

        // 类不全:尝试显式加载框架(旧系统磁盘有实体、或缓存命中)后复查
        if !ensureFrameworkLoaded() {
            return VirtualDisplayAvailability(isAvailable: false, missingClasses: initiallyMissing)
        }
        let stillMissing = Self.requiredClasses.filter { NSClassFromString($0) == nil }
        return VirtualDisplayAvailability(isAvailable: stillMissing.isEmpty, missingClasses: stillMissing)
    }

    public func create(spec: VirtualDisplaySpec, additionalModes: [VirtualDisplaySpec] = []) throws -> VirtualDisplayHandle {
        let available = availability()
        guard available.isAvailable else {
            throw VirtualDisplayError.classesUnavailable(available.missingClasses)
        }

        // WindowServer 对虚拟屏创建有冷却期(真机实测:销毁后 1 秒内的下一次创建,
        // 模式表可能迟迟不发布)—— 失败自动退避重试,消化"停止后立即再开"等场景。
        var lastError: Error = VirtualDisplayError.createFailed("unreachable")
        for attempt in 0..<3 {
            do {
                return try attemptCreate(spec: spec, additionalModes: additionalModes)
            } catch {
                lastError = error
                logger.info(
                    "create attempt \(attempt + 1) failed (\(error)); backing off before retry",
                    context: "VirtualDisplay"
                )
                if attempt < 2 {
                    Thread.sleep(forTimeInterval: 1.0 + Double(attempt) * 2.0)
                }
            }
        }
        throw lastError
    }

    private func attemptCreate(spec: VirtualDisplaySpec, additionalModes: [VirtualDisplaySpec]) throws -> VirtualDisplayHandle {
        var displayObject: AnyObject?
        do {
            let table = [spec] + additionalModes.filter { $0.key != spec.key }
            let object = try buildDisplay(table: table)
            displayObject = object
            let displayID = try Self.activate(object: object, spec: spec)
            logger.info(
                "virtual display created: \(spec.key) with \(table.count) mode(s) (id \(displayID))",
                context: "VirtualDisplay"
            )
            return VirtualDisplayHandle(
                displayID: displayID,
                spec: spec,
                declaredModeTable: table,
                object: object
            )
        } catch {
            // 失败清理:不留半成品虚拟屏
            if let object = displayObject {
                var release: AnyObject? = object
                release = nil
            }
            throw error
        }
    }

    public func destroy(_ handle: VirtualDisplayHandle) {
        guard !handle.isDestroyed else { return }
        logger.info("destroying virtual display \(handle.activeSpec.key) (id \(handle.displayID))", context: "VirtualDisplay")
        handle.retainedObject = nil
    }

    // MARK: - 私有创建流程

    private func ensureFrameworkLoaded() -> Bool {
        if frameworkLoaded { return true }
        frameworkLoaded = frameworkLoader(Self.coreDisplayPath)
        if !frameworkLoaded {
            logger.info("CoreDisplay not loadable via dlopen (normal on new macOS); falling back to class lookup", context: "VirtualDisplay")
        }
        return frameworkLoaded
    }

    private func buildDisplay(table: [VirtualDisplaySpec]) throws -> AnyObject {
        guard let preferred = table.first else {
            throw VirtualDisplayError.createFailed("empty mode table")
        }
        let descriptor = try Self.instantiate("CGVirtualDisplayDescriptor")
        Self.send(descriptor, "setName:", VirtualDisplaySpec.displayName as NSString)
        Self.send(descriptor, "setMaxPixelsWide:", max(preferred.width * 2, 4096))
        Self.send(descriptor, "setMaxPixelsHigh:", max(preferred.height * 2, 4096))
        let mmHeight = 300.0 * Double(preferred.height) / Double(preferred.width)
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

        let settings = try Self.buildSettings(preferred: preferred, table: table)
        guard Self.sendBool(display, "applySettings:", settings) else {
            throw VirtualDisplayError.createFailed("applySettings returned false")
        }
        return display
    }

    /// 构造 CGVirtualDisplaySettings:首选档在前,表内其余档一并注册。
    static func buildSettings(preferred: VirtualDisplaySpec, table: [VirtualDisplaySpec]) throws -> AnyObject {
        let ordered = [preferred] + table.filter { $0.key != preferred.key }
        let modes = try ordered.map { entry in
            try Self.sendObject(
                Self.alloc("CGVirtualDisplayMode"),
                "initWithWidth:height:refreshRate:",
                entry.width, entry.height, entry.refreshRate
            )
        }
        let settings = try Self.instantiate("CGVirtualDisplaySettings")
        Self.send(settings, "setHiDPI:", false)
        Self.send(settings, "setModes:", modes as NSArray)
        return settings
    }

    /// 原地切档。
    ///
    /// 两条路径(真机实验结论):系统会在镜像建立和每次切换后**动态改写**虚拟屏的
    /// CG 模式表——这次能切的档,下次可能已被移除,直接 CG 切换会因"模式不存在"
    /// 而失败(表现为"偶尔能切换成功,大部分失败")。
    /// - 快路径:目标档仍在当前 CG 模式表 → 纯 CG 切换;
    /// - 慢路径:已被移除 → 用私有对象重新 applySettings 声明模式表
    ///   (目标档放首位),再做 CG 切换。
    /// 激活后轮询验证(镜像组协调是异步的)。
    public func activateSpec(_ handle: VirtualDisplayHandle, spec: VirtualDisplaySpec) throws {
        guard !handle.isDestroyed else {
            throw VirtualDisplayError.createFailed("virtual display already destroyed")
        }

        if !Self.cgTableContains(displayID: handle.displayID, spec: spec) {
            guard let object = handle.retainedObject else {
                throw VirtualDisplayError.createFailed("virtual display already destroyed")
            }
            let settings = try Self.buildSettings(preferred: spec, table: handle.declaredModeTable)
            guard Self.sendBool(object, "applySettings:", settings) else {
                throw VirtualDisplayError.createFailed("re-applySettings returned false")
            }
            // 模式表更新是异步的:轮询等待目标档出现(实验实测需要数百毫秒)
            var appeared = false
            for _ in 0..<20 {
                if Self.cgTableContains(displayID: handle.displayID, spec: spec) {
                    appeared = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            guard appeared else {
                throw VirtualDisplayError.activationFailed(
                    "mode \(spec.key) did not appear in CG table after re-declare"
                )
            }
            logger.info(
                "mode \(spec.key) missing from CG table — re-declared mode table",
                context: "VirtualDisplay"
            )
        }

        try Self.activateMode(displayID: handle.displayID, spec: spec)
        handle.activeSpec = spec
        logger.info("virtual display switched to \(spec.key)", context: "VirtualDisplay")
    }

    /// 目标档是否仍在系统当前提供的 CG 模式表中。
    static func cgTableContains(displayID: UInt32, spec: VirtualDisplaySpec) -> Bool {
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode] else {
            return false
        }
        return modes.contains {
            Int($0.width) == spec.width && Int($0.height) == spec.height
        }
    }

    /// 用公共 CG API 激活目标模式并验证(实验验证的事实:applySettings 只定义模式表,
    /// 激活模式必须显式切换)。
    private static func activate(object: AnyObject, spec: VirtualDisplaySpec) throws -> UInt32 {
        // 轮询等待两件事:WindowServer 分配 displayID + 目标档出现在 CG 模式表。
        // applySettings 只是"声明",发布到 CG 层是异步的(实测需数百毫秒),
        // 表未就绪就去激活会报"mode not in list"——表现为创建/切档时好时坏。
        var displayID: UInt32 = 0
        var tableReady = false
        for _ in 0..<30 {   // 最多 3 秒
            let candidate = sendU32(object, "displayID")
            if candidate != 0 {
                if displayID == 0 { displayID = candidate }
                if cgTableContains(displayID: candidate, spec: spec) {
                    tableReady = true
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard displayID != 0 else {
            throw VirtualDisplayError.createFailed("displayID not assigned")
        }
        guard tableReady else {
            throw VirtualDisplayError.activationFailed(
                "mode \(spec.key) not published to CG table within 3s after applySettings"
            )
        }
        try activateMode(displayID: displayID, spec: spec)
        return displayID
    }

    /// 公共 CG API:配置目标模式 + 轮询验证(镜像组协调是异步的,立即读可能还是旧值)。
    private static func activateMode(displayID: UInt32, spec: VirtualDisplaySpec) throws {
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

        // 轮询等待生效:最多 1 秒(通常一两轮即通过)
        var verified = false
        for _ in 0..<10 {
            if let actual = CGDisplayCopyDisplayMode(displayID),
               Int(actual.width) == spec.width, Int(actual.height) == spec.height {
                verified = true
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard verified else {
            let actualKey = CGDisplayCopyDisplayMode(displayID)
                .map { "\($0.width)x\($0.height)" } ?? "<none>"
            throw VirtualDisplayError.verificationFailed(expected: spec.key, actual: actualKey)
        }
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
