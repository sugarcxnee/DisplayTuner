import XCTest
@testable import DisplayTunerCore

final class ModeRankerTests: XCTestCase {

    func modeInfo(
        _ w: Int,
        _ h: Int,
        refresh: Double = 60,
        hidpi: Bool = true,
        safe: Bool = true,
        ioFlags: UInt32 = DisplayModeIOFlags.valid | DisplayModeIOFlags.safe,
        current: Bool = false
    ) -> DisplayModeInfo {
        DisplayModeInfo(
            width: w,
            height: h,
            pixelWidth: w * (hidpi ? 2 : 1),
            pixelHeight: h * (hidpi ? 2 : 1),
            refreshRate: refresh,
            ioFlags: ioFlags,
            isHiDPI: hidpi,
            isCurrent: current,
            isSafe: safe
        )
    }

    // MARK: - 排序

    func testHiDRanksAboveNonHiDPI() {
        let sorted = ModeRanker.sort(
            [modeInfo(1920, 1080, hidpi: false), modeInfo(1280, 720, hidpi: true)],
            isSidecar: false
        )
        XCTAssertTrue(sorted[0].isHiDPI)
    }

    func testHigherResolutionRanksFirstWithinHiDPI() {
        let sorted = ModeRanker.sort(
            [modeInfo(1920, 1080), modeInfo(2560, 1440)],
            isSidecar: false
        )
        XCTAssertEqual(sorted[0].modeKey, "2560x1440@60-hidpi")
    }

    func testComfortableRefreshRatePreferred() {
        let sorted = ModeRanker.sort(
            [modeInfo(1920, 1080, refresh: 30), modeInfo(1920, 1080, refresh: 60)],
            isSidecar: false
        )
        XCTAssertEqual(sorted[0].refreshRate, 60)
    }

    func testInterlacedPenalized() {
        let flags = DisplayModeIOFlags.valid | DisplayModeIOFlags.safe | DisplayModeIOFlags.interlaced
        let sorted = ModeRanker.sort(
            [modeInfo(1920, 1080, ioFlags: flags), modeInfo(1280, 720)],
            isSidecar: false
        )
        // 1080p 隔行的得分被大幅扣减后仍应排在 720p 之下?两信号都为 HiDPI,分辨率差 9 分,隔行扣 30 分
        XCTAssertEqual(sorted[0].modeKey, "1280x720@60-hidpi")
    }

    func testUnsafeModeSinksToBottom() {
        let sorted = ModeRanker.sort(
            [modeInfo(4096, 2304, safe: false), modeInfo(640, 480)],
            isSidecar: false
        )
        XCTAssertEqual(sorted[0].modeKey, "640x480@60-hidpi")
    }

    func testSidecarAspectBonusPrefers4x3() {
        // 2048×1536(4:3) vs 1920×1200(16:10),面积接近时 Sidecar 应偏好 4:3
        let sorted = ModeRanker.sort(
            [modeInfo(1920, 1200), modeInfo(2048, 1536)],
            isSidecar: true
        )
        XCTAssertEqual(sorted[0].modeKey, "2048x1536@60-hidpi")
    }

    func testSortIsStableForEqualScores() {
        let a = modeInfo(1920, 1080, refresh: 60)
        let b = modeInfo(1920, 1080, refresh: 60)
        let sorted = ModeRanker.sort([a, b], isSidecar: false)
        XCTAssertEqual(sorted[0], a)
        XCTAssertEqual(sorted[1], b)
    }

    // MARK: - 推荐

    func testRecommendedMarksTopSafeModes() {
        let modes = [
            modeInfo(640, 480),
            modeInfo(1920, 1080),
            modeInfo(2560, 1440),
            modeInfo(2048, 1536),
            modeInfo(4096, 2304, safe: false),   // 不安全,不进推荐
        ]
        let marked = ModeRanker.markRecommended(modes, isSidecar: false)
        let recommended = marked.filter(\.isRecommended).map(\.modeKey)
        XCTAssertEqual(recommended.count, ModeRanker.recommendedLimit)
        XCTAssertFalse(recommended.contains("4096x2304@60-hidpi"))
        // 输入顺序保持不变(推荐只是打标)
        XCTAssertEqual(marked.map(\.width), modes.map(\.width))
    }

