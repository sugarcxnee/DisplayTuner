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

/// 像素尺寸(可比较、可跨并发域)。
public struct DisplaySize: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
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
    /// 系统锚定的原生尺寸(去重前的原始模式表里同逻辑尺寸出现 ≥2 个变体,
    /// 最大安全档即锚点 —— 镜像污染变体以原生尺寸为锚;去重后此信息丢失,
    /// 故在枚举层计算)。用于播种的基准档与"是否已解锁"判定。
    public let nativeAnchoredSize: DisplaySize?

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
        nativeAnchoredSize: DisplaySize? = nil
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
