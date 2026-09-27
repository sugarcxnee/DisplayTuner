import XCTest
@testable import DisplayTunerCore

final class StableDisplayIDTests: XCTestCase {

    func testUsesEDIDTripleWhenSerialPresent() {
        let id = StableDisplayID.make(vendor: 0x10AE, model: 0x1234, serial: 0x9ABCDEF0, displayID: 42)
        XCTAssertEqual(id, "display-v1-010ae-01234-9abcdef0")
        XCTAssertFalse(StableDisplayID.isFallback(id))
    }

    func testFallsBackToDisplayIDWhenSerialMissing() {
        let id = StableDisplayID.make(vendor: 0x10AE, model: 0x1234, serial: 0, displayID: 0x1A2B3C)
        XCTAssertEqual(id, "display-fallback-v1-001a2b3c")
        XCTAssertTrue(StableDisplayID.isFallback(id))
    }

    func testIDIsStableAcrossCallsAndDisplayIDChanges() {
        // EDID 完整时,即使 CGDisplayID 变了(重连),稳定 ID 不变
        let first = StableDisplayID.make(vendor: 1, model: 2, serial: 3, displayID: 100)
        let second = StableDisplayID.make(vendor: 1, model: 2, serial: 3, displayID: 200)
        XCTAssertEqual(first, second)

        // 回退 ID 时,CGDisplayID 变化会带来 ID 变化 —— 这是已知限制
        let fallbackA = StableDisplayID.make(vendor: 1, model: 2, serial: 0, displayID: 100)
        let fallbackB = StableDisplayID.make(vendor: 1, model: 2, serial: 0, displayID: 200)
        XCTAssertNotEqual(fallbackA, fallbackB)
    }

    func testDifferentDisplaysGetDifferentIDs() {
        let a = StableDisplayID.make(vendor: 1, model: 2, serial: 3, displayID: 10)
        let b = StableDisplayID.make(vendor: 1, model: 2, serial: 4, displayID: 10)
        XCTAssertNotEqual(a, b)
    }
}
