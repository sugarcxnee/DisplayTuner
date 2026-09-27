import Foundation

/// 主 ViewModel:串联枚举、切换、配置、日志、登录项,产出菜单模型。
/// AppKit 层只做"模型 → NSMenu"翻译和动作转发,本类不 import AppKit。
/// 预期在主线程使用。
public final class TunerViewModel {

    public private(set) var displays: [DisplayInfo] = []
    public private(set) var menuModel = MenuModel(entries: [])
    /// 每显示器实验增强揭示的额外模式(稳定 ID 索引)。
    public private(set) var extraModes: [String: [DisplayModeInfo]] = [:]
    public private(set) var lastOutcome: ModeChangeOutcome?

    public let coordinator: ModeChangeCoordinator
    public let virtualDisplayCoordinator: VirtualDisplayCoordinator

    /// 模式变更结果的外部观察点:App 壳用它驱动安全确认框(NSAlert)。
    public var onOutcome: ((ModeChangeOutcome) -> Void)?
    /// 虚拟屏会话结果的外部观察点:App 壳用它驱动安全确认框。
    public var onVirtualOutcome: ((VirtualDisplayOutcome) -> Void)?

    private let displayService: DisplayService
    private let configStore: ConfigStore
    private let enhancer: SidecarEnhancer?
    private let loginItems: LoginItemControlling
    private let virtualFactory: VirtualDisplayCreating
    private let menuBuilder: MenuModelBuilder
    private let logger: DTLogger

    public init(
        displayService: DisplayService,
        modeController: DisplayModeController,
        configStore: ConfigStore,
        loginItems: LoginItemControlling,
        enhancer: SidecarEnhancer? = nil,
        virtualDisplayFactory: VirtualDisplayCreating = CoreDisplayVirtualDisplayFactory(),
        mirrorService: DisplayMirrorControlling = CoreGraphicsMirrorService(),
        countdownScheduler: CountdownScheduler = DispatchCountdownScheduler(),
        virtualCountdownScheduler: CountdownScheduler = DispatchCountdownScheduler(),
        logger: DTLogger = DTLogger()
    ) {
        self.displayService = displayService
        self.configStore = configStore
        self.enhancer = enhancer
        self.loginItems = loginItems
        self.virtualFactory = virtualDisplayFactory
        self.menuBuilder = MenuModelBuilder()
        self.logger = logger
        self.coordinator = ModeChangeCoordinator(
            controller: modeController,
            scheduler: countdownScheduler,
            logger: logger
        )
        self.virtualDisplayCoordinator = VirtualDisplayCoordinator(
            factory: virtualDisplayFactory,
            mirror: mirrorService,
            scheduler: virtualCountdownScheduler,
            logger: logger
        )
        // 所有存储属性就绪后再挂 delegate(delegate 回调可能触发布局)
        self.coordinator.delegate = self
        self.virtualDisplayCoordinator.delegate = self
    }

    public var config: DisplayTunerConfig { configStore.config }

    // MARK: - 刷新与菜单

    /// 菜单即将打开时调用:重新枚举 + 重建菜单(规格 2:避免状态过期)。
    @discardableResult
    public func refreshDisplays() -> MenuModel {
        // 我们自己创建的虚拟屏不进菜单(它只是镜像的载体)
        let virtualID = virtualDisplayCoordinator.activeVirtualDisplayID
        displays = displayService.snapshotDisplays().filter { $0.displayID != virtualID }

        // Sidecar 断开(或断开后稳定 ID 消失):结束虚拟屏会话
        if let activeSidecar = virtualDisplayCoordinator.activeSession,
           !displays.contains(where: { $0.stableID == activeSidecar.sidecarStableID }) {
            virtualDisplayCoordinator.stop(reason: .sidecarDisconnected)
        }

        refreshExtraModesIfNeeded()
        rebuildMenu()
        return menuModel
    }

    public func rebuildMenu() {
        let probe = config.experimentalSidecar
            ? (enhancer?.lastProbeReport ?? enhancer?.probePrivateStatus())
            : nil
        var activeVirtual: [String: VirtualDisplaySessionInfo] = [:]
        if let session = virtualDisplayCoordinator.activeSession {
            activeVirtual[session.sidecarStableID] = session
        }
        menuModel = menuBuilder.build(
            displays: displays,
            config: configStore.config,
            loginItemEnabled: loginItems.isEnabled,
            privateProbe: probe,
            extraModes: extraModes,
            activeVirtualDisplays: activeVirtual,
            virtualDisplayAvailability: virtualFactory.availability()
        )
    }