    func testRecommendedEmptyModesInput() {
        XCTAssertEqual(ModeRanker.markRecommended([], isSidecar: true), [])
    }

    // MARK: - 过滤

    func testFilterHiDPIOnlyKeepsCurrentEvenIfNotMatching() {
        let current = modeInfo(1920, 1080, hidpi: false, current: true)
        let modes = [
            current,
            modeInfo(1280, 720, hidpi: true),
            modeInfo(1024, 768, hidpi: false),
        ]
        let filtered = ModeRanker.filter(modes, by: [.hidpiOnly], current: current)
        XCTAssertEqual(filtered.map(\.modeKey), [current.modeKey, "1280x720@60-hidpi"])
    }

    func testFilterAtLeastCurrentResolution() {
        let current = modeInfo(1920, 1080, current: true)
        let modes = [
            current,
            modeInfo(3840, 2160),
            modeInfo(1280, 720),
        ]
        let filtered = ModeRanker.filter(modes, by: [.atLeastCurrentResolution], current: current)
        XCTAssertEqual(filtered.map(\.modeKey).sorted(), [current.modeKey, "3840x2160@60-hidpi"].sorted())
    }

    func testFilterAspect16x10() {
        let current = modeInfo(1920, 1080, current: true)
        let modes = [
            current,
            modeInfo(1920, 1200),
            modeInfo(2048, 1536),   // 4:3
        ]
        let filtered = ModeRanker.filter(modes, by: [.aspect16x10], current: current)
        XCTAssertEqual(filtered.map(\.modeKey).sorted(), [current.modeKey, "1920x1200@60-hidpi"].sorted())
    }

    func testCombinedFilters() {
        let current = modeInfo(1920, 1080, current: true)
        let modes = [
            current,
            modeInfo(1920, 1200),       // 16:10 + HiDPI + ≥当前 → 通过
            modeInfo(1920, 1200, hidpi: false),  // 16:10 但非 HiDPI → 被滤掉
            modeInfo(1280, 800),        // 16:10 + HiDPI 但 < 当前 → 被滤掉
        ]
        let filtered = ModeRanker.filter(
            modes,
            by: [.hidpiOnly, .atLeastCurrentResolution, .aspect16x10],
            current: current
        )
        XCTAssertEqual(filtered.map(\.modeKey).sorted(), [current.modeKey, "1920x1200@60-hidpi"].sorted())
    }

    func testEmptyFiltersReturnAll() {
        let modes = [modeInfo(1920, 1080), modeInfo(640, 480)]
        XCTAssertEqual(ModeRanker.filter(modes, by: [], current: nil).count, 2)
    }

    func testFilterWithoutCurrentKeepsEverythingWhenRuleNeedsCurrent() {
        let modes = [modeInfo(640, 480), modeInfo(1920, 1080)]
        // ≥当前 规则在无当前模式时不过滤
        XCTAssertEqual(ModeRanker.filter(modes, by: [.atLeastCurrentResolution], current: nil).count, 2)
    }

    // MARK: - Sidecar 更高模式判定

    func testHasHigherModesTrueWhenBiggerModeExists() {
        let current = modeInfo(1280, 720, current: true)
        XCTAssertTrue(ModeRanker.hasHigherModes(than: current, in: [current, modeInfo(1920, 1080)]))
    }

    func testHasHigherModesTrueForHiDPIUpgrade() {
        let current = modeInfo(1920, 1080, hidpi: false, current: true)
        XCTAssertTrue(ModeRanker.hasHigherModes(than: current, in: [current, modeInfo(1920, 1080)]))
    }

    func testHasHigherModesFalseWhenCurrentIsBest() {
        let current = modeInfo(2560, 1440, current: true)
        XCTAssertFalse(ModeRanker.hasHigherModes(
            than: current,
            in: [current, modeInfo(1920, 1080), modeInfo(1280, 720)]
        ))
    }

    func testHasHigherModesIgnoresUnsafe() {
        let current = modeInfo(1920, 1080, current: true)
        XCTAssertFalse(ModeRanker.hasHigherModes(
            than: current,
            in: [current, modeInfo(4096, 2304, safe: false)]
        ))
    }

    func testHasHigherModesWithNilCurrentAndNoModes() {
        XCTAssertFalse(ModeRanker.hasHigherModes(than: nil, in: []))
    }
}
