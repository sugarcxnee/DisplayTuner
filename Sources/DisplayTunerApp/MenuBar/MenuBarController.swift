import AppKit
import DisplayTunerCore

/// 菜单栏控制器:拥有 NSStatusItem,每次菜单打开时重新枚举并重建菜单(规格 2)。
final class MenuBarController: NSObject, NSMenuDelegate {

    private let viewModel: TunerViewModel
    private let router: ActionRouter
    private let assembler: NSMenuAssembler
    private let logger: DTLogger
    private let statusItem: NSStatusItem

    init(
        viewModel: TunerViewModel,
        router: ActionRouter,
        logger: DTLogger
    ) {
        self.viewModel = viewModel
        self.router = router
        self.logger = logger
        self.assembler = NSMenuAssembler(
            target: router,
            action: #selector(ActionRouter.performMenuItem(_:))
        )

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            if let image = NSImage(
                systemSymbolName: "display",
                accessibilityDescription: "DisplayTuner"
            ) {
                button.image = image
            } else {
                button.title = "DT"
            }
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        statusItem = item

        super.init()

        menu.delegate = self
        item.menu = menu
    }

    /// NSMenuDelegate:菜单即将展开 —— 重新枚举显示器,避免状态过期。
    func menuNeedsUpdate(_ menu: NSMenu) {
        let model = viewModel.refreshDisplays()
        rebuild(menu, from: model)
    }

    private func rebuild(_ menu: NSMenu, from model: MenuModel) {
        menu.removeAllItems()
        for entry in model.entries {
            menu.addItem(assembler.menuItem(from: entry))
        }
    }
}

extension NSMenu {
    func removeAllItems() {
        while items.count > 0 {
            removeItem(at: 0)
        }
    }
}
