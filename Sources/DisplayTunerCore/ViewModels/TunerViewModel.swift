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
    /// 高分辨率播种器(一次性流程,详见 SeedEngine)。
    private let seeder: SidecarSeeding

    /// 模式变更结果的外部观察点:App 壳用它驱动安全确认框(NSAlert)。
    public var onOutcome: ((ModeChangeOutcome) -> Void)?

    private let displayService: DisplayService
    private let configStore: ConfigStore
    private let enhancer: SidecarEnhancer?
    private let loginItems: LoginItemControlling
    private let menuBuilder: MenuModelBuilder
    private let logger: DTLogger

    public init(
        displayService: DisplayService,
        modeController: DisplayModeController,
        configStore: ConfigStore,
        loginItems: LoginItemControlling,
        enhancer: SidecarEnhancer? = nil,
        displaySeeder: SidecarSeeding? = nil,
        countdownScheduler: CountdownScheduler = DispatchCountdownScheduler(),
        logger: DTLogger = DTLogger()
    ) {
        self.displayService = displayService
        self.configStore = configStore
        self.enhancer = enhancer
        self.seeder = displaySeeder ?? SeedEngine(
            factory: CoreDisplayVirtualDisplayFactory(logger: logger),
            mirror: CoreGraphicsMirrorService(logger: logger),
            logger: logger
        )
        self.loginItems = loginItems
        self.menuBuilder = MenuModelBuilder()
        self.logger = logger
        self.coordinator = ModeChangeCoordinator(
            controller: modeController,
            scheduler: countdownScheduler,
            logger: logger
        )
        self.coordinator.delegate = self
    }

    public var config: DisplayTunerConfig { configStore.config }

    // MARK: - 刷新与菜单

    /// 菜单即将打开时调用:重新枚举 + 重建菜单(规格 2:避免状态过期)。
    @discardableResult
    public func refreshDisplays() -> MenuModel {
        displays = displayService.snapshotDisplays()
        refreshExtraModesIfNeeded()
        rebuildMenu()
        return menuModel
    }

    public func rebuildMenu() {
        let probe = config.experimentalSidecar
            ? (enhancer?.lastProbeReport ?? enhancer?.probePrivateStatus())
            : nil
        menuModel = menuBuilder.build(
            displays: displays,
            config: configStore.config,
            loginItemEnabled: loginItems.isEnabled,
            privateProbe: probe,
            extraModes: extraModes
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

        case .seedHighResolutionModes(let stableID):
            seedHighResolutionModes(on: stableID)

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

    // MARK: - 播种

    /// 解锁高分辨率模式:一次性播种流程,之后高档直接出现在模式列表。
    /// 无需确认框(全程可逆,收尾回原生档)。
    private func seedHighResolutionModes(on stableID: String) {
        guard let display = displays.first(where: { $0.stableID == stableID && $0.isSidecar }) else {
            logger.error(
                "seeding target \(PrivacyRedactor.shortHash(stableID)) is not a connected sidecar",
                context: "ViewModel"
            )
            return
        }
        do {
            let outcome = try seeder.seedHighResolutionModes(on: display)
            switch outcome {
            case .alreadyUnlocked:
                logger.info("already unlocked — no seeding needed", context: "ViewModel")
            case .seeded:
                logger.info("high-resolution modes unlocked — refresh to see them", context: "ViewModel")
            }
        } catch {
            logger.error("unlock high-resolution failed: \(error)", context: "ViewModel")
        }
        refreshDisplays()
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

    /// 自动恢复的冷却截止时间(按稳定 ID)。系统可能持续把显示器拉回
    /// 它不认可的模式,无节制的自动恢复会与系统打乒乓导致无限弹窗
    /// —— 冷却窗口内不再发起恢复。
    var autoRestoreCooldowns: [String: Date] = [:]
    /// 同一显示器本次运行内自动恢复被确认的次数;达到上限后放弃
    /// (说明系统在持续对抗该模式)。
    private var autoRestoreConfirmCounts: [String: Int] = [:]
    /// 自动恢复冷却时长与放弃阈值。
    static let autoRestoreCooldown: TimeInterval = 120
    static let autoRestoreRevertCooldown: TimeInterval = 600
    static let autoRestoreGiveUpAfterConfirms = 3

    /// 启动与显示器变化时调用:按稳定 ID 恢复已保存且与当前不同的模式。
    /// 走与手动选择完全相同的安全倒计时路径。
    public func autoRestoreIfNeeded() {
        guard configStore.config.autoRestore else { return }
        // 用户主动切换尚在确认窗口内:新意图优先,恢复不得反打
        // (真机表现:切档 1.5 秒后被恢复 supersede 拉回旧偏好,偏好还被误清)
        let pendingStableID = coordinator.pendingChange?.displayStableID
        for display in displays {
            if display.stableID == pendingStableID { continue }
            guard let savedKey = configStore.config.perDisplay[display.stableID]?.modeKey else {
                continue
            }
            guard let current = display.currentMode, current.modeKey != savedKey else {
                continue
            }
            // 冷却窗口内或已达放弃阈值:不再发起(防与系统对抗循环)
            if let until = autoRestoreCooldowns[display.stableID], Date() < until {
                continue
            }
            if autoRestoreConfirmCounts[display.stableID, default: 0]
                >= Self.autoRestoreGiveUpAfterConfirms {
                logger.info(
                    "auto-restore for \(display.logDescriptor) gave up after \(Self.autoRestoreGiveUpAfterConfirms) confirms (system keeps reverting)",
                    context: "ViewModel"
                )
                continue
            }
            autoRestoreCooldowns[display.stableID] = Date().addingTimeInterval(Self.autoRestoreCooldown)
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
            // 确认后进入冷却:若系统随即将模式拉回,冷却窗口内的
            // 自动恢复不再打扰;连续确认多次则本会话放弃
            autoRestoreCooldowns[stableID] = Date().addingTimeInterval(Self.autoRestoreCooldown)
            autoRestoreConfirmCounts[stableID, default: 0] += 1
        case .reverted(let stableID, _, _):
            // 用户拒绝(或超时)即明确否定该偏好:清除保存的模式并长冷却,
            // 否则系统把模式拉回后自动恢复会无限重试、弹窗循环
            var config = configStore.config
            if var perDisplay = config.perDisplay[stableID] {
                perDisplay.modeKey = nil
                config.perDisplay[stableID] = perDisplay
                configStore.save(config)
            }
            autoRestoreCooldowns[stableID] = Date().addingTimeInterval(Self.autoRestoreRevertCooldown)
            logger.info(
                "mode change reverted for \(PrivacyRedactor.shortHash(stableID)) — cleared saved preference, cooling down auto-restore",
                context: "ViewModel"
            )
        case .applied, .failed:
            break
        }
        refreshDisplays()
    }
}
