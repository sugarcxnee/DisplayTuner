import XCTest
import CoreGraphics
@testable import DisplayTunerCore

final class DisplayCatalogTests: XCTestCase {

    // MARK: - 边界:0 / 1 / 多显示器

    func testEmptyRecordsProduceEmptyDisplays() {
        XCTAssertEqual(DisplayCatalog.displays(from: []), [])
    }

    func testSingleDisplaySnapshot() {
        let displays = DisplayCatalog.displays(from: [Fixtures.builtinDisplay()])
        XCTAssertEqual(displays.count, 1)
        XCTAssertEqual(displays[0].category, .builtin)
        XCTAssertEqual(displays[0].modes.count, 3)
        XCTAssertEqual(displays[0].currentMode?.modeKey, "1512x982@60-hidpi")
    }

    func testMultiDisplaySnapshotClassification() {
        let displays = DisplayCatalog.displays(from: [
            Fixtures.builtinDisplay(),
            Fixtures.sidecarDisplay(),
            Fixtures.externalDisplay(),
        ])
        XCTAssertEqual(displays.count, 3)
        XCTAssertEqual(displays[0].category, .builtin)
        XCTAssertEqual(displays[1].category, .sidecar)
        XCTAssertEqual(displays[2].category, .external)
        // 每个显示器稳定 ID 互不相同
        XCTAssertEqual(Set(displays.map(\.stableID)).count, 3)
    }

    // MARK: - 分类优先级

    func testSidecarWinsOverMain() {
        // Sidecar 被设为主屏时,仍按 Sidecar 分类(功能优先)
        var record = Fixtures.sidecarDisplay()
        record = RawDisplayRecord(
            displayID: record.displayID,
            vendorNumber: record.vendorNumber,
            modelNumber: record.modelNumber,
            serialNumber: record.serialNumber,
            name: record.name,
            bounds: record.bounds,
            rotation: record.rotation,
            isMain: true,
            isBuiltin: false,
            currentModeIndex: record.currentModeIndex,
            modes: record.modes
        )
        XCTAssertEqual(DisplayCatalog.classify(record: record, isSidecar: true), .sidecar)
    }

    func testMainExternalDisplayClassifiedAsMain() {
        let record = Fixtures.externalDisplay(isMain: true)
        let info = DisplayCatalog.display(from: record)
        XCTAssertEqual(info.category, .main)
        XCTAssertTrue(info.isMain, "isMain 原始标记必须保留,用于菜单主屏徽标")
    }

    func testUnknownWhenNoEDIDAndNoSignals() {
        let record = RawDisplayRecord(
            displayID: 7,
            vendorNumber: 0,
            modelNumber: 0,
            serialNumber: 0,
            name: "",
            bounds: .zero,
            modes: []
        )
        // 无模式 → 启发式不触发(0 分),分类为 unknown
        let info = DisplayCatalog.display(from: record)
        XCTAssertEqual(info.category, .unknown)
        XCTAssertNil(info.currentMode)
    }

    // MARK: - 模式解析

    func testDuplicateModesAreDeduplicated() {
        // 2026-09-28 语义更新:同尺寸的 1x/HiDPI 变体收敛为一条 HiDPI
        // (1x 渲染拉伸到面板是"切档变糊"的根因),不再作为独立条目保留。
        let record = RawDisplayRecord(
            displayID: 3,
            vendorNumber: 0x10AE,
            modelNumber: 1,
            serialNumber: 2,
            name: "Ext",
            bounds: .zero,
            currentModeIndex: 2,
            modes: [
                Fixtures.mode(1920, 1080),                    // key A
                Fixtures.mode(1920, 1080, refresh: 60),       // key A 重复
                Fixtures.mode(1920, 1080, hidpi: false),      // 同尺寸 1x → 收敛
            ]
        )
        let modes = DisplayCatalog.parseModes(record)
        XCTAssertEqual(modes.count, 1)
        XCTAssertTrue(modes[0].isHiDPI, "收敛后只保留 HiDPI 变体")
        XCTAssertTrue(modes[0].isCurrent, "当前档标记传播到收敛条目")
    }

    func testCurrentModeIsPreferedAmongDuplicates() {
        // 当前模式与列表前面的模式同 key 但变体不同 → 归并时保留当前那条
        let record = RawDisplayRecord(
            displayID: 3,
            vendorNumber: 0x10AE,
            modelNumber: 1,
            serialNumber: 2,
            name: "Ext",
            bounds: .zero,
            currentModeIndex: 1,
            modes: [
                Fixtures.mode(1920, 1080),              // 非 current,key A
                Fixtures.mode(1920, 1080),              // current,key A
            ]
        )
        let modes = DisplayCatalog.parseModes(record)
        XCTAssertEqual(modes.count, 1)
        XCTAssertTrue(modes[0].isCurrent)
    }

