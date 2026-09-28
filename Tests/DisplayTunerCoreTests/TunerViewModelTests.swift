import XCTest
@testable import DisplayTunerCore

final class TunerViewModelTests: XCTestCase {

    private var displayService: MockDisplayService!
    private var controller: MockDisplayModeController!
    private var configStore: MockConfigStore!
    private var loginItems: MockLoginItem!
    private var scheduler: MockCountdownScheduler!
    private var viewModel: TunerViewModel!

    override func setUp() {
        super.setUp()
        displayService = MockDisplayService()
        controller = MockDisplayModeController()
        configStore = MockConfigStore()
        loginItems = MockLoginItem()
        scheduler = MockCountdownScheduler()

        let builtin = DisplayCatalog.display(from: Fixtures.builtinDisplay())
        let sidecar = DisplayCatalog.display(from: Fixtures.sidecarDisplay(modes: [
            Fixtures.mode(1920, 1080),
            Fixtures.mode(2560, 1600),
        ]))
        displayService.displays = [builtin, sidecar]
        for display in [builtin, sidecar] {
            controller.currentModes[display.displayID] = display.currentMode
        }

        viewModel = makeViewModel()
    }

    private func makeViewModel(enhancer: SidecarEnhancer? = nil) -> TunerViewModel {
        TunerViewModel(
            displayService: displayService,
            modeController: controller,
            configStore: configStore,
            loginItems: loginItems,
            enhancer: enhancer,
            countdownScheduler: scheduler,
            logger: DTLogger(sinks: [MemoryLogSink()])
        )
    }

    private var sidecarDisplay: DisplayInfo {
        displayService.displays.first { $0.isSidecar }!
    }

    private var higherSidecarMode: DisplayModeInfo {
        sidecarDisplay.modes.first { !$0.isCurrent }!
    }

    // MARK: - 刷新

    func testRefreshEnumeratesAndBuildsMenu() {
        let menu = viewModel.refreshDisplays()

        XCTAssertEqual(displayService.snapshotCallCount, 1)
        XCTAssertEqual(viewModel.displays.count, 2)
        XCTAssertTrue(menu.entries.contains { $0.title == "刷新显示器" })
    }

    func testPerformRefreshTriggersEnumeration() {
        viewModel.refreshDisplays()
        viewModel.perform(.refresh)
        XCTAssertEqual(displayService.snapshotCallCount, 2)
    }

    // MARK: - 选择模式

    func testSelectModeRoutesThroughCoordinator() {
        viewModel.refreshDisplays()

        let target = higherSidecarMode
        viewModel.perform(.selectMode(
            displayStableID: sidecarDisplay.stableID,
            modeKey: target.modeKey
        ))

        XCTAssertEqual(controller.applyCalls, ["\(target.modeKey)@\(sidecarDisplay.displayID)"])
        XCTAssertTrue(viewModel.coordinator.hasPendingConfirmation)
    }

    func testConfirmedChangeIsPersistedPerDisplay() {
        viewModel.refreshDisplays()
        let target = higherSidecarMode
        viewModel.perform(.selectMode(
            displayStableID: sidecarDisplay.stableID,
            modeKey: target.modeKey
        ))
        viewModel.coordinator.confirmPending()

        XCTAssertEqual(
            configStore.config.perDisplay[sidecarDisplay.stableID]?.modeKey,
            target.modeKey,
            "确认保留后才写入持久化"
        )
    }

    func testRevertedChangeIsNotPersisted() {
        viewModel.refreshDisplays()
        let target = higherSidecarMode
        viewModel.perform(.selectMode(
            displayStableID: sidecarDisplay.stableID,
            modeKey: target.modeKey
        ))
        scheduler.fireLast()   // 超时回滚

        XCTAssertNil(
            configStore.config.perDisplay[sidecarDisplay.stableID]?.modeKey,
            "回滚的模式绝不能被记住"
        )
    }

