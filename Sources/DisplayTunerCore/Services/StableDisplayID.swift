import Foundation

/// 稳定显示器 ID 生成。
///
/// 优先使用 EDID 三元组(vendor/model/serial),序列号不可用(0)时回退 CGDisplayID。
/// CGDisplayID 在重新插拔后会变化,EDID 不变;同一物理显示器的两种连接方式
/// (例如 Sidecar 断开重连)下,该 ID 应保持稳定。
public enum StableDisplayID {

    /// 生成稳定 ID。格式固定、全小写十六进制,可直接作为 JSON 字典键。
    public static func make(
        vendor: UInt32,
        model: UInt32,
        serial: UInt32,
        displayID: UInt32
    ) -> String {
        if serial != 0 {
            return String(format: "display-v1-%05x-%05x-%08x", vendor, model, serial)
        }
        return String(format: "display-fallback-v1-%08x", displayID)
    }

    /// 从 `RawDisplayRecord` 直接生成。
    ///
    /// Sidecar 例外(2026-09-28 真机实测):其 serialNumber 随 iPad 边栏
    /// 显示状态漂移 —— 同一台 iPad 在日志中出现过两个稳定 ID,导致
    /// autoRestore 偏好在两态间互不相通。Sidecar 的 vendor/model 恒定,
    /// 改用二者构成身份;同型号多台 iPad 并发随航的碰撞在此场景下可接受。
    public static func make(for record: RawDisplayRecord) -> String {
        if SidecarHeuristic.isLikelySidecar(record) {
            return String(
                format: "display-sidecar-v1-%05x-%05x",
                record.vendorNumber, record.modelNumber
            )
        }
        return make(
            vendor: record.vendorNumber,
            model: record.modelNumber,
            serial: record.serialNumber,
            displayID: record.displayID
        )
    }

    /// 是否为回退 ID(即基于 CGDisplayID 的那类,稳定性较弱)。
    public static func isFallback(_ id: String) -> Bool {
        id.hasPrefix("display-fallback-")
    }
}
