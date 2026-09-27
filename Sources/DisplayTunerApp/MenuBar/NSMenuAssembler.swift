import AppKit
import DisplayTunerCore

/// 把纯数据 `MenuModel` 翻译成 `NSMenu`。唯一的 AppKit 依赖点,
/// 菜单结构本身由核心层的 MenuModelBuilder 决定(可单测)。
final class NSMenuAssembler {

    private let target: AnyObject
    private let action: Selector

    init(target: AnyObject, action: Selector) {
        self.target = target
        self.action = action
    }

    func assemble(_ model: MenuModel) -> NSMenu {
        let menu = NSMenu()
        for entry in model.entries {
            menu.addItem(menuItem(from: entry))
        }
        return menu
    }

    func menuItem(from entry: MenuEntry) -> NSMenuItem {
        if entry.isSeparator {
            return NSMenuItem.separator()
        }

        let item = NSMenuItem(
            title: entry.title,
            action: entry.action == nil ? nil : action,
            keyEquivalent: ""
        )
        item.target = entry.action == nil ? nil : target
        item.isEnabled = entry.isEnabled
        item.representedObject = entry.action
        switch entry.state {
        case .on: item.state = .on
        case .mixed: item.state = .mixed
        case .none: item.state = .off
        }

        if let children = entry.children {
            let submenu = NSMenu()
            for child in children {
                submenu.addItem(menuItem(from: child))
            }
            item.submenu = submenu
        }
        return item
    }
}
