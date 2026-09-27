import Foundation

/// Sidecar 随航显示器识别启发式。
///
/// 不依赖单一信号:综合名称、EDID 特征、模式形状打分,达到阈值才判定为 Sidecar。
/// macOS 没有公开的"这是虚拟/Sidecar 显示器"标志,因此:
/// - 名称含 "sidecar"/"随航"/"ipad" 是强信号(系统通常把 Sidecar 显示器命名为 iPad 名);
/// - 无 EDID(vendor/model/serial 全 0)且非内置屏,是中信号(虚拟显示器常见形态);
/// - 模式形状接近 iPad(全部为 HiDPI,或最大逻辑宽在 iPad 屏范围内)是弱信号。
/// 内置屏直接排除。
public enum SidecarHeuristic {

    /// 打分阈值:名称(3)+ 无 EDID(2)+ 模式形状(1)组合后至少需要 3 分。
    static let threshold = 3

    /// iPad 逻辑分辨率的常见范围(点)。
    static let iPadLogicalWidthRange: ClosedRange<Int> = 800...2800

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

        // 强信号:名称
        let nameHints = ["sidecar", "随航", "ipad"]
        if nameHints.contains(where: lowered.contains) {
            score += 3
        }

        // 强信号:EDID 的 vendor/model 以 ASCII 编码身份
        // (实测随航屏 vendor=0x6161706c="aapl"、model=0x69506164="iPad")
        if asciiIdentifier(vendor).lowercased().contains("appl")
            || asciiIdentifier(model).lowercased().contains("ipad") {
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

    /// 把 EDID 数值按大端字节解释为可打印 ASCII(不可打印字节丢弃)。
    static func asciiIdentifier(_ value: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
        let printable = bytes.filter { $0 >= 0x20 && $0 <= 0x7E }
        guard printable.count == bytes.count else { return "" }   // 有不可打印字节就不当 ASCII 标识
        return String(bytes: bytes, encoding: .ascii) ?? ""
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
