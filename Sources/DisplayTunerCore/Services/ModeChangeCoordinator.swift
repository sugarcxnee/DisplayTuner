import Foundation

/// 可取消的倒计时任务。
public protocol Cancellable: AnyObject {
    func cancel()
}

/// 倒计时调度器。生产用 Dispatch 实现;测试注入 Mock 以同步触发超时。
public protocol CountdownScheduler: AnyObject {
    @discardableResult
    func schedule(after delay: TimeInterval, handler: @escaping () -> Void) -> Cancellable
}

/// 主队列倒计时实现。App 层的 NSAlert 还会另持一个 common-modes 的 NSTimer
/// 驱动界面倒计时并在到点先调用回滚 —— 两者幂等,谁先到谁生效;这里只作兜底。
public final class DispatchCountdownScheduler: CountdownScheduler {
    private let queue: DispatchQueue

    public init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    public func schedule(after delay: TimeInterval, handler: @escaping () -> Void) -> Cancellable {
        let workItem = DispatchWorkItem(block: handler)
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
        return WorkItemCancellable(workItem)
    }
}

final class WorkItemCancellable: Cancellable {
    private let workItem: DispatchWorkItem

    init(_ workItem: DispatchWorkItem) {
        self.workItem = workItem
    }

    func cancel() {
        workItem.cancel()
    }
}

/// 回滚原因。
public enum RevertReason: String, Equatable, Sendable {
    /// 倒计时结束用户未确认。
    case timeout
    /// 用户在确认框点了"还原"。
    case userRequested
    /// 新的模式请求取代了旧待确认项。
    case superseded
}

/// 模式变更结果,驱动菜单刷新与(必要时的)用户提示。
public enum ModeChangeOutcome: Equatable {
    /// 已应用,等待确认。
    case applied(display: String, modeKey: String)
    /// 用户确认保留。
    case confirmed(display: String, modeKey: String)
    /// 已回滚。rollbackError 非空表示恢复旧模式本身失败(如显示器已断开),已记日志。
    case reverted(display: String, reason: RevertReason, rollbackError: String?)
    /// 应用失败(控制器已尽力恢复原状)。
    case failed(display: String, error: String)

    public var displayID: String {
        switch self {
        case .applied(let display, _),
             .confirmed(let display, _),
             .reverted(let display, _, _),
             .failed(let display, _):
            return display
        }
    }
}

/// 模式变更协调器:安全倒计时的状态机。
///
/// 生命周期:idle → applying → pendingConfirmation → confirmed / reverted。
/// 同一时刻至多一个待确认变更;新的请求会先把旧的回滚(superseded)。
/// 所有方法幂等:重复 confirm / revert / 超时不会产生二次回滚。
/// 预期在主线程调用。
public final class ModeChangeCoordinator {

    /// 默认安全倒计时(秒)。
    public static let defaultConfirmInterval: TimeInterval = 10

    public let confirmInterval: TimeInterval
    public weak var delegate: ModeChangeCoordinatorDelegate?

    private let controller: DisplayModeController
    private let scheduler: CountdownScheduler
    private let logger: DTLogger

    private var pending: AppliedChange?
    private var countdown: Cancellable?

    public init(
        controller: DisplayModeController,
        scheduler: CountdownScheduler = DispatchCountdownScheduler(),
        logger: DTLogger = DTLogger(),
        confirmInterval: TimeInterval = ModeChangeCoordinator.defaultConfirmInterval
    ) {
        self.controller = controller
        self.scheduler = scheduler
        self.logger = logger
        self.confirmInterval = max(1, confirmInterval)
    }

    public var hasPendingConfirmation: Bool { pending != nil }
    public var pendingChange: AppliedChange? { pending }

    /// 请求应用新模式。应用失败立即结束(控制器内部已恢复),成功则启动倒计时。
    public func request(mode: DisplayModeInfo, on display: DisplayInfo) {
        if pending != nil {
            logger.info("superseding pending change", context: "Coordinator")
            revertPending(reason: .superseded)
        }

        do {
            let change = try controller.apply(mode, to: display)
            pending = change
            countdown = scheduler.schedule(after: confirmInterval) { [weak self] in
                guard let self = self else { return }
                if self.pending == change {
                    self.revertPending(reason: .timeout)
                }
            }
            logger.info(
                "pending confirmation for \(change.appliedMode.modeKey) on \(display.logDescriptor), auto-revert in \(Int(self.confirmInterval))s",
                context: "Coordinator"
            )
            notify(.applied(display: display.stableID, modeKey: mode.modeKey))
        } catch {
            logger.error(
                "apply \(mode.modeKey) to \(display.logDescriptor) failed: \(error)",
                context: "Coordinator"
            )
            pending = nil
            countdown?.cancel()
            countdown = nil
            notify(.failed(display: display.stableID, error: "\(error)"))
        }
    }

    /// 用户确认保留当前变更。
    public func confirmPending() {
        guard let change = pending else { return }
        countdown?.cancel()
        countdown = nil
        pending = nil
        logger.info(
            "confirmed \(change.appliedMode.modeKey) on \(change.displayLogDescriptor)",
            context: "Coordinator"
        )
        notify(.confirmed(display: change.displayStableID, modeKey: change.appliedMode.modeKey))
    }

    /// 回滚待确认变更(超时/用户取消/被取代)。幂等。
    public func revertPending(reason: RevertReason) {
        guard let change = pending else { return }
        countdown?.cancel()
        countdown = nil
        pending = nil

        var rollbackErrorDescription: String?
        do {
            try controller.rollback(change)
        } catch {
            // 回滚失败常见于显示器已拔出/Sidecar 已断开 —— 记日志并如实上报
            rollbackErrorDescription = "\(error)"
            logger.error(
                "rollback \(change.displayLogDescriptor) to \(change.previousMode.modeKey) failed: \(error)",
                context: "Coordinator"
            )
        }
        logger.info(
            "reverted \(change.displayLogDescriptor) to \(change.previousMode.modeKey), reason=\(reason.rawValue)",
            context: "Coordinator"
        )
        notify(.reverted(
            display: change.displayStableID,
            reason: reason,
            rollbackError: rollbackErrorDescription
        ))
    }

    private func notify(_ outcome: ModeChangeOutcome) {
        delegate?.coordinator(self, didProduce: outcome)
    }
}

public protocol ModeChangeCoordinatorDelegate: AnyObject {
    func coordinator(_ coordinator: ModeChangeCoordinator, didProduce outcome: ModeChangeOutcome)
}
