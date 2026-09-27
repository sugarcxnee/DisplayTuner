import Foundation
import Darwin

/// 动态符号查找抽象:生产用 dlopen/dlsym,测试注入 Stub。
public protocol SymbolLookup: AnyObject {
    /// 打开动态库,失败返回 nil。句柄由实现持有,不要求调用方关闭。
    func openLibrary(path: String) -> UnsafeMutableRawPointer?
    /// 查找符号,失败返回 nil。
    func symbol(handle: UnsafeMutableRawPointer, name: String) -> UnsafeMutableRawPointer?
}

/// dlopen/dlsym 真实实现。不直接链接任何私有框架。
public final class DylibSymbolLookup: SymbolLookup {

    /// 已打开的库句柄,进程生命周期内保持(RTLD_LAZY|RTLD_LOCAL,不污染符号表)。
    private var handles: [String: UnsafeMutableRawPointer] = [:]
    private let lock = NSLock()

    public init() {}

    public func openLibrary(path: String) -> UnsafeMutableRawPointer? {
        lock.lock(); defer { lock.unlock() }
        if let existing = handles[path] { return existing }
        guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else { return nil }
        handles[path] = handle
        return handle
    }

    public func symbol(handle: UnsafeMutableRawPointer, name: String) -> UnsafeMutableRawPointer? {
        dlsym(handle, name)
    }
}

/// 私有 DisplayServices 框架探测报告。
public struct PrivateSymbolReport: Equatable, Sendable {
    public let libraryPath: String
    /// 找到的候选符号。
    public let foundSymbols: [String]
    /// 缺失的候选符号。
    public let missingSymbols: [String]

    public var isAvailable: Bool { !foundSymbols.isEmpty }

    public init(libraryPath: String, foundSymbols: [String], missingSymbols: [String]) {
        self.libraryPath = libraryPath
        self.foundSymbols = foundSymbols
        self.missingSymbols = missingSymbols
    }

    /// 菜单展示用的简短状态描述(不暴露路径细节)。
    public var statusDescription: String {
        if isAvailable {
            return "私有符号可用(\(foundSymbols.count) 个)"
        }
        return "未找到私有符号"
    }
}

/// 私有 DisplayServices 框架的动态探测。
///
/// 隔离规则(规格 3.4 / ARCHITECTURE):
/// - 只用 dlopen/dlsym,不直接链接私有框架;
/// - 只探测已知符号名,缺失即如实报告,绝不编造能力;
/// - 当前版本只做只读探测,不调用任何写入型私有函数;
/// - 增强主体是公开 API 的隐藏模式枚举,私有部分不可用时自动降级。
public final class PrivateDisplayServices {

    public static let displayServicesPath =
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"

    /// 候选符号(名称来自公开的逆向工程资料;存在性不保证)。
    public static let candidateSymbols = [
        "DisplayServicesGetIntegerValue",
        "DisplayServicesSetIntegerValue",
        "DisplayServicesCopyValue",
        "DisplayServicesSetBinaryValue",
    ]

    private let lookup: SymbolLookup
    private let logger: DTLogger

    public init(lookup: SymbolLookup = DylibSymbolLookup(), logger: DTLogger = DTLogger()) {
        self.lookup = lookup
        self.logger = logger
    }

    /// 探测一次并返回报告。结果同时写日志。
    public func probe() -> PrivateSymbolReport {
        guard let handle = lookup.openLibrary(path: Self.displayServicesPath) else {
            logger.info(
                "private framework not loadable: \(Self.displayServicesPath) — degrading to public API",
                context: "PrivateAPI"
            )
            return PrivateSymbolReport(
                libraryPath: Self.displayServicesPath,
                foundSymbols: [],
                missingSymbols: Self.candidateSymbols
            )
        }

        var found: [String] = []
        var missing: [String] = []
        for name in Self.candidateSymbols {
            if lookup.symbol(handle: handle, name: name) != nil {
                found.append(name)
            } else {
                missing.append(name)
            }
        }
        logger.debug(
            "probe found=\(found) missing=\(missing.count)",
            context: "PrivateAPI"
        )
        return PrivateSymbolReport(
            libraryPath: Self.displayServicesPath,
            foundSymbols: found,
            missingSymbols: missing
        )
    }
}