    /// 实验增强开启时,为 Sidecar 显示器揭示隐藏模式。
    private func refreshExtraModesIfNeeded() {
        guard let enhancer = enhancer else { return }
        guard configStore.config.experimentalSidecar else {
            if !extraModes.isEmpty { extraModes = [:] }
            return
        }
        var collected: [String: [DisplayModeInfo]] = [:]
        for display in displays where display.isSidecar {
            collected[display.stableID] = enhancer.extraModes(for: display)
        }
        extraModes = collected
    }

    // MARK: - 动作分发

    public func perform(_ action: MenuAction) {
        switch action {
        case .refresh:
            refreshDisplays()

        case .selectMode(let stableID, let modeKey):
            selectMode(modeKey, on: stableID)

        case .toggleFilter(let stableID, let filter):
            toggleFilter(filter, on: stableID)

        case .restoreDefaultMode(let stableID):
            restoreDefaultMode(on: stableID)

        case .startVirtualDisplay(let stableID, let width, let height):
            startVirtualDisplay(width: width, height: height, on: stableID)

        case .stopVirtualDisplay(let stableID):
            guard virtualDisplayCoordinator.activeSession?.sidecarStableID == stableID else { return }
            virtualDisplayCoordinator.stop(reason: .userRequested)

        case .toggleExperimentalSidecar:
            toggleExperimentalSidecar()

        case .toggleAutoRestore:
            var config = configStore.config
            config.autoRestore.toggle()
            configStore.save(config)
            logger.info("autoRestore = \(config.autoRestore)", context: "ViewModel")
            rebuildMenu()

        case .toggleLaunchAtLogin:
            let target = !loginItems.isEnabled
            if loginItems.setEnabled(target) {
                logger.info("launch at login = \(target)", context: "ViewModel")
            } else {
                logger.error("failed to set launch at login = \(target)", context: "ViewModel")
            }
            rebuildMenu()

        case .setLogLevel(let level):
            var config = configStore.config
            config.logLevel = level
            configStore.save(config)
            logger.setLevel(level)
            logger.info("log level = \(level.label)", context: "ViewModel")
            rebuildMenu()

        case .openLogFile, .showAbout, .quit:
            // 这三个动作由 App 壳处理(打开文件/关于面板/终止应用)
            break
        }
    }

    // MARK: - 模式选择

    public func selectMode(_ modeKey: String, on stableID: String) {
        // 镜像会话中的 Sidecar:模式由虚拟屏决定,手动切换会被镜像约束拉回
        if virtualDisplayCoordinator.activeSession?.sidecarStableID == stableID {
            logger.info(
                "mode change rejected for \(PrivacyRedactor.shortHash(stableID)): mirroring virtual display",
                context: "ViewModel"
            )
            return
        }
        guard let display = displays.first(where: { $0.stableID == stableID }) else {
            logger.error("display \(PrivacyRedactor.shortHash(stableID)) vanished before applying", context: "ViewModel")
            return
        }
        // 优先常规列表,其次实验增强列表
        let candidates = display.modes + (extraModes[stableID] ?? [])
        guard let mode = candidates.first(where: { $0.modeKey == modeKey }) else {
            logger.error("mode \(modeKey) not found on \(display.logDescriptor)", context: "ViewModel")
            return
        }
        coordinator.request(mode: mode, on: display)
    }

    private func toggleFilter(_ filter: ModeFilter, on stableID: String) {
        var config = configStore.config
        var perDisplay = config.perDisplay[stableID] ?? PerDisplayConfig()
        if perDisplay.filters.contains(filter) {
            perDisplay.filters.remove(filter)
        } else {
            perDisplay.filters.insert(filter)
        }
        config.perDisplay[stableID] = perDisplay
        configStore.save(config)
        rebuildMenu()
    }

    private func restoreDefaultMode(on stableID: String) {
        guard let display = displays.first(where: { $0.stableID == stableID }) else { return }
        // 默认模式 = 系统标记 kDisplayModeDefaultFlag 的模式;找不到则回退排序第一的安全模式
        let target = display.modes.first {
            $0.ioFlags & DisplayModeIOFlags.defaultFlag != 0
        } ?? display.modes.filter(\.isSafe).first

        guard let target = target else {
            logger.error("no restorable default mode on \(display.logDescriptor)", context: "ViewModel")
            return
        }
        if target.modeKey == display.currentMode?.modeKey {
            logger.info("already at default mode", context: "ViewModel")
            return
        }
        coordinator.request(mode: target, on: display)
    }

    // MARK: - 虚拟屏

