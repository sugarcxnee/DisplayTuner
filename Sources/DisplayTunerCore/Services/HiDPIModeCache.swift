import Foundation
import CoreGraphics

/// Sidecar 影子 HiDPI 模式缓存。
///
/// 真机定性(2026-09-28,实验脚本 /tmp/exp_retained2x.swift):
/// Sidecar 的清晰态由一个 2x `CGDisplayMode`(逻辑 1116×820 → 2232×1640,
/// flags 0x2000007)承载。该对象由系统在 framebuffer 重建时(边栏切换、
/// 连接建立等系统路径)内部合成,**从不出现**在 `CGDisplayCopyAllDisplayModes`
/// 的任何枚举结果中 —— 即使正处于清晰态、带
/// `kCGDisplayShowDuplicateLowResolutionModes` 选项,列表也全部 1x。
/// 但持有该对象的引用后,`CGConfigureDisplayWithDisplayMode` /
/// `CGDisplaySetDisplayMode` 均可正常切换,清晰态经程序路径完全可达。
///
/// 策略:凡读到某显示器当前档为 HiDPI 即捕获对象引用(它必然刚由系统设置);
/// 之后同尺寸目标经缓存升级,不再依赖枚举。对象在进程内长期持有,进程退出即失
/// ——冷启动若系统未先到过清晰态,缓存为空,如实降级。
public final class HiDPIModeCache: @unchecked Sendable {

    private let lock = NSLock()
    /// displayID → sizeKey → 捕获的 2x 模式对象(强引用,进程内长期持有)。
    private var objects: [UInt32: [String: CGDisplayMode]] = [:]

    public init() {}

    /// 与 `DisplayModeInfo.sizeKey` 同域的尺寸键。
    public static func sizeKey(width: Int, height: Int, refreshRate: Double) -> String {
        "\(width)x\(height)@\(Int(refreshRate.rounded()))"
    }

    /// 当前档为 HiDPI 时捕获对象引用;否则忽略(含 nil)。
    /// 镜像协商档不作数:显示器处于镜像组时 `CGDisplayCopyDisplayMode` 返回
    /// 的是镜像主屏的临时协商档(实测 2026-09-28:挂内置屏后读到
    /// 1710×1111→2x),解除镜像即失效,捕获它只会留下无效菜单条目。
    public func captureIfHiDPI(_ mode: CGDisplayMode?, displayID: UInt32) {
        guard let mode = mode,
              Int(mode.pixelWidth) >= Int(mode.width) * 2,
              Int(mode.pixelHeight) >= Int(mode.height) * 2 else { return }
        guard CGDisplayIsInMirrorSet(displayID) == 0 else { return }
        let key = Self.sizeKey(width: Int(mode.width), height: Int(mode.height), refreshRate: mode.refreshRate)
        lock.lock()
        objects[displayID, default: [:]][key] = mode
        lock.unlock()
    }

    /// 查询同尺寸的影子 HiDPI 对象。
    public func hidpiMode(displayID: UInt32, width: Int, height: Int, refreshRate: Double) -> CGDisplayMode? {
        let key = Self.sizeKey(width: width, height: height, refreshRate: refreshRate)
        lock.lock()
        defer { lock.unlock() }
        return objects[displayID]?[key]
    }

    /// 匹配目标模式的影子对象(仅 HiDPI 目标;1x 目标永远走枚举)。
    public func hidpiMode(displayID: UInt32, matching target: DisplayModeInfo) -> CGDisplayMode? {
        guard target.isHiDPI else { return nil }
        return hidpiMode(displayID: displayID, width: target.width, height: target.height, refreshRate: target.refreshRate)
    }

    /// 该显示器当前缓存的影子条目元数据(用于并入模式表)。
    public func rawEntries(for displayID: UInt32) -> [RawModeRecord] {
        lock.lock()
        defer { lock.unlock() }
        return (objects[displayID] ?? [:]).values.map { mode in
            RawModeRecord(
                width: Int(mode.width),
                height: Int(mode.height),
                pixelWidth: Int(mode.pixelWidth),
                pixelHeight: Int(mode.pixelHeight),
                refreshRate: mode.refreshRate,
                ioFlags: mode.ioFlags
            )
        }
    }

    /// 失效一条缓存(configure 失败或验证未落在 2x 时调用,防反复使用陈旧对象)。
    public func invalidate(displayID: UInt32, width: Int, height: Int, refreshRate: Double) {
        let key = Self.sizeKey(width: width, height: height, refreshRate: refreshRate)
        lock.lock()
        objects[displayID]?.removeValue(forKey: key)
        lock.unlock()
    }

    public func removeAll() {
        lock.lock()
        objects.removeAll()
        lock.unlock()
    }
}

/// 影子 HiDPI 条目并入枚举模式表(纯函数,可单元测试)。
///
/// 注入规则:影子条目(必然 HiDPI)在枚举中同尺寸(宽×高@刷新率)没有
/// HiDPI 变体时追加到表尾;`DisplayCatalog.parseModes` 的同尺寸收敛会把它
/// 提为该尺寸的代表条目,并按 currentIndex 精确传播 isCurrent ——
/// 菜单因此显示 "HiDPI" 条目且勾选正确,用户直接可点选。
public enum ShadowModeMerge {

    public static func merge(enumModes: [RawModeRecord], shadowModes: [RawModeRecord]) -> [RawModeRecord] {
        guard !shadowModes.isEmpty else { return enumModes }
        var result = enumModes
        for shadow in shadowModes where shadow.isHiDPI {
            let hasHiDPIVariant = enumModes.contains {
                $0.isHiDPI
                    && $0.width == shadow.width && $0.height == shadow.height
                    && Int($0.refreshRate.rounded()) == Int(shadow.refreshRate.rounded())
            }
            if !hasHiDPIVariant {
                result.append(shadow)
            }
        }
        return result
    }
}
