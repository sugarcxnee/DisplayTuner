import XCTest
@testable import DisplayTunerCore

/// Sidecar 影子 HiDPI 机制(2026-09-28 定性)的纯逻辑测试:
/// 2x 对象不进枚举,经缓存捕获后其元数据注入模式表,由
/// `DisplayCatalog` 既有收敛规则提为同尺寸代表条目。
final class HiDPIModeCacheTests: XCTestCase {

    // MARK: - ShadowModeMerge.merge

    func testMergeAppendsShadowWhenNoHiDPIVariantExists() {
        let enumModes = [
            Fixtures.mode(1116, 820, hidpi: false),
            Fixtures.mode(1280, 940, hidpi: false),
        ]
        let shadow = Fixtures.mode(1116, 820, hidpi: true)

        let merged = ShadowModeMerge.merge(enumModes: enumModes, shadowModes: [shadow])

        XCTAssertEqual(merged.count, 3, "影子条目应追加到表尾")
        XCTAssertTrue(merged.contains(shadow), "影子条目本体应在表中")
    }

    func testMergeDoesNotDuplicateWhenEnumAlreadyHasHiDPIVariant() {
        let enumModes = [
            Fixtures.mode(1920, 1080, hidpi: false),
            Fixtures.mode(1920, 1080, hidpi: true),
        ]
        let shadow = Fixtures.mode(1920, 1080, hidpi: true)

        let merged = ShadowModeMerge.merge(enumModes: enumModes, shadowModes: [shadow])

        XCTAssertEqual(merged.count, 2, "同尺寸已有 HiDPI 条目时不再注入")
    }

    func testMergeWithEmptyShadowReturnsEnumModes() {
        let enumModes = [Fixtures.mode(1116, 820, hidpi: false)]
        XCTAssertEqual(ShadowModeMerge.merge(enumModes: enumModes, shadowModes: []), enumModes)
    }

    func testMergeIgnoresNonHiDPIShadowEntries() {
        let enumModes = [Fixtures.mode(1116, 820, hidpi: false)]
        let bogus = Fixtures.mode(1280, 940, hidpi: false)
        let merged = ShadowModeMerge.merge(enumModes: enumModes, shadowModes: [bogus])
        XCTAssertEqual(merged, enumModes, "只有 HiDPI 条目才可能成为影子条目")
    }

    // MARK: - 注入后的目录收敛(端到端纯逻辑)

    func testParseModesResolvesShadowEntryAsCurrentHiDPIRepresentative() {
        // Sidecar 清晰态的实际形态:枚举全 1x,当前档是表外的 2x 影子对象
        let enumModes = [
            Fixtures.mode(1116, 820, hidpi: false),
            Fixtures.mode(1280, 940, hidpi: false),
        ]
        let shadow = Fixtures.mode(1116, 820, hidpi: true, ioFlags: 0x2000007)
        let merged = ShadowModeMerge.merge(enumModes: enumModes, shadowModes: [shadow])
        // merge 将影子条目追加到表尾(见注入规则)
        let shadowIndex = merged.count - 1
        XCTAssertEqual(merged[shadowIndex], shadow)
        let record = Fixtures.sidecarDisplay(
            currentModeIndex: shadowIndex,
            modes: merged
        )

        let display = DisplayCatalog.display(from: record)

        // 同尺寸收敛后:820p 的代表条目是 HiDPI、带当前标记
        let current = display.currentMode
        XCTAssertEqual(current?.modeKey, "1116x820@60-hidpi")
        XCTAssertTrue(current?.isHiDPI ?? false)
        // 菜单列表中该尺寸只显示一条(HiDPI),1x 变体被收敛
        let sizeMatches = display.modes.filter { $0.width == 1116 && $0.height == 820 }
        XCTAssertEqual(sizeMatches.count, 1)
        XCTAssertEqual(sizeMatches.first?.isHiDPI, true)
    }

    // MARK: - sizeKey 纯函数

    func testSizeKeyFormattingMatchesModeKeyPrefix() {
        let mode = DisplayModeInfo(
            width: 1116, height: 820,
            pixelWidth: 2232, pixelHeight: 1640,
            refreshRate: 60.4,
            ioFlags: 3,
            isHiDPI: true
        )
        XCTAssertEqual(mode.modeKey, "1116x820@60-hidpi")
        XCTAssertEqual(mode.sizeKey, "1116x820@60")
        XCTAssertEqual(HiDPIModeCache.sizeKey(width: 1116, height: 820, refreshRate: 60.4), "1116x820@60")
    }

    func testSizeKeyOfModeKeyStripsHiDPISuffix() {
        XCTAssertEqual(DisplayModeInfo.sizeKey(ofModeKey: "1116x820@60-hidpi"), "1116x820@60")
        XCTAssertEqual(DisplayModeInfo.sizeKey(ofModeKey: "1116x820@60"), "1116x820@60")
    }

    func testSameSizeVariantsShareSizeKey() {
        let hidpi = Fixtures.mode(1116, 820, hidpi: true)
        let lowdpi = Fixtures.mode(1116, 820, hidpi: false)
        let a = DisplayCatalog.modeInfo(from: hidpi, isCurrent: false)
        let b = DisplayCatalog.modeInfo(from: lowdpi, isCurrent: false)
        XCTAssertEqual(a.sizeKey, b.sizeKey, "同逻辑档的 1x/2x 变体 sizeKey 必须一致")
    }
}