    func testHiDPIDetection() {
        let hidpi = DisplayCatalog.modeInfo(from: Fixtures.mode(1920, 1080, hidpi: true), isCurrent: false)
        XCTAssertTrue(hidpi.isHiDPI)
        let lodpi = DisplayCatalog.modeInfo(from: Fixtures.mode(1920, 1080, hidpi: false), isCurrent: false)
        XCTAssertFalse(lodpi.isHiDPI)
    }

    func testUnsafeModesAreFlagged() {
        let missingSafe = Fixtures.mode(1920, 1080, ioFlags: DisplayModeIOFlags.valid)
        XCTAssertFalse(ModeSafety.isSafe(mode: missingSafe))

        let tiny = Fixtures.mode(320, 200)
        XCTAssertFalse(ModeSafety.isSafe(mode: tiny))

        let zeroRefresh = Fixtures.mode(1920, 1080, refresh: 0)
        XCTAssertFalse(ModeSafety.isSafe(mode: zeroRefresh))

        let normal = Fixtures.mode(1920, 1080)
        XCTAssertTrue(ModeSafety.isSafe(mode: normal))
    }

    func testMenuTitleFallsBackToCategoryWhenNameEmpty() {
        let record = RawDisplayRecord(
            displayID: 4,
            vendorNumber: 0,
            modelNumber: 0,
            serialNumber: 0,
            name: "   ",
            bounds: .zero,
            isMain: true,
            currentModeIndex: 0,
            modes: [Fixtures.mode(1024, 768)]
        )
        // 名称空白:unknown 分类(1024 在 iPad 范围但 vendor=0 且全 HiDPI → +1,仅 1 分不触发)
        let info = DisplayCatalog.display(from: record)
        XCTAssertEqual(info.menuTitle, info.category.displayName)
    }

    func testLogDescriptorDoesNotLeakNameOrSerial() {
        let info = DisplayCatalog.display(from: Fixtures.externalDisplay(name: "王五的显示器"))
        XCTAssertFalse(info.logDescriptor.contains("王五"))
        XCTAssertFalse(info.logDescriptor.contains("9abcdef0"))
        XCTAssertTrue(info.logDescriptor.hasPrefix("外接显示器#"))
    }
}


// MARK: - 同尺寸变体收敛(2026-09-28 "切档变糊"根因)

final class ModeVariantCollapseTests: XCTestCase {

    private func record(_ modes: [RawModeRecord], current: Int = 0) -> RawDisplayRecord {
        Fixtures.sidecarDisplay(currentModeIndex: current, modes: modes)
    }

    func testSameSizeVariantsCollapseToHiDPI() {
        // 同尺寸 1x + 2x 共存 → 菜单只暴露 HiDPI 一条
        let modes = DisplayCatalog.parseModes(record([
            Fixtures.mode(1116, 820, hidpi: false),
            Fixtures.mode(1116, 820, hidpi: true),
        ]))
        XCTAssertEqual(modes.count, 1, "同尺寸收敛为一条")
        XCTAssertTrue(modes[0].isHiDPI, "收敛条目恒为 HiDPI 变体")
    }

    func testCurrentOnLowVariantMarksCollapsedEntryCurrent() {
        // 当前停在 1x 变体:收敛后的 HiDPI 条目仍标记为当前(菜单勾选正确),
        // 用户再点该条即真正升到 2x 渲染。
        let modes = DisplayCatalog.parseModes(record([
            Fixtures.mode(1116, 820, hidpi: true),
            Fixtures.mode(1116, 820, hidpi: false),
        ], current: 1))
        XCTAssertEqual(modes.count, 1)
        XCTAssertTrue(modes[0].isHiDPI)
        XCTAssertTrue(modes[0].isCurrent, "当前标记按尺寸组传播")
    }

    func testDifferentSizesUnaffected() {
        let modes = DisplayCatalog.parseModes(record([
            Fixtures.mode(1116, 820),
            Fixtures.mode(1600, 1200),
            Fixtures.mode(1600, 1200, hidpi: false),
        ]))
        XCTAssertEqual(modes.count, 2)
        XCTAssertTrue(modes.allSatisfy(\.isHiDPI))
    }
}