    func testSelectModeOnVanishedDisplayIsIgnored() {
        viewModel.refreshDisplays()
        viewModel.perform(.selectMode(displayStableID: "display-v1-nope", modeKey: "1920x1080@60-hidpi"))
        XCTAssertTrue(controller.applyCalls.isEmpty)
        XCTAssertFalse(viewModel.coordinator.hasPendingConfirmation)
    }

    // MARK: - 过滤

    func testToggleFilterPersistsAndAffectsMenu() {
        viewModel.refreshDisplays()
        viewModel.perform(.toggleFilter(
            displayStableID: sidecarDisplay.stableID,
            filter: .hidpiOnly
        ))

        XCTAssertEqual(
            configStore.config.perDisplay[sidecarDisplay.stableID]?.filters,
            [.hidpiOnly]
        )
    }

    // MARK: - 自动恢复

    func testAutoRestoreAppliesSavedDifferentMode() {
        // 保存:Sidecar 上次选了更高模式
        var config = configStore.config
        var perDisplay = PerDisplayConfig()
        perDisplay.modeKey = "2560x1600@60-hidpi"
        config.perDisplay[sidecarDisplay.stableID] = perDisplay
        configStore.config = config

        viewModel.refreshDisplays()
        viewModel.autoRestoreIfNeeded()

        XCTAssertEqual(controller.applyCalls.count, 1, "应自动恢复一次")
        XCTAssertTrue(controller.applyCalls[0].hasPrefix("2560x1600@60-hidpi"))
    }

    func testAutoRestoreFallsBackToSameSizeWhenSavedHiDPIKeyNotListed() {
        // Sidecar 冷启动形态:保存的是影子 HiDPI key,但当前快照的模式表
        // 只有同尺寸 1x 条目(缓存未捕获、影子未注入)—— 按 sizeKey 回退
        // 恢复尺寸,清晰度升级留给 apply 内部再尝试。
        let coldSidecar = DisplayCatalog.display(from: Fixtures.sidecarDisplay(
            currentModeIndex: 1,
            modes: [
                Fixtures.mode(1116, 820, hidpi: false),
                Fixtures.mode(1280, 940, hidpi: false),
            ]
        ))
        displayService.displays = [coldSidecar]

        var config = configStore.config
        config.perDisplay[coldSidecar.stableID] = PerDisplayConfig(modeKey: "1116x820@60-hidpi")
        configStore.config = config

        viewModel.refreshDisplays()
        viewModel.autoRestoreIfNeeded()

        XCTAssertEqual(controller.applyCalls.count, 1, "应经 sizeKey 回退恢复一次")
        XCTAssertTrue(
            controller.applyCalls[0].hasPrefix("1116x820@60@"),
            "回退目标应是同尺寸条目,实际 \(controller.applyCalls)"
        )
    }

    func testAutoRestoreSkipsWhenAlreadyAtSavedMode() {
        var config = configStore.config
        config.perDisplay[sidecarDisplay.stableID] = PerDisplayConfig(
            modeKey: sidecarDisplay.currentMode?.modeKey
        )
        configStore.config = config

        viewModel.refreshDisplays()
        viewModel.autoRestoreIfNeeded()

        XCTAssertTrue(controller.applyCalls.isEmpty)
    }

    func testAutoRestoreDisabledByConfig() {
        var config = configStore.config
        config.autoRestore = false
        config.perDisplay[sidecarDisplay.stableID] = PerDisplayConfig(modeKey: "2560x1600@60-hidpi")
        configStore.config = config

        viewModel.refreshDisplays()
        viewModel.autoRestoreIfNeeded()

        XCTAssertTrue(controller.applyCalls.isEmpty)
    }

    func testAutoRestoreSkipsUnavailableSavedMode() {
        var config = configStore.config
        config.perDisplay[sidecarDisplay.stableID] = PerDisplayConfig(modeKey: "9999x9999@120")
        configStore.config = config

        viewModel.refreshDisplays()
        viewModel.autoRestoreIfNeeded()

        XCTAssertTrue(controller.applyCalls.isEmpty, "保存的模式已不可用时不动作")
    }

