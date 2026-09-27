import XCTest
@testable import DisplayTunerCore

final class SidecarHeuristicTests: XCTestCase {

    func testNameHintAloneTriggersSidecar() {
        // 名称为 iPad 名 + 无 EDID + 模式形状 → 综合高分
        let record = Fixtures.sidecarDisplay()
        XCTAssertTrue(SidecarHeuristic.isLikelySidecar(record))
    }

    func testNameContainsSidecarKeyword() {
        let record = Fixtures.sidecarDisplay(name: "Sidecar Display", displayID: 9)
        XCTAssertTrue(SidecarHeuristic.isLikelySidecar(record))
    }

    func testLocalizedSidecarKeywordMatches() {
        let record = Fixtures.sidecarDisplay(name: "随航显示器", displayID: 9)
        XCTAssertTrue(SidecarHeuristic.isLikelySidecar(record))
    }

    func testNoEDIDPlusiPadShapedModesWithoutName() {
        // 无名称、无 EDID,但模式全部 HiDPI 且最大逻辑宽在 iPad 范围 → 2+1=3 分,判定 Sidecar
        let record = RawDisplayRecord(
            displayID: 5,
            vendorNumber: 0,
            modelNumber: 0,
            serialNumber: 0,
            name: "Display",
            bounds: .zero,
            currentModeIndex: 0,
            modes: [Fixtures.mode(2128, 1480)]
        )
        XCTAssertTrue(SidecarHeuristic.isLikelySidecar(record))
    }

    func testRegularExternalDisplayIsNotSidecar() {
        // 有 EDID、名称无关键词、最大逻辑宽超出 iPad 范围 → 0 分
        let record = Fixtures.externalDisplay()
        XCTAssertFalse(SidecarHeuristic.isLikelySidecar(record))
    }

    func testBuiltinDisplayIsNeverSidecar() {
        let record = RawDisplayRecord(
            displayID: 1,
            vendorNumber: 0,
            modelNumber: 0,
            serialNumber: 0,
            name: "张三的 iPad",   // 即便名称像 Sidecar
            bounds: .zero,
            isMain: true,
            isBuiltin: true,
            currentModeIndex: 0,
            modes: [Fixtures.mode(1512, 982)]
        )
        XCTAssertEqual(SidecarHeuristic.score(
            name: record.name,
            vendor: record.vendorNumber,
            model: record.modelNumber,
            serial: record.serialNumber,
            isBuiltin: record.isBuiltin,
            modes: record.modes
        ), 0)
        XCTAssertFalse(SidecarHeuristic.isLikelySidecar(record))
    }

    func testAirPlayLikeVirtualDisplayWithoutNameIsNotEnough() {
        // 无 EDID(2 分)但模式形状不像 iPad(最大逻辑宽 5120 超范围,且非全 HiDPI)→ 不足 3 分
        let record = RawDisplayRecord(
            displayID: 6,
            vendorNumber: 0,
            modelNumber: 0,
            serialNumber: 0,
            name: "AirPlay",
            bounds: .zero,
            currentModeIndex: 0,
            modes: [
                Fixtures.mode(5120, 2880, hidpi: false),
                Fixtures.mode(1920, 1080, hidpi: false),
            ]
        )
        XCTAssertFalse(SidecarHeuristic.isLikelySidecar(record))
    }
}
