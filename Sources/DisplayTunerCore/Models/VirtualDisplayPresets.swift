import Foundation

/// 虚拟屏档位:按 Sidecar 当前逻辑分辨率的倍数生成,
/// 适配任何 iPad(苹果全系 iPad 均为 2x 物理,故 2 倍档通常接近点对点)。
public enum VirtualDisplayPresets {

    public struct Preset: Equatable, Sendable {
        public let spec: VirtualDisplaySpec
        public let scale: Double
        public let isRecommended: Bool

        public var title: String {
            let recommended = isRecommended ? "(推荐)" : ""
            return "\(spec.title) — 工作区 ×\(String(format: "%.1f", scale))\(recommended)"
        }
    }

    /// 三档:×1.5(舒适)、×2(推荐,接近 iPad 物理像素)、×2.5(超大)。
    /// 基准一律取**原生档**(defaultFlag 或宽 ≤1400 的最大安全档):
    /// Sidecar 可能停留在镜像遗留的高档上,用实时模式当基准会把档位算错。
    public static func presets(for display: DisplayInfo) -> [Preset] {
        let base = nativeBase(of: display)
        return presets(baseWidth: base.width, baseHeight: base.height)
    }

    /// 显示器的原生基准。
    ///
    /// 判据(真机探测):Sidecar 的原生档没有 NATIVE/DEFAULT 标志可查,但系统为
    /// 镜像生成污染变体时**以原生尺寸为锚**(如 1180×820 出现 0x3 与 0x1 两个变体,
    /// 该信息在模式去重后保留于 `nativeAnchoredSize`)。
    /// 无锚点时退回:defaultFlag 档 → 宽 ≤1400 的最大安全档 → 当前模式。
    public static func nativeBase(of display: DisplayInfo) -> (width: Int, height: Int) {
        // 首选:去重前计算的系统锚定原生尺寸(见 DisplayCatalog.anchoredNativeSize)
        if let anchored = display.nativeAnchoredSize, anchored.width > 0 {
            return anchored
        }
        let safe = display.modes.filter(\.isSafe)
        if let flagged = safe.first(where: { $0.ioFlags & DisplayModeIOFlags.defaultFlag != 0 }) {
            return (flagged.width, flagged.height)
        }
        if let small = safe.filter({ $0.width <= 1400 }).max(by: { $0.width * $0.height < $1.width * $1.height }) {
            return (small.width, small.height)
        }
        if let current = display.currentMode {
            return (current.width, current.height)
        }
        return (0, 0)
    }

    /// 基于基准分辨率(会话启动时的 Sidecar 逻辑分辨率)计算档位。
    /// 镜像期间 Sidecar 实时模式会漂移,必须用基准。
    public static func presets(baseWidth: Int, baseHeight: Int) -> [Preset] {
        guard baseWidth > 0, baseHeight > 0 else { return [] }
        return [
            Preset(spec: scaled(baseWidth, baseHeight, 1.5), scale: 1.5, isRecommended: false),
            Preset(spec: scaled(baseWidth, baseHeight, 2.0), scale: 2.0, isRecommended: true),
            Preset(spec: scaled(baseWidth, baseHeight, 2.5), scale: 2.5, isRecommended: false),
        ]
    }

    private static func scaled(_ width: Int, _ height: Int, _ factor: Double) -> VirtualDisplaySpec {
        VirtualDisplaySpec(
            width: roundTo10(Double(width) * factor),
            height: roundTo10(Double(height) * factor)
        )
    }

    private static func roundTo10(_ value: Double) -> Int {
        Int((value / 10).rounded() * 10)
    }
}