    func testAutoRestoreDoesNotSupersedePendingUserChange() {
        // 场景(真机日志):保存偏好为高档,用户主动切回低档且尚在确认窗口,
        // 切换引发的屏幕变化立刻触发自动恢复 —— 修复前恢复会把用户的新切换
        // supersede 拉回旧偏好,随后回滚还会误清偏好。
        var config = configStore.config
        config.perDisplay[sidecarDisplay.stableID] = PerDisplayConfig(modeKey: "2560x1600@60-hidpi")
        configStore.config = config

        viewModel.refreshDisplays()
        viewModel.perform(.selectMode(
            displayStableID: sidecarDisplay.stableID,
            modeKey: "1920x1080@60-hidpi"
        ))
        XCTAssertEqual(controller.applyCalls.count, 1)

        viewModel.autoRestoreIfNeeded()

        XCTAssertEqual(controller.applyCalls.count, 1, "用户切换确认窗口内,自动恢复必须让位")
        XCTAssertTrue(viewModel.coordinator.hasPendingConfirmation, "pending 不得被恢复顶掉")
    }

    func testAutoRestoreCooldownSkipsRepeatWithinWindow() {
        var config = configStore.config
        config.perDisplay[sidecarDisplay.stableID] = PerDisplayConfig(modeKey: "2560x1600@60-hidpi")
        configStore.config = config

        viewModel.refreshDisplays()
        viewModel.autoRestoreIfNeeded()
        XCTAssertEqual(controller.applyCalls.count, 1, "第一次恢复应执行")

        // 冷却窗口内再次触发(系统把模式拉回的场景):不再发起,避免弹窗循环
        viewModel.autoRestoreIfNeeded()
        XCTAssertEqual(controller.applyCalls.count, 1, "冷却窗口内不重复发起")
    }

    func testAutoRestoreResumesAfterCooldownExpires() {
        var config = configStore.config
        config.perDisplay[sidecarDisplay.stableID] = PerDisplayConfig(modeKey: "2560x1600@60-hidpi")
        configStore.config = config

        viewModel.refreshDisplays()
        viewModel.autoRestoreIfNeeded()
        // 第一次恢复被确认(pending 清空;确认后本就进入冷却)
        viewModel.coordinator.confirmPending()
        // 模拟冷却过期
        viewModel.autoRestoreCooldowns[sidecarDisplay.stableID] = Date().addingTimeInterval(-1)
        viewModel.autoRestoreIfNeeded()
        XCTAssertEqual(controller.applyCalls.count, 2, "冷却过期后可再次发起")
    }

    func testRevertedModeClearsPreferenceAndCoolsDown() {
        var config = configStore.config
        config.perDisplay[sidecarDisplay.stableID] = PerDisplayConfig(modeKey: "2560x1600@60-hidpi")
        configStore.config = config

        viewModel.refreshDisplays()
        let target = sidecarDisplay.modes.first { $0.modeKey == "2560x1600@60-hidpi" }!
        viewModel.perform(.selectMode(displayStableID: sidecarDisplay.stableID, modeKey: target.modeKey))
        scheduler.fireLast()   // 超时回滚 = 用户否定

        XCTAssertNil(
            configStore.config.perDisplay[sidecarDisplay.stableID]?.modeKey,
            "拒绝后保存的偏好必须清除,否则自动恢复会无限重试"
        )
        // 偏好已清除 + 长冷却:自动恢复不再发起(applyCalls 保持 selectMode 的那一次)
        viewModel.autoRestoreIfNeeded()
        XCTAssertEqual(controller.applyCalls.count, 1, "拒绝后自动恢复不再发起")
    }

    // MARK: - 全局开关

    func testToggleAutoRestoreRoundTrip() {
        viewModel.refreshDisplays()
        XCTAssertTrue(configStore.config.autoRestore)
        viewModel.perform(.toggleAutoRestore)
        XCTAssertFalse(configStore.config.autoRestore)
        viewModel.perform(.toggleAutoRestore)
        XCTAssertTrue(configStore.config.autoRestore)
    }

