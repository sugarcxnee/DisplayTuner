import Foundation
import CoreGraphics
@testable import DisplayTunerCore

/// 测试数据工厂:构造 `RawDisplayRecord` / `RawModeRecord` 的典型样本。
enum Fixtures {

    /// 逻辑 1920x1080,HiDPI 物理像素 2x。
    static func mode(
        _ width: Int,
        _ height: Int,
        refresh: Double = 60,
        hidpi: Bool = true,
        ioFlags: UInt32 = DisplayModeIOFlags.valid | DisplayModeIOFlags.safe
    ) -> RawModeRecord {
        RawModeRecord(
            width: width,
            height: height,
            pixelWidth: width * (hidpi ? 2 : 1),
            pixelHeight: height * (hidpi ? 2 : 1),
            refreshRate: refresh,
            ioFlags: ioFlags
        )
    }

    static func builtinDisplay(name: String = "Built-in Retina Display") -> RawDisplayRecord {
        RawDisplayRecord(
            displayID: 1,
            vendorNumber: 0x05AC,
            modelNumber: 0xA041,
            serialNumber: 0,
            name: name,
            bounds: CGRect(x: 0, y: 0, width: 1512, height: 982),
            isMain: true,
            isBuiltin: true,
            currentModeIndex: 0,
            modes: [
                mode(1512, 982),
                mode(1440, 900),
                mode(1024, 640),
            ]
        )
    }

    static func sidecarDisplay(
        name: String = "张三的 iPad",
        displayID: UInt32 = 2,
        serialNumber: UInt32 = 0,
        modes: [RawModeRecord] = []
    ) -> RawDisplayRecord {
        let sidecarModes = modes.isEmpty
            ? [mode(1920, 1080), mode(1280, 720)]
            : modes
        return RawDisplayRecord(
            displayID: displayID,
            vendorNumber: 0,
            modelNumber: 0,
            serialNumber: serialNumber,
            name: name,
            bounds: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
            isMain: false,
            isBuiltin: false,
            currentModeIndex: 0,
            modes: sidecarModes
        )
    }

    static func externalDisplay(
        name: String = "DELL U2720Q",
        displayID: UInt32 = 3,
        isMain: Bool = false
    ) -> RawDisplayRecord {
        RawDisplayRecord(
            displayID: displayID,
            vendorNumber: 0x10AE,
            modelNumber: 0x1234,
            serialNumber: 0x9ABCDEF0,
            name: name,
            bounds: CGRect(x: 0, y: -1440, width: 3840, height: 2160),
            isMain: isMain,
            isBuiltin: false,
            currentModeIndex: 1,
            modes: [
                mode(1920, 1080),
                mode(2560, 1440),
                mode(1920, 1080, hidpi: false),
            ]
        )
    }
}
