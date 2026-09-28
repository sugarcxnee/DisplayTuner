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
        seeder = MockSeeder()

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

    private var seeder: MockSeeder!

    private func makeViewModel(enhancer: SidecarEnhancer? = nil) -> TunerViewModel {
        TunerViewModel(
            displayService: displayService,
            modeController: controller,
            configStore: configStore,
            loginItems: loginItems,
            enhancer: enhancer,
            virtualDisplayFactory: virtualFactory,
            mirrorService: virtualMirror,
            displaySeeder: seeder,
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

        // 模拟 iPad 断开:枚举只剩内置屏。
        // 断开需连续两次枚举确认(第一次视为镜像重组瞬态,见 v0.2.4)
        displayService.displays = [DisplayCatalog.display(from: Fixtures.builtinDisplay())]
        viewModel.refreshDisplays()
        XCTAssertNotNil(viewModel.virtualDisplayCoordinator.activeSession, "第一次缺失视为瞬态")

        viewModel.refreshDisplays()
        XCTAssertEqual(virtualMirror.unmirrored.count, 1, "连续两次缺失应触发停止")
        XCTAssertEqual(virtualFactory.destroyedIDs.count, 1)
        XCTAssertNil(viewModel.virtualDisplayCoordinator.activeSession)
    }

    func testStartVirtualDisplayRegistersFullModeTable() {
        viewModel.refreshDisplays()
        // sidecar 当前 1920x1080 → 档位表 2880x1620 / 3840x2160 / 4800x2700
        viewModel.perform(.startVirtualDisplay(
            displayStableID: sidecarDisplay.stableID,
            width: 3840,
            height: 2160
        ))

        XCTAssertEqual(virtualFactory.modeTables.count, 1)
        XCTAssertEqual(virtualFactory.modeTables[0].map(\.key), ["3840x2160", "2880x1620", "4800x2700"],
                       "模式表必须含全部档位,否则运行中切档会被拉回")
    }

    func testSwitchResolutionWhileRunningDoesNotRebuild() {
        viewModel.refreshDisplays()
        viewModel.perform(.startVirtualDisplay(
            displayStableID: sidecarDisplay.stableID,
            width: 3840,
            height: 2160
        ))
        viewModel.perform(.startVirtualDisplay(
            displayStableID: sidecarDisplay.stableID,
            width: 2880,
            height: 1620
        ))

        XCTAssertEqual(virtualFactory.createdSpecs.count, 1, "切档不重建")
        XCTAssertEqual(virtualFactory.destroyedIDs.count, 0)
        XCTAssertEqual(virtualFactory.activateCalls, ["101:2880x1620"])
        XCTAssertEqual(virtualMirror.mirrored.count, 1, "镜像不被打断")
    }

    func testResolutionChangedUpdatesPreference() {
        viewModel.refreshDisplays()
        viewModel.perform(.startVirtualDisplay(
            displayStableID: sidecarDisplay.stableID,
            width: 3840,
            height: 2160
        ))
        viewModel.perform(.startVirtualDisplay(
            displayStableID: sidecarDisplay.stableID,
            width: 2880,
            height: 1620
        ))

        XCTAssertEqual(configStore.config.perDisplay[sidecarDisplay.stableID]?.virtualDisplayWidth, 2880)
        XCTAssertEqual(configStore.config.perDisplay[sidecarDisplay.stableID]?.virtualDisplayHeight, 1620)
    }

    func testSelectModeRejectedWhileMirroringVirtualDisplay() {
        viewModel.refreshDisplays()
        viewModel.perform(.startVirtualDisplay(
            displayStableID: sidecarDisplay.stableID,
            width: 3840,
            height: 2160
        ))
        let target = sidecarDisplay.modes.first { !$0.isCurrent }!

        viewModel.perform(.selectMode(
            displayStableID: sidecarDisplay.stableID,
            modeKey: target.modeKey
        ))

        XCTAssertTrue(controller.applyCalls.isEmpty, "镜像期间 Sidecar 模式切换必须被拦截")
    }

    func testAutoRestoreSkipsSidecarMirroringVirtualDisplay() {
        var config = configStore.config
        config.perDisplay[sidecarDisplay.stableID] = PerDisplayConfig(
            modeKey: sidecarDisplay.modes.first { !$0.isCurrent }?.modeKey
        )
        configStore.config = config

        viewModel.refreshDisplays()
        viewModel.perform(.startVirtualDisplay(
            displayStableID: sidecarDisplay.stableID,
            width: 3840,
            height: 2160
        ))
        viewModel.autoRestoreIfNeeded()

        XCTAssertTrue(controller.applyCalls.isEmpty,
                      "镜像会话中的 Sidecar 不能自动恢复模式(会和镜像约束打架)")
    }

    // MARK: - 瞬态与镜像保护(v0.2.4)

    func testTransientSidecarDisappearDoesNotStopSession() {
        let fullList = displayService.displays
        viewModel.refreshDisplays()
        viewModel.perform(.startVirtualDisplay(
            displayStableID: sidecarDisplay.stableID,
            width: 2360,
            height: 1640
        ))

        // 第一次枚举缺失(镜像重组瞬态):不应停止会话
        displayService.displays = fullList.filter { !$0.isSidecar }
        viewModel.refreshDisplays()
        XCTAssertNotNil(viewModel.virtualDisplayCoordinator.activeSession, "瞬态缺失不应停止会话")

        // 第二次仍缺失:判定真正断开,停止并清理
        viewModel.refreshDisplays()
        XCTAssertNil(viewModel.virtualDisplayCoordinator.activeSession, "连续两次缺失应停止会话")
        XCTAssertEqual(virtualFactory.destroyedIDs.count, 1)
    }

    func testTransientDisappearThenReappearResetsCounter() {
        let fullList = displayService.displays
        viewModel.refreshDisplays()
        viewModel.perform(.startVirtualDisplay(
            displayStableID: sidecarDisplay.stableID,
            width: 2360,
            height: 1640
        ))

        // 缺一次 → 回来 → 再缺一次:仍不算连续两次
        displayService.displays = fullList.filter { !$0.isSidecar }
        viewModel.refreshDisplays()
        displayService.displays = fullList
        viewModel.refreshDisplays()
        displayService.displays = fullList.filter { !$0.isSidecar }
        viewModel.refreshDisplays()
        XCTAssertNotNil(viewModel.virtualDisplayCoordinator.activeSession, "非连续缺失不停止")

        // 第四次(连续第二次缺失)才停
        viewModel.refreshDisplays()
        XCTAssertNil(viewModel.virtualDisplayCoordinator.activeSession)
    }

    func testAutoRestoreSkipsAnyMirroredDisplayEvenWithoutSessionMatch() {
        // 场景:会话挂在 Sidecar A 上,但枚举里另一台处于镜像组的显示器 B
        // 也不应被自动恢复(双重保护:不只依赖会话稳定 ID 匹配)
        let mirroredOther = DisplayCatalog.display(from: Fixtures.sidecarDisplay(displayID: 33))
        var config = configStore.config
        config.perDisplay[mirroredOther.stableID] = PerDisplayConfig(
            modeKey: mirroredOther.modes.first { !$0.isCurrent }?.modeKey
        )
        configStore.config = config

        viewModel.refreshDisplays()
        viewModel.perform(.startVirtualDisplay(
            displayStableID: sidecarDisplay.stableID,
            width: 2360,
            height: 1640
        ))
        // 让 mirroredOther 进入镜像组(MockMirrorService 状态)
        try? virtualMirror.mirror(display: mirroredOther.displayID, toMaster: 101)

        displayService.displays.append(mirroredOther)
        viewModel.refreshDisplays()
        viewModel.autoRestoreIfNeeded()

        XCTAssertTrue(controller.applyCalls.isEmpty, "镜像组内的显示器一律不做自动恢复")
    }

    // MARK: - 自动恢复节流(v0.2.5)

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

    func testAutoRestoreGivesUpAfterRepeatedConfirms() {
        var config = configStore.config
        config.perDisplay[sidecarDisplay.stableID] = PerDisplayConfig(modeKey: "2560x1600@60-hidpi")
        configStore.config = config
        viewModel.refreshDisplays()

        // 模拟系统反复对抗:确认 3 次后,第 4 轮自动恢复放弃
        for _ in 0..<3 {
            viewModel.autoRestoreIfNeeded()
            viewModel.coordinator.confirmPending()
            // 模拟系统拉回 + 冷却过期
            viewModel.autoRestoreCooldowns[sidecarDisplay.stableID] = Date().addingTimeInterval(-1)
        }
        XCTAssertEqual(controller.applyCalls.count, 3)

        viewModel.autoRestoreIfNeeded()
        XCTAssertEqual(controller.applyCalls.count, 3, "达到放弃阈值后不再发起,避免与系统对抗循环")
    }

    func testSeedHighResolutionModesDispatchesToSeeder() {
        viewModel.refreshDisplays()
        viewModel.perform(.seedHighResolutionModes(displayStableID: sidecarDisplay.stableID))

        XCTAssertEqual(seeder.seedCalls, [sidecarDisplay.stableID])
    }

    func testSeedFailingDoesNotCrashAndRefreshes() {
        seeder.error = VirtualDisplayError.classesUnavailable(["CGVirtualDisplay"])
        viewModel.refreshDisplays()
        viewModel.perform(.seedHighResolutionModes(displayStableID: sidecarDisplay.stableID))

        XCTAssertEqual(seeder.seedCalls.count, 1)
        XCTAssertFalse(viewModel.menuModel.entries.isEmpty, "失败后菜单仍刷新")
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