    func testToggleLaunchAtLogin() {
        viewModel.refreshDisplays()
        viewModel.perform(.toggleLaunchAtLogin)
        XCTAssertEqual(loginItems.setCalls, [true])
        XCTAssertTrue(loginItems.isEnabled)
    }

    func testSetLogLevelUpdatesConfigAndLogger() {
        let sink = MemoryLogSink()
        let logger = DTLogger(sinks: [sink], level: .error)
        let vm = TunerViewModel(
            displayService: displayService,
            modeController: controller,
            configStore: configStore,
            loginItems: loginItems,
            countdownScheduler: scheduler,
            logger: logger
        )
        vm.refreshDisplays()

        vm.perform(.setLogLevel(.debug))

        XCTAssertEqual(configStore.config.logLevel, .debug)
        XCTAssertEqual(logger.level, .debug)
    }

    // MARK: - 实验开关

    func testToggleExperimentalSidecarProbesAndEnablesExtraModes() {
        viewModel.refreshDisplays()
        let enhancerService = StubDisplayService()
        enhancerService.displays = [sidecarDisplay]
        enhancerService.hiddenRawModes[sidecarDisplay.displayID] = [Fixtures.mode(2048, 1536)]
        let symbolStub = StubSymbolLookup()
        symbolStub.libraryAvailable = false
        let enhancer = ExperimentalSidecarEnhancer(
            displayService: enhancerService,
            privateServices: PrivateDisplayServices(
                lookup: symbolStub,
                logger: DTLogger(sinks: [MemoryLogSink()])
            ),
            logger: DTLogger(sinks: [MemoryLogSink()])
        )
        let vm = makeViewModel(enhancer: enhancer)
        vm.refreshDisplays()

        XCTAssertNil(enhancer.lastProbeReport, "未开启前不探测")

        vm.perform(.toggleExperimentalSidecar)

        XCTAssertTrue(configStore.config.experimentalSidecar)
        XCTAssertNotNil(enhancer.lastProbeReport, "开启后立即探测")
        XCTAssertFalse(enhancer.lastProbeReport!.isAvailable)
        // 主枚举服务的显示器仍是 sidecar → enhancer 用自己的 stub 服务找到额外模式
        XCTAssertEqual(vm.extraModes[sidecarDisplay.stableID]?.map(\.modeKey), ["2048x1536@60-hidpi"])

        vm.perform(.toggleExperimentalSidecar)
        XCTAssertFalse(configStore.config.experimentalSidecar)
        XCTAssertTrue(vm.extraModes.isEmpty, "关闭后清空增强模式")
    }

    // MARK: - 恢复默认

    func testRestoreDefaultPicksDefaultFlaggedMode() {
        // builtin fixture 当前是 1512(推荐第一),构造带 default 标志的低分辨率模式
        var record = Fixtures.sidecarDisplay(modes: [
            Fixtures.mode(1920, 1080),
            Fixtures.mode(1280, 720, ioFlags: DisplayModeIOFlags.valid | DisplayModeIOFlags.safe | DisplayModeIOFlags.defaultFlag),
        ])
        record = RawDisplayRecord(
            displayID: record.displayID,
            vendorNumber: record.vendorNumber,
            modelNumber: record.modelNumber,
            serialNumber: record.serialNumber,
            name: record.name,
            bounds: record.bounds,
            isMain: record.isMain,
            isBuiltin: record.isBuiltin,
            currentModeIndex: 0,
            modes: record.modes
        )
        let display = DisplayCatalog.display(from: record)
        displayService.displays = [display]
        controller.currentModes[display.displayID] = display.currentMode

        viewModel.refreshDisplays()
        viewModel.perform(.restoreDefaultMode(displayStableID: display.stableID))

        XCTAssertEqual(controller.applyCalls.count, 1)
        XCTAssertTrue(controller.applyCalls[0].hasPrefix("1280x720@60"))
    }
}
