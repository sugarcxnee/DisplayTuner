import XCTest
@testable import DisplayTunerCore

/// 真实控制器的安全失败路径测试:只覆盖"必然失败、无副作用"的场景,
/// 绝不切换真实显示器(真实切换只在 DISPLAYTUNER_RUN_DANGEROUS_TESTS=1 的集成测试里发生)。
final class CoreGraphicsDisplayModeControllerTests: XCTestCase {

    func testCurrentModeForNonexistentDisplayIsNil() {
        let controller = CoreGraphicsDisplayModeController(
            logger: DTLogger(sinks: [MemoryLogSink()])
        )
        // 0xFFFFFF 是极不可能在线的 CGDisplayID
        XCTAssertNil(controller.currentMode(for: 0xFFFFFF))
    }

    func testApplyToNonexistentDisplayThrowsDisplayNotFound() {
        let controller = CoreGraphicsDisplayModeController(
            logger: DTLogger(sinks: [MemoryLogSink()])
        )
        var record = Fixtures.externalDisplay()
        record = RawDisplayRecord(
            displayID: 0xFFFFFF,
            vendorNumber: record.vendorNumber,
            modelNumber: record.modelNumber,
            serialNumber: record.serialNumber,
            name: record.name,
            bounds: record.bounds,
            isMain: record.isMain,
            isBuiltin: record.isBuiltin,
            currentModeIndex: record.currentModeIndex,
            modes: record.modes
        )
        let ghostDisplay = DisplayCatalog.display(from: record)
        guard let someMode = ghostDisplay.modes.first else {
            return XCTFail("fixture 应包含模式")
        }

        XCTAssertThrowsError(try controller.apply(someMode, to: ghostDisplay)) { error in
            XCTAssertEqual(error as? ModeApplicationError, .displayNotFound(0xFFFFFF))
        }
    }

    func testRollbackToUnavailableModeThrows() {
        let controller = CoreGraphicsDisplayModeController(
            logger: DTLogger(sinks: [MemoryLogSink()])
        )
        let change = AppliedChange(
            displayStableID: "display-v1-00001-00002-00000003",
            displayID: 0xFFFFFF,
            displayLogDescriptor: "test#abcd",
            previousMode: DisplayModeInfo(
                width: 4096, height: 2160,
                pixelWidth: 8192, pixelHeight: 4320,
                refreshRate: 240,
                ioFlags: DisplayModeIOFlags.valid | DisplayModeIOFlags.safe,
                isHiDPI: true
            ),
            appliedMode: DisplayModeInfo(
                width: 1920, height: 1080,
                pixelWidth: 3840, pixelHeight: 2160,
                refreshRate: 60,
                ioFlags: DisplayModeIOFlags.valid | DisplayModeIOFlags.safe,
                isHiDPI: true
            )
        )
        XCTAssertThrowsError(try controller.rollback(change)) { rawError in
            guard let error = rawError as? ModeApplicationError, case .rollbackFailed = error else {
                return XCTFail("应抛 rollbackFailed,实际 \(rawError)")
            }
        }
    }
}
