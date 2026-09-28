import Foundation

/// 纯数据菜单模型:由 `MenuModelBuilder` 生成,AppKit 层翻译成 `NSMenu`。
/// 不 import AppKit,构建逻辑可完全单元测试(规格 4.2)。
public struct MenuModel: Equatable {
    public let entries: [MenuEntry]

    public init(entries: [MenuEntry]) {
        self.entries = entries
    }
}

public struct MenuEntry: Equatable {
    public enum State: Equatable {
        case none
        case on
        case mixed
    }

    public let title: String
    public let isEnabled: Bool
    public let state: State
    public let isSeparator: Bool
    public let children: [MenuEntry]?
    public let action: MenuAction?

    public init(
        title: String = "",
        isEnabled: Bool = true,
        state: State = .none,
        isSeparator: Bool = false,
        children: [MenuEntry]? = nil,
        action: MenuAction? = nil
    ) {
        self.title = title
        self.isEnabled = isEnabled
        self.state = state
        self.isSeparator = isSeparator
        self.children = children
        self.action = action
    }

    public static func separator() -> MenuEntry {
        MenuEntry(isSeparator: true)
    }

    public var hasCheckmark: Bool { state == .on }
}

/// 菜单动作。AppKit 层据此派发,ViewModel 据此执行。
public enum MenuAction: Equatable {
    case refresh
    case selectMode(displayStableID: String, modeKey: String)
    case toggleFilter(displayStableID: String, filter: ModeFilter)
    case restoreDefaultMode(displayStableID: String)
    case toggleExperimentalSidecar
    case seedHighResolutionModes(displayStableID: String)
    case startVirtualDisplay(displayStableID: String, width: Int, height: Int)
    case stopVirtualDisplay(displayStableID: String)
    case toggleAutoRestore
    case toggleLaunchAtLogin
    case setLogLevel(LogLevel)
    case openLogFile
    case showAbout
    case quit
}
