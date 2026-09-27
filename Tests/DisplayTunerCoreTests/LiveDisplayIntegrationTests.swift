import XCTest
import CoreGraphics
@testable import DisplayTunerCore

/// 集成测试(规格 4.3)。
///
/// 两级环境门控:
/// - `DISPLAYTUNER_RUN_LIVE_TESTS=1`:允许在真实 macOS 上做**只读**枚举;
/// - `DISPLAYTUNER_RUN_DANGEROUS_TESTS=1`:允许**真实切换**显示器模式。
///   仅在连接了可承受短暂黑屏的副屏、且有人在场时启用!
final class LiveDisplayIntegrationTests: XCTestCase {

    private var liveAllowed: Bool {
        ProcessInfo.processInfo.environment["DISPLAYTUNER_RUN_LIVE_TESTS"] == "1"
    }

    private var dangerousAllowed: Bool {
        ProcessInfo.processInfo.environment["DISPLAYTUNER_RUN_DANGEROUS_TESTS"] == "1"
    }

    func testLiveEnumerationPrintsDisplayAndModes() throws {
        try XCTSkipUnless(liveAllowed, "设置 DISPLAYTUNER_RUN_LIVE_TESTS=1 启用真实枚举")

        let service = CoreGraphicsDisplayService(logger: DTLogger.makeDefault())
        let displays = service.snapshotDisplays()

        XCTAssertGreaterThanOrEqual(displays.count, 1)
        for display in displays {
            print("📺 \(display.logDescriptor) — \(display.modes.count) 个模式")
            if let current = display.currentMode {
                print("   当前:\(current.title)")
            }
            for mode in display.modes.prefix(5) {
                print("   - \(mode.title)\(mode.isRecommended ? " ⭐推荐" : "")")
            }
        }
    }

    func testLiveSidecarDisplayDetectedWhenConnected() throws {
        try XCTSkipUnless(liveAllowed, "设置 DISPLAYTUNER_RUN_LIVE_TESTS=1 启用真实枚举")

        let service = CoreGraphicsDisplayService(logger: DTLogger.makeDefault())
        let displays = service.snapshotDisplays()
        let sidecars = displays.filter(\.isSidecar)

        // 断言只验证信息一致性,不强求本机一定有 Sidecar
        if sidecars.isEmpty {
            throw XCTSkip("本机当前无 Sidecar 连接,跳过 Sidecar 断言")
        }
        for sidecar in sidecars {
            XCTAssertFalse(sidecar.isBuiltin)
            XCTAssertFalse(sidecar.modes.isEmpty, "Sidecar 显示器应暴露至少一个模式")
        }
    }

    /// 危险测试:对**非主屏**真实应用一次同效果模式并确认回滚闭环。
    /// 前提:连接了副屏,有人在场。10 秒倒计时由 Mock 调度器立即触发。
    func testDangerousApplyAndRollbackOnSecondaryDisplay() throws {
        try XCTSkipUnless(dangerousAllowed,
                          "设置 DISPLAYTUNER_RUN_DANGEROUS_TESTS=1 且确保有人在场、副屏可短暂黑屏")

        let logger = DTLogger.makeDefault()
        let service = CoreGraphicsDisplayService(logger: logger)
        let displays = service.snapshotDisplays()

        // 只碰非主屏、有多个安全模式的显示器
        guard let target = displays.first(where: { !$0.isMain && $0.modes.filter(\.isSafe).count >= 2 }) else {
            throw XCTSkip("没有符合条件的副屏(非主屏且至少两个安全模式)")
        }
        let modes = target.modes.filter(\.isSafe)
        let other = modes.first { $0.modeKey != target.currentMode?.modeKey }
        guard let other = other else {
            throw XCTSkip("副屏无可切换的备用模式")
        }

        let controller = CoreGraphicsDisplayModeController(logger: logger)
        let scheduler = ImmediateFireScheduler()
        let coordinator = ModeChangeCoordinator(
            controller: controller,
            scheduler: scheduler,
            logger: logger
        )
        let recorder = OutcomeRecorder()
        coordinator.delegate = recorder

        let originalKey = target.currentMode?.modeKey
        coordinator.request(mode: other, on: target)
        XCTAssertTrue(coordinator.hasPendingConfirmation, "应用后应进入待确认状态")
        XCTAssertEqual(recorder.outcomes.count, 1)

        scheduler.fireAll()
        XCTAssertFalse(coordinator.hasPendingConfirmation)
        XCTAssertEqual(recorder.outcomes.count, 2)

        // 倒计时回滚后,实际生效模式应恢复
        let restored = service.snapshotDisplays()
            .first { $0.stableID == target.stableID }?
            .currentMode?.modeKey
        XCTAssertEqual(restored, originalKey, "回滚后应恢复原模式")
    }
}

