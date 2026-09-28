import Foundation
import CoreGraphics

/// 显示器枚举服务。每次调用都重新读取系统状态,调用方不缓存。
public protocol DisplayService: AnyObject {
    /// 当前在线显示器快照;系统异常时返回空数组(不崩溃)。
    func snapshotDisplays() -> [DisplayInfo]

    /// 读取指定显示器的原始模式列表。
    /// `includeHidden` 为 true 时以 `kCGDisplayShowDuplicateLowResolutionModes`
    /// 选项枚举,可暴露系统默认隐藏的低分辨率/重复模式(实验性 Sidecar 增强的公开部分)。
    func rawModes(for displayID: UInt32, includeHidden: Bool) -> [RawModeRecord]
}

/// 显示器名称提供器:core 层不依赖 AppKit,名称由调用方注入
/// (生产环境用 `NSScreen.localizedName`,测试环境可注入任意名字)。
public typealias DisplayNameProvider = (CGDirectDisplayID) -> String?

/// 基于 CoreGraphics 公共 API 的真实实现。
/// CG 调用全部集中在这里,产出 `RawDisplayRecord`,再由纯函数 `DisplayCatalog` 加工。
public final class CoreGraphicsDisplayService: DisplayService {

    private let logger: DTLogger
    private let nameProvider: DisplayNameProvider
    /// Sidecar 影子 HiDPI 缓存(与 ModeController 共享同一实例,由组合根注入)。
    private let hidpiCache: HiDPIModeCache

    public init(
        nameProvider: @escaping DisplayNameProvider = { _ in nil },
        logger: DTLogger = DTLogger(),
        hidpiCache: HiDPIModeCache = HiDPIModeCache()
    ) {
        self.logger = logger
        self.nameProvider = nameProvider
        self.hidpiCache = hidpiCache
    }

    public func snapshotDisplays() -> [DisplayInfo] {
        let records = collectRawRecords()
        let displays = DisplayCatalog.displays(from: records)
        logger.debug(
            "enumerated \(displays.count) display(s): "
                + displays.map(\.logDescriptor).joined(separator: ", "),
            context: "DisplayService"
        )
        return displays
    }

    // MARK: - CG 采集

    public func rawModes(for displayID: UInt32, includeHidden: Bool) -> [RawModeRecord] {
        // 常量值即其名称字符串;直接用字面量避免依赖是否公开导出的符号
        let options: CFDictionary? = includeHidden
            ? ["kCGDisplayShowDuplicateLowResolutionModes": true] as CFDictionary
            : nil
        guard let list = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
            return []
        }
        return list.map { mode in
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

    private func collectRawRecords() -> [RawDisplayRecord] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        let status = CGGetOnlineDisplayList(32, &ids, &count)
        guard status == .success else {
            logger.error("CGGetOnlineDisplayList failed: \(status)", context: "DisplayService")
            return []
        }
        return ids.prefix(Int(count)).map(rawRecord(for:))
    }

    private func rawRecord(for displayID: CGDirectDisplayID) -> RawDisplayRecord {
        let name = nameProvider(displayID) ?? ""
        let current = CGDisplayCopyDisplayMode(displayID)
        // Sidecar 影子 HiDPI:清晰态的 2x 档从不进枚举(2026-09-28 真机定性),
        // 读到即捕获对象引用;已捕获的影子条目并入模式表,让菜单可见、可点选。
        hidpiCache.captureIfHiDPI(current, displayID: displayID)
        let shadowEntries = hidpiCache.rawEntries(for: displayID)
        let modes = ShadowModeMerge.merge(
            enumModes: rawModes(for: displayID, includeHidden: false),
            shadowModes: shadowEntries
        )
        if !shadowEntries.isEmpty {
            logger.debug(
                "merged \(shadowEntries.count) shadow HiDPI mode(s) into \(displayID) mode table",
                context: "DisplayService"
            )
        }
        let currentIndex = modes.firstIndex { mode in
            guard let current = current else { return false }
            return mode.width == Int(current.width)
                && mode.height == Int(current.height)
                && mode.pixelWidth == Int(current.pixelWidth)
                && mode.pixelHeight == Int(current.pixelHeight)
                && mode.refreshRate == current.refreshRate
        }

        return RawDisplayRecord(
            displayID: displayID,
            vendorNumber: CGDisplayVendorNumber(displayID),
            modelNumber: CGDisplayModelNumber(displayID),
            serialNumber: CGDisplaySerialNumber(displayID),
            name: name,
            bounds: CGDisplayBounds(displayID),
            rotation: Double(CGDisplayRotation(displayID)),
            isMain: CGDisplayIsMain(displayID) != 0,
            isBuiltin: CGDisplayIsBuiltin(displayID) != 0,
            currentModeIndex: currentIndex,
            modes: modes
        )
    }
}
