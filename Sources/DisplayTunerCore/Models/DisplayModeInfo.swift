import Foundation

/// 领域层显示模式。由 `RawModeRecord` 解析而来,带派生属性,可直接驱动菜单与持久化。
public struct DisplayModeInfo: Equatable, Hashable, Sendable {
    public let width: Int
    public let height: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let refreshRate: Double
    public let ioFlags: UInt32
    /// 物理像素为逻辑尺寸 2 倍及以上。
    public let isHiDPI: Bool
    /// 是否该显示器当前生效的模式(每个显示器至多一个)。
    public let isCurrent: Bool
    /// 通过安全标志与尺寸健全性检查。
    public let isSafe: Bool
    /// 排序/推荐算法判定为推荐模式。
    public let isRecommended: Bool

    public init(
        width: Int,
        height: Int,
        pixelWidth: Int,
        pixelHeight: Int,
        refreshRate: Double,
        ioFlags: UInt32,
        isHiDPI: Bool,
        isCurrent: Bool = false,
        isSafe: Bool = true,
        isRecommended: Bool = false
    ) {
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
        self.ioFlags = ioFlags
        self.isHiDPI = isHiDPI
        self.isCurrent = isCurrent
        self.isSafe = isSafe
        self.isRecommended = isRecommended
    }

    /// 持久化与匹配用的稳定键:"1920x1080@60-hidpi"。
    public var modeKey: String {
        "\(width)x\(height)@\(Int(refreshRate.rounded()))\(isHiDPI ? "-hidpi" : "")"
    }

    /// modeKey 的尺寸部分(不含 -hidpi 后缀)。同一逻辑档的 1x/2x 变体
    /// sizeKey 相同,用于持久化偏好的跨渲染倍率匹配。
    public var sizeKey: String {
        "\(width)x\(height)@\(Int(refreshRate.rounded()))"
    }

    /// 从持久化的 modeKey 提取尺寸部分("1920x1080@60-hidpi" → "1920x1080@60")。
    public static func sizeKey(ofModeKey key: String) -> String {
        key.hasSuffix("-hidpi") ? String(key.dropLast("-hidpi".count)) : key
    }

    /// 菜单展示:"1920×1080 HiDPI @ 60Hz"。
    public var title: String {
        let refresh = Int(refreshRate.rounded())
        return "\(width)×\(height)\(isHiDPI ? " HiDPI" : "") @ \(refresh)Hz"
    }

    /// 宽高比(宽/高),宽高非法时为 nil。
    public var aspectRatio: Double? {
        guard height > 0 else { return nil }
        return Double(width) / Double(height)
    }

    /// 像素总量,排序用。
    public var pixelArea: Int { pixelWidth * pixelHeight }

    /// 与另一模式是否同一"显示效果"(尺寸+刷新+HiDPI),忽略 ioFlags 等噪音。
    public func sameEffect(as other: DisplayModeInfo) -> Bool {
        modeKey == other.modeKey
    }
}

/// 模式安全判定(纯函数)。
public enum ModeSafety {
    private static let minWidth = 640
    private static let minHeight = 480
    private static let maxWidth = 15_360
    private static let maxHeight = 8_640

    /// 必须声明 valid+safe,且尺寸在人类可见范围内,且刷新率已知(>0)。
    public static func isSafe(mode: RawModeRecord) -> Bool {
        let flags = mode.ioFlags
        guard flags & DisplayModeIOFlags.valid != 0,
              flags & DisplayModeIOFlags.safe != 0 else { return false }
        guard mode.width >= minWidth, mode.height >= minHeight,
              mode.width <= maxWidth, mode.height <= maxHeight else { return false }
        guard mode.refreshRate > 0 else { return false }
        return true
    }
}