/// 立即触发的倒计时调度器,仅供危险集成测试使用。
final class ImmediateFireScheduler: CountdownScheduler {
    private var handlers: [() -> Void] = []

    func schedule(after delay: TimeInterval, handler: @escaping () -> Void) -> Cancellable {
        handlers.append(handler)
        return NoopCancellable()
    }

    func fireAll() {
        let pending = handlers
        handlers = []
        for handler in pending { handler() }
    }
}

final class NoopCancellable: Cancellable {
    func cancel() {}
}

extension LiveDisplayIntegrationTests {

    /// 危险测试:对 Sidecar 真实走一遍"虚拟屏 + 镜像 + 停止"闭环。
    /// 前提:Sidecar 已连接、有人在场;整个过程几秒内完成并自动恢复。
    func testDangerousVirtualDisplayRoundtripOnSidecar() throws {
        try XCTSkipUnless(dangerousAllowed,
                          "设置 DISPLAYTUNER_RUN_DANGEROUS_TESTS=1 且确保 Sidecar 已连接、有人在场")

        let logger = DTLogger.makeDefault()
        let service = CoreGraphicsDisplayService(logger: logger)
        guard let sidecar = service.snapshotDisplays().first(where: \.isSidecar) else {
            throw XCTSkip("当前无 Sidecar 连接")
        }
        guard let current = sidecar.currentMode else {
            throw XCTSkip("Sidecar 无当前模式")
        }

        let mirror = CoreGraphicsMirrorService(logger: logger)
        let factory = CoreDisplayVirtualDisplayFactory(logger: logger)
        let recorder = VirtualDisplayRecorder()
        let coordinator = VirtualDisplayCoordinator(
            factory: factory,
            mirror: mirror,
            scheduler: ImmediateFireScheduler(),
            logger: logger
        )
        coordinator.delegate = recorder

        let onlineBefore = Self.onlineDisplayCount()

        // 1. 启动:虚拟屏 = 当前逻辑分辨率 ×2
        let spec = VirtualDisplaySpec(width: current.width * 2, height: current.height * 2)
        coordinator.start(spec: spec, mirroring: sidecar)
        XCTAssertEqual(
            recorder.outcomes.last,
            .started(spec: spec, virtualDisplayID: coordinator.activeVirtualDisplayID ?? 0, sidecarStableID: sidecar.stableID)
        )
        XCTAssertTrue(coordinator.hasPendingConfirmation)
        XCTAssertTrue(mirror.isInMirrorSet(sidecar.displayID), "Sidecar 应处于镜像组")
        XCTAssertEqual(Self.onlineDisplayCount(), onlineBefore + 1, "在线显示器应 +1")
        if let vid = coordinator.activeVirtualDisplayID, let m = CGDisplayCopyDisplayMode(vid) {
            print("📺 虚拟屏激活模式: \(m.width)x\(m.height) px\(m.pixelWidth)x\(m.pixelHeight)")
            XCTAssertEqual(m.width, spec.width)
            XCTAssertEqual(m.height, spec.height)
        }

        // 2. 确认保留
        coordinator.confirmActive()
        XCTAssertFalse(coordinator.hasPendingConfirmation)

        // 3. 停止
        coordinator.stop(reason: .userRequested)
        XCTAssertNil(coordinator.activeSession)
        XCTAssertEqual(Self.onlineDisplayCount(), onlineBefore, "虚拟屏销毁后在线数回落")
        sleep(1)
        XCTAssertFalse(mirror.isInMirrorSet(sidecar.displayID), "镜像应已解除")
    }