    private func startVirtualDisplay(width: Int, height: Int, on stableID: String) {
        // 已有会话 → 原地切档(模式表在创建时已含全部档位)
        if let active = virtualDisplayCoordinator.activeSession, active.sidecarStableID == stableID {
            virtualDisplayCoordinator.changeResolution(
                to: VirtualDisplaySpec(width: width, height: height)
            )
            return
        }
        guard let display = displays.first(where: { $0.stableID == stableID && $0.isSidecar }) else {
            logger.error(
                "virtual display target \(PrivacyRedactor.shortHash(stableID)) is not a connected sidecar",
                context: "ViewModel"
            )
            return
        }
        let spec = VirtualDisplaySpec(width: width, height: height)
        // 模式表包含全部档位,运行中可原地切换(单模式表会导致"切一下被拉回")
        let table = VirtualDisplayPresets.presets(for: display).map(\.spec)
        virtualDisplayCoordinator.start(spec: spec, additionalModes: table, mirroring: display)
    }

    private func toggleExperimentalSidecar() {
        var config = configStore.config
        config.experimentalSidecar.toggle()
        configStore.save(config)
        logger.info("experimental sidecar enhancement = \(config.experimentalSidecar)", context: "ViewModel")
        if config.experimentalSidecar {
            _ = enhancer?.probePrivateStatus()
        } else {
            extraModes = [:]
        }
        refreshExtraModesIfNeeded()
        rebuildMenu()
    }

    // MARK: - 自动恢复

    /// 启动与显示器变化时调用:按稳定 ID 恢复已保存且与当前不同的模式。
    /// 走与手动选择完全相同的安全倒计时路径。
    public func autoRestoreIfNeeded() {
        guard configStore.config.autoRestore else { return }
        for display in displays {
            // 镜像会话中的 Sidecar:自动恢复会与镜像约束打架,跳过
            if virtualDisplayCoordinator.activeSession?.sidecarStableID == display.stableID {
                continue
            }
            guard let savedKey = configStore.config.perDisplay[display.stableID]?.modeKey else {
                continue
            }
            guard let current = display.currentMode, current.modeKey != savedKey else {
                continue
            }
            let candidates = display.modes + (extraModes[display.stableID] ?? [])
            guard let target = candidates.first(where: { $0.modeKey == savedKey }) else {
                logger.info(
                    "saved mode \(savedKey) no longer available on \(display.logDescriptor), skipping",
                    context: "ViewModel"
                )
                continue
            }
            logger.info(
                "auto-restoring \(savedKey) on \(display.logDescriptor)",
                context: "ViewModel"
            )
            coordinator.request(mode: target, on: display)
            return   // 一次只恢复一台,确认后再处理下一台
        }
    }

    // MARK: - 导入导出(菜单与命令行共用)

    public func exportConfig(to url: URL) throws {
        try configStore.exportConfig(to: url)
    }

    public func importConfig(from url: URL) throws {
        try configStore.importConfig(from: url)
        logger.setLevel(configStore.config.logLevel)
        refreshDisplays()
    }
}

// MARK: - ModeChangeCoordinatorDelegate

extension TunerViewModel: ModeChangeCoordinatorDelegate {

    public func coordinator(_ coordinator: ModeChangeCoordinator, didProduce outcome: ModeChangeOutcome) {
        lastOutcome = outcome
        onOutcome?(outcome)
        switch outcome {
        case .confirmed(let stableID, let modeKey):
            // 只有用户确认保留的模式才写入持久化配置
            var config = configStore.config
            var perDisplay = config.perDisplay[stableID] ?? PerDisplayConfig()
            perDisplay.modeKey = modeKey
            config.perDisplay[stableID] = perDisplay
            configStore.save(config)
        case .applied, .reverted, .failed:
            break
        }
        refreshDisplays()
    }
}

// MARK: - VirtualDisplayCoordinatorDelegate

extension TunerViewModel: VirtualDisplayCoordinatorDelegate {

    public func virtualDisplayCoordinator(
        _ coordinator: VirtualDisplayCoordinator,
        didProduce outcome: VirtualDisplayOutcome
    ) {
        onVirtualOutcome?(outcome)
        switch outcome {
        case .confirmed(let spec, let stableID), .resolutionChanged(let spec, let stableID):
            // 记录用户确认/选择的虚拟屏偏好(仅偏好,不做开机自动重建)
            var config = configStore.config
            var perDisplay = config.perDisplay[stableID] ?? PerDisplayConfig()
            perDisplay.virtualDisplayWidth = spec.width
            perDisplay.virtualDisplayHeight = spec.height
            config.perDisplay[stableID] = perDisplay
            configStore.save(config)
        case .started, .stopped, .failed:
            break
        }
        refreshDisplays()
    }
}
