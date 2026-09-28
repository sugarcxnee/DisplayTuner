import XCTest
import CoreGraphics
@testable import DisplayTunerCore

/// 集成测试(规格 4.3)。
///
/// 两级环境门控:
/// - `DISPLAYTUNER_RUN_LIVE_TESTS=1`:允许在真实 macOS 上做**只读**枚举;
/// - `DISPLAYTUNER_RUN_DANGEROUS_TESTS=1`:允许**真实切换**显示器模式。
///   仅在连接了可承受短暂黑屏的副屏、且有人在场时启用!
///
/// 跑危险测试(尤其播种/虚拟屏)前**先退出 DisplayTuner 菜单栏应用**:
/// 应用与测试进程写同一份日志、同时监听屏幕变化 —— 应用侧的自动恢复会
/// 在测试把 Sidecar 重置到原生档后立刻把档位拉回去,导致虚拟屏模式表
/// 发布被系统拒绝(真机日志已证实此跨进程竞争,易误判为 WindowServer 异常)。
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

    /// 危险测试(v0.2.6 回归):Sidecar 停留在镜像不接受的高分辨率档时,
    /// 开虚拟屏(镜像)应经 fallback(切回默认档重试)成功,而不是直接失败。
    func testDangerousMirrorFallbackWhenSidecarAtHighMode() throws {
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

        // 把 Sidecar 置于模式表里的最高档(镜像会话遗留的高分辨率档)
        let highest = sidecar.modes.filter(\.isSafe).max { $0.width * $0.height < $1.width * $1.height }
        guard let highest = highest else {
            throw XCTSkip("无安全模式")
        }
        if let current = sidecar.currentMode, highest.modeKey != current.modeKey {
            let modeController = CoreGraphicsDisplayModeController(logger: logger)
            _ = try? modeController.apply(highest, to: sidecar)
        }
        print("📺 Sidecar 置于高档: \(highest.modeKey)(已在此档则直接用)")

        // 在高档状态下启动虚拟屏:镜像 fallback 应让 start 成功
        let presets = VirtualDisplayPresets.presets(for: sidecar)
        let start = presets.first(where: { $0.isRecommended })?.spec ?? VirtualDisplaySpec(width: highest.width, height: highest.height)
        coordinator.start(
            spec: start,
            additionalModes: presets.map(\.spec),
            mirroring: sidecar
        )
        coordinator.stop(reason: .userRequested)
        XCTAssertTrue(recorder.outcomes.contains {
            if case .started = $0 { return true }
            return false
        }, "高档状态下 start 应通过镜像 fallback 成功,实际:\(recorder.outcomes)")
    }

    /// 危险测试:播种流程真机验证(在已解锁的机器上验证幂等与干净收尾:
    /// 执行后高档仍在、Sidecar 回原生档、无虚拟屏残留、不在镜像组)。
    func testDangerousSeedHighResolutionModes() throws {
        try XCTSkipUnless(dangerousAllowed,
                          "设置 DISPLAYTUNER_RUN_DANGEROUS_TESTS=1 且确保 Sidecar 已连接、有人在场")

        let logger = DTLogger.makeDefault()
        let service = CoreGraphicsDisplayService(logger: logger)
        guard let sidecar = service.snapshotDisplays().first(where: \.isSidecar) else {
            throw XCTSkip("当前无 Sidecar 连接")
        }
        let modesBefore = sidecar.modes.map(\.modeKey)
        let highBefore = sidecar.modes.filter {
            $0.isSafe && Double($0.width * $0.height) > 1_200_000
        }.count
        let onlineBefore = Self.onlineDisplayCount()

        let seeder = VirtualDisplaySeeder(
            factory: CoreDisplayVirtualDisplayFactory(logger: logger),
            mirror: CoreGraphicsMirrorService(logger: logger),
            logger: logger
        )
        try seeder.seedHighResolutionModes(on: sidecar)

        // 等待系统稳定后重新枚举
        Thread.sleep(forTimeInterval: 2.0)
        let after = service.snapshotDisplays()
        guard let sidecarAfter = after.first(where: { $0.stableID == sidecar.stableID }) else {
            return XCTFail("播种后 Sidecar 消失")
        }
        let highAfter = sidecarAfter.modes.filter {
            $0.isSafe && Double($0.width * $0.height) > 1_200_000
        }.count

        print("📺 播种前高档数=\(highBefore), 播种后=\(highAfter), 当前=\(sidecarAfter.currentMode?.modeKey ?? "?")")
        XCTAssertGreaterThanOrEqual(highAfter, highBefore, "播种不得丢失已有高档")
        XCTAssertEqual(Self.onlineDisplayCount(), onlineBefore, "无虚拟屏残留")
        XCTAssertFalse(CoreGraphicsMirrorService(logger: logger).isInMirrorSet(sidecarAfter.displayID), "不在镜像组")
        if let anchor = sidecarAfter.nativeAnchoredSize,
           let current = sidecarAfter.currentMode {
            XCTAssertEqual(current.width, anchor.width, "收尾应回到原生档")
            XCTAssertEqual(current.height, anchor.height)
        }
        _ = modesBefore
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