    private static func onlineDisplayCount() -> Int {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        _ = CGGetOnlineDisplayList(32, &ids, &count)
        return Int(count)
    }

    /// 危险测试(v0.2.3 回归):镜像状态下反复切档。
    /// 系统会在镜像/切换后动态改写虚拟屏 CG 模式表,历史 bug 是"这次能切的档
    /// 下次不在表里 → 大部分切换失败"。此测试连续切各档两轮,全部必须成功。
    func testDangerousVirtualDisplayRepeatedSwitchUnderMirror() throws {
        try XCTSkipUnless(dangerousAllowed,
                          "设置 DISPLAYTUNER_RUN_DANGEROUS_TESTS=1 且确保 Sidecar 已连接、有人在场")

        let logger = DTLogger.makeDefault()
        let service = CoreGraphicsDisplayService(logger: logger)
        guard let sidecar = service.snapshotDisplays().first(where: \.isSidecar) else {
            throw XCTSkip("当前无 Sidecar 连接")
        }

        let factory = CoreDisplayVirtualDisplayFactory(logger: logger)
        let mirror = CoreGraphicsMirrorService(logger: logger)
        let coordinator = VirtualDisplayCoordinator(
            factory: factory,
            mirror: mirror,
            scheduler: ImmediateFireScheduler(),
            logger: logger
        )
        let recorder = VirtualDisplayRecorder()
        coordinator.delegate = recorder

        // 清理残留镜像(例如上次异常退出遗留的会话),否则基准读数会被污染
        if mirror.isInMirrorSet(sidecar.displayID) {
            print("⚠️ Sidecar 已处于镜像组,先解除残留镜像")
            try? mirror.unmirror(display: sidecar.displayID)
            Thread.sleep(forTimeInterval: 1.5)
        }
        // 重新枚举拿干净的基准分辨率
        guard let clean = service.snapshotDisplays()
            .first(where: { $0.stableID == sidecar.stableID }) else {
            throw XCTSkip("重新枚举失败")
        }
        let presets = VirtualDisplayPresets.presets(for: clean)
        guard presets.count >= 2 else { throw XCTSkip("无可用档位") }
        let allSpecs = presets.map(\.spec)
        let start = presets.first(where: \.isRecommended)!.spec

        coordinator.start(spec: start, additionalModes: allSpecs, mirroring: sidecar)
        guard coordinator.activeSession != nil else {
            XCTFail("start 失败: \(String(describing: recorder.outcomes.last))")
            return
        }
        coordinator.confirmActive()
        XCTAssertTrue(mirror.isInMirrorSet(sidecar.displayID))

        // 两轮 × 全部档位(含起点档),覆盖"表漂移后目标档消失"的场景
        for _ in 0..<2 {
            for spec in allSpecs {
                coordinator.changeResolution(to: spec)
                guard case .resolutionChanged(let applied, _) = recorder.outcomes.last ?? .failed(sidecarStableID: "", error: "") else {
                    XCTFail("切档到 \(spec.key) 失败,最后结果:\(String(describing: recorder.outcomes.last))")
                    continue
                }
                XCTAssertEqual(applied.key, spec.key)
                XCTAssertEqual(coordinator.activeSession?.spec.key, spec.key)

                if let vid = coordinator.activeVirtualDisplayID,
                   let mode = CGDisplayCopyDisplayMode(vid) {
                    XCTAssertEqual(Int(mode.width), spec.width, "实际生效模式应为 \(spec.key)")
                    XCTAssertEqual(Int(mode.height), spec.height)
                    print("📺 虚拟屏实际模式: \(mode.width)x\(mode.height) ✅")
                }
            }
        }

        coordinator.stop(reason: .userRequested)
        XCTAssertNil(coordinator.activeSession)
    }
}

final class VirtualDisplayRecorder: VirtualDisplayCoordinatorDelegate {
    private(set) var outcomes: [VirtualDisplayOutcome] = []

    func virtualDisplayCoordinator(
        _ coordinator: VirtualDisplayCoordinator,
        didProduce outcome: VirtualDisplayOutcome
    ) {
        outcomes.append(outcome)
    }
}
