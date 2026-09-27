import Foundation
import CoreGraphics

/// 显示器枚举服务。每次调用都重新读取系统状态,调用方不缓存。
public protocol DisplayService: AnyObject {
    /// 当前在线显示器快照;系统异常时返回空数组(不崩溃)。
    func snapshotDisplays() -> [DisplayInfo]
}

/// 显示器名称提供器:core 层不依赖 AppKit,名称由调用方注入
/// (生产环境用 `NSScreen.localizedName`,测试环境可注入任意名字)。
public typealias DisplayNameProvider = (CGDirectDisplayID) -> String?

/// 基于 CoreGraphics 公共 API 的真实实现。
/// CG 调用全部集中在这里,产出 `RawDisplayRecord`,再由纯函数 `DisplayCatalog` 加工。
public final class CoreGraphicsDisplayService: DisplayService {

    private let logger: DTLogger
    private let nameProvider: DisplayNameProvider

    public init(
        nameProvider: @escaping DisplayNameProvider = { _ in nil },
        logger: DTLogger = DTLogger()
    ) {
        self.logger = logger
        self.nameProvider = nameProvider
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

        var rawModes: [RawModeRecord] = []
        if let modeList = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode] {
            rawModes = modeList.map { mode in
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
        let currentIndex = rawModes.firstIndex { mode in
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
            modes: rawModes
        )
    }
}
