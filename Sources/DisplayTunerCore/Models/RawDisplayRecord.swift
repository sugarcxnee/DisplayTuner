import Foundation
import CoreGraphics

/// CoreGraphics 原始模式值的纯数据快照。不依赖任何系统对象,便于单元测试。
/// 字段语义与 `CGDisplayMode` 一一对应。
public struct RawModeRecord: Equatable, Sendable {
    /// 逻辑宽(点)。对应 `CGDisplayModeGetWidth`。
    public let width: Int
    /// 逻辑高(点)。对应 `CGDisplayModeGetHeight`。
    public let height: Int
    /// 物理像素宽。对应 `CGDisplayModeGetPixelWidth`。
    public let pixelWidth: Int
    /// 物理像素高。对应 `CGDisplayModeGetPixelHeight`。
    public let pixelHeight: Int
    /// 刷新率(Hz),可能为 0(未知/隔行)。
    public let refreshRate: Double
    /// `CGDisplayModeGetIOFlags` 原始值。
    public let ioFlags: UInt32

    public init(
        width: Int,
        height: Int,
        pixelWidth: Int,
        pixelHeight: Int,
        refreshRate: Double,
        ioFlags: UInt32 = DisplayModeIOFlags.valid | DisplayModeIOFlags.safe
    ) {
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
        self.ioFlags = ioFlags
    }

    /// HiDPI(2x)模式:物理像素按 2 倍及以上渲染。
    public var isHiDPI: Bool {
        guard width > 0, height > 0 else { return false }
        return pixelWidth >= width * 2 && pixelHeight >= height * 2
    }
}

/// CoreGraphics 单个显示器的原始快照。由 `CoreGraphicsDisplayService` 采集,
/// 之后所有分类、稳定 ID、模式解析都在这份数据上以纯函数完成。
public struct RawDisplayRecord: Equatable, Sendable {
    public let displayID: UInt32
    public let vendorNumber: UInt32
    public let modelNumber: UInt32
    public let serialNumber: UInt32
    /// `CGDisplayCopyDisplayName` 结果,可能为空。
    public let name: String
    public let bounds: CGRect
    /// 弧度制旋转,对应 `CGDisplayRotation`。
    public let rotation: Double
    public let isMain: Bool
    public let isBuiltin: Bool
    /// 当前模式在 `modes` 中的下标;找不到时为 nil(例如显示器刚接入)。
    public let currentModeIndex: Int?
    public let modes: [RawModeRecord]

    public init(
        displayID: UInt32,
        vendorNumber: UInt32,
        modelNumber: UInt32,
        serialNumber: UInt32,
        name: String,
        bounds: CGRect,
        rotation: Double = 0,
        isMain: Bool = false,
        isBuiltin: Bool = false,
        currentModeIndex: Int? = nil,
        modes: [RawModeRecord] = []
    ) {
        self.displayID = displayID
        self.vendorNumber = vendorNumber
        self.modelNumber = modelNumber
        self.serialNumber = serialNumber
        self.name = name
        self.bounds = bounds
        self.rotation = rotation
        self.isMain = isMain
        self.isBuiltin = isBuiltin
        self.currentModeIndex = currentModeIndex
        self.modes = modes
    }
}

/// IOKit `IOGraphicsTypes.h` 里的模式标志位镜像,避免在纯逻辑层 import IOKit。
public enum DisplayModeIOFlags {
    public static let valid: UInt32 = 0x00000001
    public static let safe: UInt32 = 0x00000002
    public static let native: UInt32 = 0x00000004
    public static let defaultFlag: UInt32 = 0x00000008
    public static let stretched: UInt32 = 0x00000020
    public static let interlaced: UInt32 = 0x00000080
}
