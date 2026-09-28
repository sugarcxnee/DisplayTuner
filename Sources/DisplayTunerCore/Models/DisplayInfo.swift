import Foundation
import CoreGraphics

/// 显示器类别。主屏是叠加属性(isMain),但为满足菜单展示需求,
/// 分类优先级为:sidecar > main > builtin > external > unknown。
public enum DisplayCategory: String, Codable, CaseIterable, Sendable {
    case main
    case builtin
    case sidecar
    case external
    case unknown

    public var displayName: String {
        switch self {
        case .main: return "主屏"
        case .builtin: return "内置屏"
        case .sidecar: return "Sidecar 随航"
        case .external: return "外接显示器"
        case .unknown: return "未知显示器"
        }
    }
}

/// 领域层显示器描述:枚举结果的最终形态,菜单与配置都围绕它工作。
public struct DisplayInfo: Equatable, Sendable {
    public let stableID: String
    /// CGDirectDisplayID,单次会话内有效,不用于持久化。
    public let displayID: UInt32
    public let name: String
    public let category: DisplayCategory
    public let isMain: Bool
    public let isBuiltin: Bool
    public let bounds: CGRect
    public let rotation: Double
    /// 已排序、已去重、已标记当前/安全/推荐的模式列表。
    public let modes: [DisplayModeInfo]
    public let currentMode: DisplayModeInfo?

    /// 系统锚定的原生尺寸(去重前的原始模式表中,同逻辑尺寸出现多个变体
    /// 的最大档 —— 真机探测结论:镜像污染变体以原生尺寸为锚)。
    /// 用于虚拟屏档位基准与镜像前的档位重置。
    public let nativeAnchoredSize: (width: Int, height: Int)?

    public init(
        stableID: String,
        displayID: UInt32,
        name: String,
        category: DisplayCategory,
        isMain: Bool,
        isBuiltin: Bool,
        bounds: CGRect,
        rotation: Double,
        modes: [DisplayModeInfo],
        currentMode: DisplayModeInfo?,
        nativeAnchoredSize: (width: Int, height: Int)? = nil
    ) {
        self.stableID = stableID
        self.displayID = displayID
        self.name = name
        self.category = category
        self.isMain = isMain
        self.isBuiltin = isBuiltin
        self.bounds = bounds
        self.rotation = rotation
        self.modes = modes
        self.currentMode = currentMode
        self.nativeAnchoredSize = nativeAnchoredSize
    }

    public static func == (lhs: DisplayInfo, rhs: DisplayInfo) -> Bool {
        lhs.stableID == rhs.stableID
            && lhs.displayID == rhs.displayID
            && lhs.name == rhs.name
            && lhs.category == rhs.category
            && lhs.isMain == rhs.isMain
            && lhs.isBuiltin == rhs.isBuiltin
            && lhs.bounds == rhs.bounds
            && lhs.rotation == rhs.rotation
            && lhs.modes == rhs.modes
            && lhs.currentMode == rhs.currentMode
            && lhs.nativeAnchoredSize?.width == rhs.nativeAnchoredSize?.width
            && lhs.nativeAnchoredSize?.height == rhs.nativeAnchoredSize?.height
    }

    /// 是否 Sidecar(分类或启发式命中)。
    public var isSidecar: Bool { category == .sidecar }

    /// 菜单标题:优先系统名,为空回退类别名。
    public var menuTitle: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? category.displayName : trimmed
    }

    /// 日志安全描述:不落设备名与序列号,只落类别 + 稳定 ID 短哈希。
    public var logDescriptor: String {
        "\(category.displayName)#\(PrivacyRedactor.shortHash(stableID))"
    }
}
