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
    public static func presets(for display: DisplayInfo) -> [Preset] {
        guard let current = display.currentMode, current.width > 0, current.height > 0 else {
            return []
        }
        return presets(baseWidth: current.width, baseHeight: current.height)
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
