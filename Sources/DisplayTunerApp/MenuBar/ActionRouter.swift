import AppKit
import DisplayTunerCore

/// 所有菜单点击的统一入口:representedObject 里取回 MenuAction 再派发。
final class ActionRouter: NSObject {

    /// App 级动作处理(打开日志/关于/退出等需要 AppKit 的行为)。
    typealias ExtraHandler = (MenuAction) -> Void

    private let performCore: (MenuAction) -> Void
    private let performAppLevel: ExtraHandler

    init(
        performCore: @escaping (MenuAction) -> Void,
        performAppLevel: @escaping ExtraHandler
    ) {
        self.performCore = performCore
        self.performAppLevel = performAppLevel
    }

    @objc func performMenuItem(_ sender: NSMenuItem) {
        guard let menuAction = sender.representedObject as? MenuAction else { return }
        performCore(menuAction)
        performAppLevel(menuAction)
    }
}
