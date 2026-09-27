import Foundation

/// 虚拟屏会话结束原因。
public enum VirtualDisplayStopReason: String, Equatable, Sendable {
    case timeout = "timeout"
    case userRequested = "user-requested"
    case sidecarDisconnected = "sidecar-disconnected"
    case superseded = "superseded"
    case failedTeardown = "failed"
}

/// 虚拟屏会话结果。
public enum VirtualDisplayOutcome: Equatable {
    /// 虚拟屏已创建并镜像,等待确认。
    case started(spec: VirtualDisplaySpec, virtualDisplayID: UInt32, sidecarStableID: String)
    /// 用户确认保留。
    case confirmed(spec: VirtualDisplaySpec, sidecarStableID: String)
    /// 会话结束(倒计时/用户/断开/取代);teardownError 非空表示解除镜像失败(Sidecar 可能已断),虚拟屏仍已销毁。
    case stopped(sidecarStableID: String, reason: VirtualDisplayStopReason, teardownError: String?)
    /// 启动失败(已清理,无残留)。
    case failed(sidecarStableID: String, error: String)

    var sidecarStableID: String {
        switch self {
        case .started(_, _, let id), .confirmed(_, let id),
             .stopped(let id, _, _), .failed(let id, _):
            return id
        }
    }
}

public protocol VirtualDisplayCoordinatorDelegate: AnyObject {
    func virtualDisplayCoordinator(
        _ coordinator: VirtualDisplayCoordinator,
        didProduce outcome: VirtualDisplayOutcome
    )
}

/// 虚拟屏会话协调器:与 ModeChangeCoordinator 同一套安全模式。
///
/// 生命周期:idle → starting → pendingConfirmation → confirmed / stopped。
/// 创建虚拟屏 + 镜像 = 一次事务;10 秒倒计时未确认则解除镜像并销毁虚拟屏;
/// 所有操作幂等;Sidecar 断开导致解除镜像失败时如实记录,虚拟屏依然销毁。
/// 预期在主线程调用。
public final class VirtualDisplayCoordinator {

    public static let defaultConfirmInterval: TimeInterval = 10

    public let confirmInterval: TimeInterval
    public weak var delegate: VirtualDisplayCoordinatorDelegate?

    private let factory: VirtualDisplayCreating
    private let mirror: DisplayMirrorControlling
    private let scheduler: CountdownScheduler
    private let logger: DTLogger

    private struct Session {
        let sidecarStableID: String
        let sidecarDisplayID: UInt32
        let handle: VirtualDisplayHandle
        var countdown: Cancellable?
    }

    private var session: Session?

    public init(
        factory: VirtualDisplayCreating,
        mirror: DisplayMirrorControlling,
        scheduler: CountdownScheduler = DispatchCountdownScheduler(),
        logger: DTLogger = DTLogger(),
        confirmInterval: TimeInterval = VirtualDisplayCoordinator.defaultConfirmInterval
    ) {
        self.factory = factory
        self.mirror = mirror
        self.scheduler = scheduler
        self.logger = logger
        self.confirmInterval = max(1, confirmInterval)
    }

    /// 当前活动虚拟屏(稳定 ID + 规格);无会话时为 nil。
    public var activeSession: (sidecarStableID: String, spec: VirtualDisplaySpec)? {
        session.map { ($0.sidecarStableID, $0.handle.spec) }
    }

    /// 活动虚拟屏的 CGDisplayID(枚举时用于把它从显示器列表里过滤掉)。
    public var activeVirtualDisplayID: UInt32? { session?.handle.displayID }

    /// 是否还有未确认(倒计时运行中)的会话;确认保留后为 false,但仍可手动停止。
    public var hasPendingConfirmation: Bool { session?.countdown != nil }

    /// 启动:创建虚拟屏 → 把 sidecar 镜像到它 → 验证镜像成立 → 启动倒计时。
    public func start(spec: VirtualDisplaySpec, mirroring sidecar: DisplayInfo) {
        if session != nil {
            logger.info("superseding active virtual display session", context: "VirtualCoordinator")
            stop(reason: .superseded)
        }

        var created: VirtualDisplayHandle?
        do {
            let handle = try factory.create(spec: spec)
            created = handle
            try mirror.mirror(display: sidecar.displayID, toMaster: handle.displayID)

            // 验证镜像确实生效(显示器刚断开时 configure 可能"成功"但无效)
            guard mirror.isInMirrorSet(sidecar.displayID) else {
                throw VirtualDisplayError.createFailed("mirror did not take effect")
            }

            var newSession = Session(
                sidecarStableID: sidecar.stableID,
                sidecarDisplayID: sidecar.displayID,
                handle: handle,
                countdown: nil
            )
            newSession.countdown = scheduler.schedule(after: confirmInterval) { [weak self] in
                guard let self = self, self.session?.handle.displayID == handle.displayID else { return }
                self.stop(reason: .timeout)
            }
            session = newSession
            logger.info(
                "virtual display \(spec.key) started for \(sidecar.logDescriptor), auto-revert in \(Int(self.confirmInterval))s",
                context: "VirtualCoordinator"
            )
            notify(.started(
                spec: spec,
                virtualDisplayID: handle.displayID,
                sidecarStableID: sidecar.stableID
            ))
        } catch {
            if let handle = created {
                factory.destroy(handle)
            }
            logger.error(
                "virtual display start failed for \(sidecar.logDescriptor): \(error)",
                context: "VirtualCoordinator"
            )
            notify(.failed(sidecarStableID: sidecar.stableID, error: "\(error)"))
        }
    }

    /// 确认保留当前会话。
    public func confirmActive() {
        guard let current = session else { return }
        current.countdown?.cancel()
        session?.countdown = nil
        // 注意:确认后仍保留 session(activeSession 非空驱动菜单"运行中"状态),
        // 只是不再自动回滚;用户仍可手动停止。
        logger.info(
            "virtual display \(current.handle.spec.key) confirmed on \(current.sidecarStableID)",
            context: "VirtualCoordinator"
        )
        notify(.confirmed(spec: current.handle.spec, sidecarStableID: current.sidecarStableID))
    }

    /// 停止会话并清理(幂等):解除镜像 → 销毁虚拟屏。
    public func stop(reason: VirtualDisplayStopReason) {
        guard let current = session else { return }
        current.countdown?.cancel()
        session = nil

        var teardownError: String?
        do {
            try mirror.unmirror(display: current.sidecarDisplayID)
        } catch {
            // Sidecar 已断开时这是预期失败:记录并继续销毁虚拟屏
            teardownError = "\(error)"
            logger.error(
                "unmirror failed while stopping (sidecar may be gone): \(error)",
                context: "VirtualCoordinator"
            )
        }
        factory.destroy(current.handle)
        logger.info(
            "virtual display \(current.handle.spec.key) stopped, reason=\(reason.rawValue)",
            context: "VirtualCoordinator"
        )
        notify(.stopped(
            sidecarStableID: current.sidecarStableID,
            reason: reason,
            teardownError: teardownError
        ))
    }

    private func notify(_ outcome: VirtualDisplayOutcome) {
        delegate?.virtualDisplayCoordinator(self, didProduce: outcome)
    }
}
