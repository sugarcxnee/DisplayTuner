import AppKit
import DisplayTunerCore

/// 依赖装配 + 生命周期。无主窗口、无 Settings —— 纯菜单栏应用。
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var logger: DTLogger!
    private var viewModel: TunerViewModel!
    private var menuBar: MenuBarController!
    private var alertPresenter: SafetyAlertPresenter!
    private var screenChangeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 日志先行:控制台 + Application Support 轮转文件
        logger = DTLogger.makeDefault()

        // 依赖装配(core 全部通过协议注入,无单例耦合)
        let configStore = JSONFileConfigStore(logger: logger)
        logger.setLevel(configStore.config.logLevel)

        let nameProvider = NSScreenNameProvider()
        let displayService = CoreGraphicsDisplayService(
            nameProvider: { id in nameProvider.name(for: id) },
            logger: logger
        )
        let modeController = CoreGraphicsDisplayModeController(logger: logger)
        let enhancer = ExperimentalSidecarEnhancer(
            displayService: displayService,
            privateServices: PrivateDisplayServices(logger: logger),
            logger: logger
        )
        let loginItems = SMAppServiceLoginItem()

        viewModel = TunerViewModel(
            displayService: displayService,
            modeController: modeController,
            configStore: configStore,
            loginItems: loginItems,
            enhancer: enhancer,
            logger: logger
        )

        // 模式变更结果 → 安全确认框(applied 时弹出,reverted/failed 时收起)
        alertPresenter = SafetyAlertPresenter(
            coordinator: viewModel.coordinator,
            displaysProvider: { [weak viewModel] in viewModel?.displays ?? [] },
            logger: logger
        )
        viewModel.onOutcome = { [weak self] outcome in
            self?.alertPresenter.handle(outcome)
        }

        // 菜单栏(唯一的"界面")
        let router = ActionRouter(
            performCore: { [weak viewModel] action in
                viewModel?.perform(action)
            },
            performAppLevel: { [weak self] action in
                self?.handleAppLevelAction(action)
            }
        )
        menuBar = MenuBarController(viewModel: viewModel, router: router, logger: logger)

        // 显示器热插拔 / Sidecar 连接断开 → 刷新 + 自动恢复
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.logger.info("screen parameters changed", context: "App")
            self.viewModel.refreshDisplays()
            self.viewModel.autoRestoreIfNeeded()
        }

        // 启动即枚举;自动恢复稍后一拍,让状态先就绪
        viewModel.refreshDisplays()
        DispatchQueue.main.async { [weak self] in
            self?.viewModel.autoRestoreIfNeeded()
        }

        logger.info("DisplayTuner started (menu bar only)", context: "App")
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        logger.info("DisplayTuner terminating", context: "App")
    }

    // MARK: - App 级动作

    private func handleAppLevelAction(_ action: MenuAction) {
        switch action {
        case .openLogFile:
            let url = LogLocations.logFileURL()
            // 日志文件可能尚未创建,先确保目录存在
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if NSWorkspace.shared.open(url) {
                logger.info("opened log file", context: "App")
            } else {
                logger.error("failed to open log file", context: "App")
            }

        case .showAbout:
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(nil)

        case .quit:
            NSApp.terminate(nil)

        default:
            break
        }
    }
}
