import Foundation
import CoreGraphics

/// `RawDisplayRecord` → `DisplayInfo` 的纯转换:稳定 ID、分类、模式去重与标记。
/// 不触碰任何系统 API,全部逻辑可单元测试。
public enum DisplayCatalog {

    public static func displays(from records: [RawDisplayRecord]) -> [DisplayInfo] {
        records.map(display(from:))
    }

    public static func display(from record: RawDisplayRecord) -> DisplayInfo {
        let stableID = StableDisplayID.make(for: record)
        let isSidecar = SidecarHeuristic.isLikelySidecar(record)
        let category = classify(record: record, isSidecar: isSidecar)
        // 排序 + 推荐标记在解析后立即完成,菜单直接使用最终顺序。
        let modes = ModeRanker.markRecommended(
            ModeRanker.sort(parseModes(record), isSidecar: isSidecar),
            isSidecar: isSidecar
        )

        return DisplayInfo(
            stableID: stableID,
            displayID: record.displayID,
            name: record.name,
            category: category,
            isMain: record.isMain,
            isBuiltin: record.isBuiltin,
            bounds: record.bounds,
            rotation: record.rotation,
            modes: modes,
            currentMode: modes.first(where: \.isCurrent),
            nativeAnchoredSize: anchoredNativeSize(rawModes: record.modes)
        )
    }

    /// 去重前的原始模式表中,同逻辑尺寸出现 ≥2 个变体的最大安全档 = 系统锚定的
    /// 原生尺寸(镜像污染变体以原生尺寸为锚;去重后此信息丢失,故在此计算)。
    static func anchoredNativeSize(rawModes: [RawModeRecord]) -> (width: Int, height: Int)? {
        let bySize = Dictionary(grouping: rawModes, by: { "\($0.width)x\($0.height)" })
        let anchored = bySize.values
            .filter { $0.count >= 2 }
            .compactMap { variants -> RawModeRecord? in
                variants.first { $0.ioFlags & DisplayModeIOFlags.safe != 0 } ?? variants.first
            }
            .max { $0.width * $0.height < $1.width * $1.height }
        guard let anchored = anchored else { return nil }
        return (anchored.width, anchored.height)
    }

    /// 分类优先级:sidecar > builtin > main > external > unknown。
    /// 内置屏被设为主屏时保留 `.builtin` 本质,主屏由 `DisplayInfo.isMain` 徽标表达;
    /// `.main` 类别用于"外接显示器被设为主屏"的场景。
    public static func classify(record: RawDisplayRecord, isSidecar: Bool) -> DisplayCategory {
        if isSidecar { return .sidecar }
        if record.isBuiltin { return .builtin }
        if record.isMain { return .main }
        if record.vendorNumber != 0 || record.modelNumber != 0 || record.serialNumber != 0 {
            return .external
        }
        return .unknown
    }

    /// 模式解析:同一 modeKey 去重(当前模式优先保留),保持首次出现顺序。
    public static func parseModes(_ record: RawDisplayRecord) -> [DisplayModeInfo] {
        let parsed = record.modes.enumerated().map { index, raw in
            modeInfo(from: raw, isCurrent: index == record.currentModeIndex)
        }

        var byKey: [String: DisplayModeInfo] = [:]
        var order: [String] = []
        for mode in parsed {
            if let existing = byKey[mode.modeKey] {
                // 同 key 两条时保留当前那条,否则保留先出现的
                if mode.isCurrent && !existing.isCurrent {
                    byKey[mode.modeKey] = mode
                }
            } else {
                byKey[mode.modeKey] = mode
                order.append(mode.modeKey)
            }
        }
        return order.compactMap { byKey[$0] }
    }

    public static func modeInfo(from raw: RawModeRecord, isCurrent: Bool) -> DisplayModeInfo {
        DisplayModeInfo(
            width: raw.width,
            height: raw.height,
            pixelWidth: raw.pixelWidth,
            pixelHeight: raw.pixelHeight,
            refreshRate: raw.refreshRate,
            ioFlags: raw.ioFlags,
            isHiDPI: raw.isHiDPI,
            isCurrent: isCurrent,
            isSafe: ModeSafety.isSafe(mode: raw),
            isRecommended: false
        )
    }
}
