import XCTest
@testable import DisplayTunerCore

final class TunerViewModelTests: XCTestCase {

    private var displayService: MockDisplayService!
    private var controller: MockDisplayModeController!
    private var configStore: MockConfigStore!
    private var loginItems: MockLoginItem!
    private var scheduler: MockCountdownScheduler!
    private var virtualFactory: MockVirtualDisplayFactory!
    private var virtualMirror: MockMirrorService!
    private var virtualScheduler: MockCountdownScheduler!
    private var viewModel: TunerViewModel!

    override func setUp() {
        super.setUp()
        displayService = MockDisplayService()
        controller = MockDisplayModeController()
        configStore = MockConfigStore()
        loginItems = MockLoginItem()
        scheduler = MockCountdownScheduler()
        virtualFactory = MockVirtualDisplayFactory()
        virtualMirror = MockMirrorService()
        virtualScheduler = MockCountdownScheduler()

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
            virtualDisplayFactory: virtualFactory,
            mirrorService: virtualMirror,
            countdownScheduler: scheduler,
            virtualCountdownScheduler: virtualScheduler,
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

    // MARK: - 虚拟屏

    func testStartVirtualDisplayCreatesAndMirrors() {
        viewModel.refreshDisplays()

        viewModel.perform(.startVirtualDisplay(
            displayStableID: sidecarDisplay.stableID,
            width: 2360,
            height: 1640
        ))

        XCTAssertEqual(virtualFactory.createdSpecs.map(\.key), ["2360x1640"])
        XCTAssertEqual(virtualMirror.mirrored.map(\.display), [sidecarDisplay.displayID])
        XCTAssertTrue(viewModel.virtualDisplayCoordinator.hasPendingConfirmation)
    }

    func testStartVirtualDisplayRejectsNonSidecarTarget() {
        viewModel.refreshDisplays()
        let builtin = viewModel.displays.first { !$0.isSidecar }!

        viewModel.perform(.startVirtualDisplay(
            displayStableID: builtin.stableID,
            width: 2360,
            height: 1640
        ))

        XCTAssertTrue(virtualFactory.createdSpecs.isEmpty, "非 Sidecar 目标不允许开虚拟屏")
    }

    func testVirtualDisplayConfirmSavesPreference() {
        viewModel.refreshDisplays()
        viewModel.perform(.startVirtualDisplay(
            displayStableID: sidecarDisplay.stableID,
            width: 2360,
            height: 1640
        ))
        viewModel.virtualDisplayCoordinator.confirmActive()

        XCTAssertEqual(configStore.config.perDisplay[sidecarDisplay.stableID]?.virtualDisplayWidth, 2360)
        XCTAssertEqual(configStore.config.perDisplay[sidecarDisplay.stableID]?.virtualDisplayHeight, 1640)
    }

    func testVirtualDisplayTimeoutTearsDown() {
        viewModel.refreshDisplays()
        viewModel.perform(.startVirtualDisplay(
            displayStableID: sidecarDisplay.stableID,
            width: 2360,
            height: 1640
        ))
        virtualScheduler.fireLast()

        XCTAssertEqual(virtualMirror.unmirrored, [sidecarDisplay.displayID])
        XCTAssertEqual(virtualFactory.destroyedIDs.count, 1)
        XCTAssertNil(configStore.config.perDisplay[sidecarDisplay.stableID]?.virtualDisplayWidth,
                     "超时回滚不写偏好")
    }

    func testRefreshFiltersOutOwnVirtualDisplay() {
        viewModel.refreshDisplays()
        viewModel.perform(.startVirtualDisplay(
            displayStableID: sidecarDisplay.stableID,
            width: 2360,
            height: 1640
        ))
        let virtualID: UInt32 = 101   // MockVirtualDisplayFactory 首个句柄的 displayID

        // 模拟枚举服务把虚拟屏也报出来了
        let virtualDisplayInfo = DisplayInfo(
            stableID: "display-virtual-fake",
            displayID: virtualID,
            name: "DisplayTuner Virtual",
            category: .external,
            isMain: false,
            isBuiltin: false,
            bounds: .zero,
            rotation: 0,
            modes: [],
            currentMode: nil
        )
        displayService.displays.append(virtualDisplayInfo)

        viewModel.refreshDisplays()

        XCTAssertFalse(
            viewModel.displays.contains { $0.displayID == virtualID },
            "自己创建的虚拟屏不应出现在菜单里"
        )
    }

    func testSidecarDisconnectedStopsVirtualDisplay() {
        viewModel.refreshDisplays()
        viewModel.perform(.startVirtualDisplay(
            displayStableID: sidecarDisplay.stableID,
            width: 2360,
            height: 1640
        ))

        // 模拟 iPad 断开:枚举只剩内置屏
        displayService.displays = [DisplayCatalog.display(from: Fixtures.builtinDisplay())]
        viewModel.refreshDisplays()

        XCTAssertEqual(virtualMirror.unmirrored.count, 1, "Sidecar 消失应触发停止")
        XCTAssertEqual(virtualFactory.destroyedIDs.count, 1)
        XCTAssertNil(viewModel.virtualDisplayCoordinator.activeSession)
    }

    func testStopVirtualDisplayViaMenu() {
        viewModel.refreshDisplays()
        viewModel.perform(.startVirtualDisplay(
            displayStableID: sidecarDisplay.stableID,
            width: 2360,
            height: 1640
        ))
        viewModel.perform(.stopVirtualDisplay(displayStableID: sidecarDisplay.stableID))

        XCTAssertEqual(virtualMirror.unmirrored.count, 1)
        XCTAssertEqual(virtualFactory.destroyedIDs.count, 1)
    }
}
