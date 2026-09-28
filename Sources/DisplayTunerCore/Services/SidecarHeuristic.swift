import Foundation

/// Sidecar 随航显示器识别启发式。
///
/// 不依赖单一信号:综合名称、EDID 特征、模式形状打分,达到阈值才判定为 Sidecar。
/// macOS 没有公开的"这是虚拟/Sidecar 显示器"标志,因此:
/// - 虚拟 EDID 三元组恰为 "aapl"/"iPad"(2026-09-28 真机实测,
///   0x6161706C/0x69506164)是最强信号 —— Apple 专门编码,别的显示器不会有;
/// - 名称含 "sidecar"/"随航"/"ipad" 是强信号(系统通常把 Sidecar 显示器命名为 iPad 名);
/// - 无 EDID(vendor/model/serial 全 0)且非内置屏,是中信号(虚拟显示器常见形态,
///   部分 Sidecar 连接会以全 0 形态出现);
/// - 模式形状接近 iPad(全部为 HiDPI,或最大逻辑宽在 iPad 屏范围内)是弱信号。
/// 内置屏直接排除。
public enum SidecarHeuristic {

    /// 打分阈值:虚拟 EDID(3)/名称(3)+ 无 EDID(2)+ 模式形状(1)组合后至少需要 3 分。
    static let threshold = 3

    /// iPad 逻辑分辨率的常见范围(点)。
    static let iPadLogicalWidthRange: ClosedRange<Int> = 800...2800

    /// Sidecar 的虚拟 EDID 字面值:vendor = ASCII "aapl",model = ASCII "iPad"。
    private static let sidecarVendorID: UInt32 = 0x6161706C
    private static let sidecarModelID: UInt32 = 0x69506164

    /// 综合打分。分数与判定细节都会进日志,便于现场排查。
    public static func score(
        name: String,
        vendor: UInt32,
        model: UInt32,
        serial: UInt32,
        isBuiltin: Bool,
        modes: [RawModeRecord]
    ) -> Int {
        if isBuiltin { return 0 }

        var score = 0
        let lowered = name.lowercased()

        // 最强信号:虚拟 EDID 恰为 "aapl"/"iPad"
        if vendor == sidecarVendorID && model == sidecarModelID {
            score += 3
        }

        // 强信号:名称
        let nameHints = ["sidecar", "随航", "ipad"]
        if nameHints.contains(where: lowered.contains) {
            score += 3
        }

        // 中信号:无 EDID 的虚拟显示器
        if vendor == 0 && model == 0 && serial == 0 {
            score += 2
        }

        // 弱信号:模式形状接近 iPad
        if !modes.isEmpty {
            let maxLogicalWidth = modes.map(\.width).max() ?? 0
            let allHiDPI = modes.allSatisfy(\.isHiDPI)
            if (iPadLogicalWidthRange.contains(maxLogicalWidth) && allHiDPI)
                || (vendor == 0 && iPadLogicalWidthRange.contains(maxLogicalWidth)) {
                score += 1
            }
        }

        return score
    }

    /// 是否判定为 Sidecar。
    public static func isLikelySidecar(_ record: RawDisplayRecord) -> Bool {
        score(
            name: record.name,
            vendor: record.vendorNumber,
            model: record.modelNumber,
            serial: record.serialNumber,
            isBuiltin: record.isBuiltin,
            modes: record.modes
        ) >= threshold
    }
}
