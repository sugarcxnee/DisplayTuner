import Foundation

/// 模式应用/回滚错误。
public enum ModeApplicationError: Error, Equatable, CustomStringConvertible {
    /// 目标显示器不在线(可能已拔出/Sidecar 断开)。
    case displayNotFound(UInt32)
    /// 目标模式在该显示器上不可用。
    case modeNotFound(String)
    /// CG 配置阶段失败。真实实现内部已尽力恢复原模式。
    case applyFailed(String)
    /// 应用后验证发现实际模式与期望不符,已自动恢复。
    case verificationFailed(expected: String, actual: String)
    /// 回滚失败(例如显示器在确认期间断开)。
    case rollbackFailed(String)

    public var description: String {
        switch self {
        case .displayNotFound(let id):
            return "display \(id) not found"
        case .modeNotFound(let key):
            return "mode \(key) not available on this display"
        case .applyFailed(let detail):
            return "apply failed: \(detail)"
        case .verificationFailed(let expected, let actual):
            return "verification failed: expected \(expected), got \(actual)"
        case .rollbackFailed(let detail):
            return "rollback failed: \(detail)"
        }
    }
}

/// 一次成功应用后的回滚凭据:记录应用前模式,供倒计时超时/用户取消时恢复。
public struct AppliedChange: Equatable, Sendable {
    public let displayStableID: String
    public let displayID: UInt32
    public let displayLogDescriptor: String
    public let previousMode: DisplayModeInfo
    public let appliedMode: DisplayModeInfo
    public let timestamp: Date

    public init(
        displayStableID: String,
        displayID: UInt32,
        displayLogDescriptor: String,
        previousMode: DisplayModeInfo,
        appliedMode: DisplayModeInfo,
        timestamp: Date = Date()
    ) {
        self.displayStableID = displayStableID
        self.displayID = displayID
        self.displayLogDescriptor = displayLogDescriptor
        self.previousMode = previousMode
        self.appliedMode = appliedMode
        self.timestamp = timestamp
    }
}

/// 显示模式控制器:真正改系统配置的唯一入口。
///
/// 契约:
/// - `apply` 成功返回变更凭据(含旧模式);
/// - `apply` 失败抛错,且真实实现在抛错前已尽力把显示器恢复原样;
/// - `rollback` 用凭据恢复旧模式。
public protocol DisplayModeController: AnyObject {
    /// 读取某显示器当前生效模式(无显示器/无模式时为 nil)。
    func currentMode(for displayID: UInt32) -> DisplayModeInfo?

    /// 应用新模式到显示器。应用前读取并保存旧模式,应用后验证。
    func apply(_ mode: DisplayModeInfo, to display: DisplayInfo) throws -> AppliedChange

    /// 回滚一次变更。
    func rollback(_ change: AppliedChange) throws
}
