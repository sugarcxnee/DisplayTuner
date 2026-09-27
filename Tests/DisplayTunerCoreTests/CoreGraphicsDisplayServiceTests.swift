import XCTest
@testable import DisplayTunerCore

/// 真实 CoreGraphics 只读枚举测试:不切换任何显示器,无副作用,
/// 因此不加环境门控(CI 的 macOS runner 也至少有一台虚拟显示器)。
final class CoreGraphicsDisplayServiceTests: XCTestCase {

    func testLiveEnumerationReturnsAtLeastOneDisplay() {
        let service = CoreGraphicsDisplayService(logger: DTLogger(sinks: [MemoryLogSink()]))
        let displays = service.snapshotDisplays()
        XCTAssertGreaterThanOrEqual(displays.count, 1, "本机至少应有一台在线显示器")
    }

    func testLiveEnumerationHasExactlyOneMainDisplay() {
        let service = CoreGraphicsDisplayService(logger: DTLogger(sinks: [MemoryLogSink()]))
        let displays = service.snapshotDisplays()
        let mainCount = displays.filter(\.isMain).count
        XCTAssertEqual(mainCount, 1, "系统应报告恰好一台主屏")
    }

    func testLiveEnumerationEveryDisplayHasStableID() {
        let service = CoreGraphicsDisplayService(logger: DTLogger(sinks: [MemoryLogSink()]))
        let displays = service.snapshotDisplays()
        for display in displays {
            XCTAssertFalse(display.stableID.isEmpty)
            XCTAssertTrue(
                display.stableID.hasPrefix("display-v1-")
                    || display.stableID.hasPrefix("display-fallback-v1-")
            )
        }
    }

    func testLiveEnumerationIsRepeatable() {
        let service = CoreGraphicsDisplayService(logger: DTLogger(sinks: [MemoryLogSink()]))
        let first = service.snapshotDisplays().map(\.stableID).sorted()
        let second = service.snapshotDisplays().map(\.stableID).sorted()
        XCTAssertEqual(first, second, "连续两次枚举的稳定 ID 应一致")
    }
}
