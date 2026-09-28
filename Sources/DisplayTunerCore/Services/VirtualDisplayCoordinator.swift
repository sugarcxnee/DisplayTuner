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
    /// 运行中原地切档成功(模式表内纯 CG 切换,失败会自动回退并报告 failed)。
    case resolutionChanged(spec: VirtualDisplaySpec, sidecarStableID: String)
    /// 会话结束(倒计时/用户/断开/取代);teardownError 非空表示解除镜像失败(Sidecar 可能已断),虚拟屏仍已销毁。
    case stopped(sidecarStableID: String, reason: VirtualDisplayStopReason, teardownError: String?)
    /// 启动/切档失败(已清理或已回退,无残留)。
    case failed(sidecarStableID: String, error: String)

    var sidecarStableID: String {
        switch self {
        case .started(_, _, let id), .confirmed(_, let id), .resolutionChanged(_, let id),
             .stopped(let id, _, _), .failed(let id, _):
            return id
        }
    }
}

/// 活动会话的公开信息:目标 Sidecar、当前激活规格、启动时的基准分辨率
/// (镜像期间 Sidecar 的实时模式会漂移,档位计算必须用基准)。
public struct VirtualDisplaySessionInfo: Equatable, Sendable {
    public let sidecarStableID: String
    public let spec: VirtualDisplaySpec
    public let baseWidth: Int
    public let baseHeight: Int
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
/// 同一 Sidecar 上再次 start 视为**原地切档**(模式表内纯 CG 切换,不重建、
/// 不倒计时,失败立即切回旧档);所有操作幂等;Sidecar 断开导致解除镜像失败时
/// 如实记录,虚拟屏依然销毁。预期在主线程调用。
public final class VirtualDisplayCoordinator {

    public static let defaultConfirmInterval: TimeInterval = 10
    /// 超过此逻辑面积的 Sidecar 模式视为"镜像遗留高档"(原生约 1180×820 ≈ 0.97M)。
    static let sidecarHighModeAreaThreshold = 2_200_000

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
        let baseWidth: Int
        let baseHeight: Int
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

    /// 当前活动会话;无会话时为 nil。
    public var activeSession: VirtualDisplaySessionInfo? {
        session.map {
            VirtualDisplaySessionInfo(
                sidecarStableID: $0.sidecarStableID,
                spec: $0.handle.activeSpec,
                baseWidth: $0.baseWidth,
                baseHeight: $0.baseHeight
            )
        }
    }

    /// 活动虚拟屏的 CGDisplayID(枚举时用于把它从显示器列表里过滤掉)。
    public var activeVirtualDisplayID: UInt32? { session?.handle.displayID }

    /// 是否还有未确认(倒计时运行中)的会话;确认保留后为 false,但仍可手动停止。
    public var hasPendingConfirmation: Bool { session?.countdown != nil }

    /// 启动/切档。
    /// - 同一 Sidecar 已有会话 → 原地切档(`changeResolution`);
    /// - 其他情况(Sidecar 换了/无会话)→ 全新创建,旧的按 superseded 停止。
    public func start(
        spec: VirtualDisplaySpec,
        additionalModes: [VirtualDisplaySpec] = [],
        mirroring sidecar: DisplayInfo
    ) {
        if let existing = session {
            if existing.sidecarStableID == sidecar.stableID {
                changeResolution(to: spec)
                return
            }
            logger.info("superseding active virtual display session (different sidecar)", context: "VirtualCoordinator")
            stop(reason: .superseded)
        }

        var created: VirtualDisplayHandle?
        do {
            // 一律先切回锚定的原生档:真机实验表明 Sidecar 处于任何非原生档时,
            // 虚拟屏的模式表发布与镜像协商都会被系统拒绝。
            mirror.resetToDefaultMode(displayID: sidecar.displayID)
            Thread.sleep(forTimeInterval: 1.0)
            let handle = try factory.create(spec: spec, additionalModes: additionalModes)
            created = handle
            try mirror.mirror(display: sidecar.displayID, toMaster: handle.displayID)

            // 验证镜像确实生效(显示器刚断开时 configure 可能"成功"但无效)
            guard mirror.isInMirrorSet(sidecar.displayID) else {
                throw VirtualDisplayError.createFailed("mirror did not take effect")
            }

            let base = sidecar.currentMode
            var newSession = Session(
                sidecarStableID: sidecar.stableID,
                sidecarDisplayID: sidecar.displayID,
                handle: handle,
                baseWidth: base?.width ?? spec.width,
                baseHeight: base?.height ?? spec.height,
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

    /// 原地切档:模式表内纯 CG 切换,不重建虚拟屏、不打断镜像;
    /// 失败立即切回旧档并报告。无倒计时(切换是即时的、可无损回退)。
    public func changeResolution(to spec: VirtualDisplaySpec) {
        guard let current = session else { return }
        let previousSpec = current.handle.activeSpec
        guard previousSpec.key != spec.key else {
            logger.debug("virtual display already at \(spec.key)", context: "VirtualCoordinator")
            return
        }

        do {
            try factory.activateSpec(current.handle, spec: spec)
            logger.info(
                "virtual display resolution changed \(previousSpec.key) → \(spec.key)",
                context: "VirtualCoordinator"
            )
            notify(.resolutionChanged(spec: spec, sidecarStableID: current.sidecarStableID))
        } catch {
            logger.error(
                "resolution change to \(spec.key) failed: \(error) — reverting to \(previousSpec.key)",
                context: "VirtualCoordinator"
            )
            do {
                try factory.activateSpec(current.handle, spec: previousSpec)
            } catch {
                logger.error("revert to \(previousSpec.key) also failed: \(error)", context: "VirtualCoordinator")
            }
            notify(.failed(sidecarStableID: current.sidecarStableID, error: "\(error)"))
        }
    }

    /// 确认保留当前会话。
    public func confirmActive() {
        guard let current = session else { return }
        current.countdown?.cancel()
        session?.countdown = nil
        // 确认后仍保留 session(activeSession 驱动菜单"运行中"状态),
        // 只是不再自动回滚;用户仍可手动停止或切档。
        logger.info(
            "virtual display \(current.handle.activeSpec.key) confirmed on \(current.sidecarStableID)",
            context: "VirtualCoordinator"
        )
        notify(.confirmed(spec: current.handle.activeSpec, sidecarStableID: current.sidecarStableID))
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
            "virtual display \(current.handle.activeSpec.key) stopped, reason=\(reason.rawValue)",
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
