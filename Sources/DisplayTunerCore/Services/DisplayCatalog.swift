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
            nativeAnchoredSize: anchoredNativeSize(rawModes: record.modes).map {
                DisplaySize(width: $0.width, height: $0.height)
            }
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
    /// 模式解析(两层收敛):
    /// 1. 同逻辑尺寸(宽×高@刷新率)收敛为一条 —— **恒取 HiDPI 变体**。
    ///    真机实测(2026-09-28):Sidecar 同尺寸共存 1x/2x 变体,1x 渲染被拉伸
    ///    到面板导致字体发虚("切档后变糊"的根因);系统自身选档恒为 2x。
    ///    菜单/配置从此不再暴露 1x 条目。
    /// 2. 同 modeKey 去重(当前档优先保留)。
    /// 当前档标记按尺寸组传播:当前停在 1x 变体时,收敛后的 HiDPI 条目
    /// 仍标记 isCurrent(菜单勾选正确;用户再点该条即真正升到 2x)。
    public static func parseModes(_ record: RawDisplayRecord) -> [DisplayModeInfo] {
        let parsed = record.modes.enumerated().map { index, raw in
            modeInfo(from: raw, isCurrent: index == record.currentModeIndex)
        }

        struct Slot {
            var entry: DisplayModeInfo
            var sizeCurrent: Bool
        }
        var bySize: [String: Slot] = [:]
        var order: [String] = []

        func sizeKey(_ mode: DisplayModeInfo) -> String {
            "\(mode.width)x\(mode.height)@\(Int(mode.refreshRate.rounded()))"
        }
        func rank(_ mode: DisplayModeInfo) -> Int {
            // HiDPI(2) > 当前(1) > 其他(0)
            (mode.isHiDPI ? 2 : 0) + (mode.isCurrent ? 1 : 0)
        }

        for mode in parsed {
            let key = sizeKey(mode)
            if var slot = bySize[key] {
                slot.sizeCurrent = slot.sizeCurrent || mode.isCurrent
                if rank(mode) > rank(slot.entry) {
                    slot.entry = mode
                }
                bySize[key] = slot
            } else {
                bySize[key] = Slot(entry: mode, sizeCurrent: mode.isCurrent)
                order.append(key)
            }
        }

        let collapsed = order.compactMap { key -> DisplayModeInfo? in
            guard var slot = bySize[key] else { return nil }
            if slot.sizeCurrent && !slot.entry.isCurrent {
                slot.entry = withCurrent(slot.entry, true)
            }
            return slot.entry
        }

        // 同 modeKey 去重(理论已无重复,防御性保留)
        var byKey: [String: DisplayModeInfo] = [:]
        var keyOrder: [String] = []
        for mode in collapsed {
            if let existing = byKey[mode.modeKey] {
                if mode.isCurrent && !existing.isCurrent {
                    byKey[mode.modeKey] = mode
                }
            } else {
                byKey[mode.modeKey] = mode
                keyOrder.append(mode.modeKey)
            }
        }
        return keyOrder.compactMap { byKey[$0] }
    }

    private static func withCurrent(_ mode: DisplayModeInfo, _ isCurrent: Bool) -> DisplayModeInfo {
        DisplayModeInfo(
            width: mode.width,
            height: mode.height,
            pixelWidth: mode.pixelWidth,
            pixelHeight: mode.pixelHeight,
            refreshRate: mode.refreshRate,
            ioFlags: mode.ioFlags,
            isHiDPI: mode.isHiDPI,
            isCurrent: isCurrent,
            isSafe: mode.isSafe,
            isRecommended: mode.isRecommended
        )
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
