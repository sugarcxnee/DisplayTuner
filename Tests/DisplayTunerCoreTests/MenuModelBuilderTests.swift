import XCTest
@testable import DisplayTunerCore

final class MenuModelBuilderTests: XCTestCase {

    private let builder = MenuModelBuilder()

    // MARK: - 查找辅助

    private func find(
        _ entries: [MenuEntry],
        title contains: String
    ) -> [MenuEntry] {
        var result: [MenuEntry] = []
        for entry in entries {
            if entry.title.contains(contains) { result.append(entry) }
            if let children = entry.children {
                result.append(contentsOf: find(children, title: contains))
            }
        }
        return result
    }

    private func findAction(
        _ entries: [MenuEntry],
        matching predicate: (MenuAction) -> Bool
    ) -> [MenuEntry] {
        var result: [MenuEntry] = []
        for entry in entries {
            if let action = entry.action, predicate(action) { result.append(entry) }
            if let children = entry.children {
                result.append(contentsOf: findAction(children, matching: predicate))
            }
        }
        return result
    }

    private func buildWith(
        displays: [DisplayInfo],
        config: DisplayTunerConfig = DisplayTunerConfig(),
        loginItemEnabled: Bool = false,
        probe: PrivateSymbolReport? = nil,
        extraModes: [String: [DisplayModeInfo]] = [:]
    ) -> MenuModel {
        builder.build(
            displays: displays,
            config: config,
            loginItemEnabled: loginItemEnabled,
            privateProbe: probe,
            extraModes: extraModes
        )
    }

    // MARK: - 基本结构

    func testTopLevelStructureMatchesSpec() {
        let menu = buildWith(displays: [DisplayCatalog.display(from: Fixtures.builtinDisplay())])

        let titles = menu.entries.map(\.title)
        XCTAssertTrue(titles[0].hasPrefix("当前显示器:"), "首行为概览信息")
        XCTAssertEqual(titles[1], "刷新显示器")
        XCTAssertTrue(titles.contains("自动恢复上次配置"))
        XCTAssertTrue(titles.contains("实验性 Sidecar 增强"))
        XCTAssertTrue(titles.contains("开机启动"))
        XCTAssertTrue(titles.contains("日志级别"))
        XCTAssertTrue(titles.contains("打开日志文件"))
        XCTAssertTrue(titles.contains("关于 DisplayTuner"))
        XCTAssertTrue(titles.contains("退出"))
        // 分隔线存在
        XCTAssertTrue(menu.entries.contains(where: \.isSeparator))
    }

    func testEmptyDisplaysShowPlaceholder() {
        let menu = buildWith(displays: [])
        XCTAssertTrue(menu.entries.contains { $0.title == "未检测到显示器" && !$0.isEnabled })
        XCTAssertTrue(menu.entries[0].title.contains("无"))
    }

    func testMainDisplayTitleHasBadge() {
        let menu = buildWith(displays: [DisplayCatalog.display(from: Fixtures.externalDisplay(isMain: true))])
        let displayEntry = menu.entries.first { $0.children != nil }!
        XCTAssertTrue(displayEntry.title.contains("主屏"), "主屏必须带徽标")
    }

    // MARK: - 当前模式与分组

    func testCurrentModeHasCheckmarkAndIsDisabled() {
        let display = DisplayCatalog.display(from: Fixtures.externalDisplay())
        let menu = buildWith(displays: [display])

        let currentEntries = findAction(menu.entries) {
            if case .selectMode(_, let key) = $0 { return key == display.currentMode?.modeKey }
            return false
        }
        XCTAssertTrue(currentEntries.isEmpty, "当前模式不可再次选择(无 action)")

        let currentRow = find(menu.entries, title: "当前模式:").first
        XCTAssertNotNil(currentRow)
        XCTAssertFalse(currentRow!.isEnabled)

        let checked = menu.entries
            .compactMap(\.children)
            .flatMap { $0 }
            .compactMap(\.children)
            .flatMap { $0 }
            .filter(\.hasCheckmark)
        XCTAssertTrue(checked.contains { $0.title == display.currentMode?.title },
                      "当前模式条目应有 ✓")
    }

    func testRecommendedGroupComesBeforeOthers() {
        let record = RawDisplayRecord(
            displayID: 3,
            vendorNumber: 0x10AE,
            modelNumber: 1,
            serialNumber: 2,
            name: "Ext",
            bounds: .zero,
            currentModeIndex: 2,
            modes: [
                Fixtures.mode(640, 480),
                Fixtures.mode(1024, 768),
                Fixtures.mode(1920, 1080),
                Fixtures.mode(2560, 1440),
                Fixtures.mode(3840, 2160),
            ]
        )
        let display = DisplayCatalog.display(from: record)
        let menu = buildWith(displays: [display])
        let children = menu.entries.first { $0.children != nil }!.children!

        let titles = children.map(\.title)
        let recommendedIndex = titles.firstIndex(of: "推荐模式")
        let othersIndex = titles.firstIndex(of: "其他模式")
        XCTAssertNotNil(recommendedIndex, "应有推荐分组")
        XCTAssertNotNil(othersIndex, "应有其他模式分组")
        XCTAssertLessThan(recommendedIndex!, othersIndex!, "推荐分组在前")
    }

    // MARK: - Sidecar

    func testSidecarWithoutHigherModesShowsHint() {
        let sidecar = DisplayCatalog.display(from: Fixtures.sidecarDisplay(modes: [
            Fixtures.mode(2560, 1440),   // 已是最优,无更高模式
        ]))
        let menu = buildWith(displays: [sidecar])

        XCTAssertTrue(menu.entries
            .compactMap(\.children)
            .flatMap { $0 }
            .contains { $0.title == "当前随航连接未提供更高分辨率模式" && !$0.isEnabled })
    }

    func testUnlockedFreeSidecarShowsSeedEntry() {
        // 原始形态(单档、无锚点变体):显示一次性解锁入口
        let sidecar = DisplayCatalog.display(from: Fixtures.sidecarDisplay(modes: [
            Fixtures.mode(1180, 820),
        ]))
        let menu = buildWith(displays: [sidecar])

        let seedEntry = menu.entries
            .compactMap(\.children)
            .flatMap { $0 }
            .first { $0.title == "解锁高分辨率模式(一次性)" }
        XCTAssertNotNil(seedEntry, "未解锁的 Sidecar 应提供播种入口")
        XCTAssertEqual(seedEntry?.action,
                       .seedHighResolutionModes(displayStableID: sidecar.stableID))
    }

    func testUnlockedSidecarHidesSeedEntry() {
        // 已解锁(锚点 + 高档):只显示说明行,不显示播种入口
        let sidecar = DisplayCatalog.display(from: Fixtures.sidecarDisplay(modes: [
            Fixtures.mode(1180, 820),
            Fixtures.mode(2360, 1640),
            Fixtures.mode(1180, 820, ioFlags: DisplayModeIOFlags.valid),
        ]))
        let menu = buildWith(displays: [sidecar])

        let titles = menu.entries.compactMap(\.children).flatMap { $0 }.map(\.title)
        XCTAssertFalse(titles.contains("解锁高分辨率模式(一次性)"), "已解锁不再提供播种入口")
    }

    func testExternalDisplayNeverShowsSidecarHint() {
        let external = DisplayCatalog.display(from: Fixtures.externalDisplay())
        let menu = buildWith(displays: [external])

        XCTAssertNil(find(menu.entries, title: "未提供更高分辨率").first)
    }

    func testSidecarEntryHasSidecarBadge() {
        let sidecar = DisplayCatalog.display(from: Fixtures.sidecarDisplay())
        let menu = buildWith(displays: [sidecar])
        let entry = menu.entries.first { $0.children != nil }!
        XCTAssertTrue(entry.title.contains("Sidecar"))
    }

    // MARK: - 开关状态

    func testAutoRestoreStateReflected() {
        let display = DisplayCatalog.display(from: Fixtures.builtinDisplay())
        var config = DisplayTunerConfig()
        config.autoRestore = true
        XCTAssertTrue(buildWith(displays: [display], config: config)
            .entries.first { $0.title == "自动恢复上次配置" }!.hasCheckmark)

        config.autoRestore = false
        XCTAssertFalse(buildWith(displays: [display], config: config)
            .entries.first { $0.title == "自动恢复上次配置" }!.hasCheckmark)
    }

    func testExperimentalToggleStateAndProbeSuffix() {
        let display = DisplayCatalog.display(from: Fixtures.sidecarDisplay())
        var config = DisplayTunerConfig()
        config.experimentalSidecar = false
        let offMenu = buildWith(displays: [display], config: config)
        XCTAssertFalse(offMenu.entries.first { $0.title == "实验性 Sidecar 增强" }!.hasCheckmark)
        XCTAssertEqual(offMenu.entries.first { $0.title == "实验性 Sidecar 增强" }!.title,
                       "实验性 Sidecar 增强", "关闭时不附加探测状态")

        config.experimentalSidecar = true
        let report = PrivateSymbolReport(libraryPath: "x", foundSymbols: [], missingSymbols: ["a"])
        let onMenu = buildWith(displays: [display], config: config, probe: report)
        XCTAssertTrue(onMenu.entries.first { $0.title.hasPrefix("实验性 Sidecar 增强") }!.hasCheckmark)
        XCTAssertTrue(onMenu.entries.first { $0.title.hasPrefix("实验性 Sidecar 增强") }!.title
            .contains("未找到私有符号"))
    }

    func testLaunchAtLoginStateReflected() {
        let display = DisplayCatalog.display(from: Fixtures.builtinDisplay())
        XCTAssertTrue(buildWith(displays: [display], loginItemEnabled: true)
            .entries.first { $0.title == "开机启动" }!.hasCheckmark)
        XCTAssertFalse(buildWith(displays: [display], loginItemEnabled: false)
            .entries.first { $0.title == "开机启动" }!.hasCheckmark)
    }

    func testLogLevelRadioMarksCurrent() {
        let display = DisplayCatalog.display(from: Fixtures.builtinDisplay())
        var config = DisplayTunerConfig()
        config.logLevel = .debug

        let menu = buildWith(displays: [display], config: config)
        let logMenu = menu.entries.first { $0.title == "日志级别" }!
        let checked = logMenu.children!.filter(\.hasCheckmark)
        XCTAssertEqual(checked.map(\.title), ["调试"])
    }

    // MARK: - 过滤

    func testFilterSubmenuReflectsSavedFilters() {
        let external = DisplayCatalog.display(from: Fixtures.externalDisplay())
        var config = DisplayTunerConfig()
        config.perDisplay[external.stableID] = PerDisplayConfig(filters: [.hidpiOnly])

        let menu = buildWith(displays: [external], config: config)
        let displayChildren = menu.entries.first { $0.children != nil }!.children!
        let filterMenu = displayChildren.first { $0.title == "过滤" }!
        let hidpi = filterMenu.children!.first { $0.title == "仅显示 HiDPI" }!
        let geCurrent = filterMenu.children!.first { $0.title.contains("≥ 当前分辨率") }!
        XCTAssertTrue(hidpi.hasCheckmark)
        XCTAssertFalse(geCurrent.hasCheckmark)
    }

    func testFilterHidesNonMatchingModesButKeepsCurrent() {
        let external = DisplayCatalog.display(from: Fixtures.externalDisplay())
        // external fixture: 1920 hidpi, 2560 hidpi(当前), 1920 非 hidpi
        var config = DisplayTunerConfig()
        config.perDisplay[external.stableID] = PerDisplayConfig(filters: [.hidpiOnly])

        let menu = buildWith(displays: [external], config: config)
        let modeEntries = findAction(menu.entries) {
            if case .selectMode = $0 { return true }
            return false
        }.map(\.title)

        XCTAssertFalse(modeEntries.contains { $0.contains("1920×1080 @") && !$0.contains("HiDPI") },
                       "非 HiDPI 模式应被过滤")
    }

    // MARK: - 增强模式分组

    func testExtraModesShownOnlyWhenExperimentalEnabled() {
        let sidecar = DisplayCatalog.display(from: Fixtures.sidecarDisplay(modes: [
            Fixtures.mode(1920, 1080),
        ]))
        let extra = [DisplayModeInfo(
            width: 2048, height: 1536,
            pixelWidth: 4096, pixelHeight: 3072,
            refreshRate: 60,
            ioFlags: DisplayModeIOFlags.valid | DisplayModeIOFlags.safe,
            isHiDPI: true
        )]

        var config = DisplayTunerConfig()
        config.experimentalSidecar = true
        let onMenu = buildWith(
            displays: [sidecar], config: config,
            extraModes: [sidecar.stableID: extra]
        )
        XCTAssertTrue(find(onMenu.entries, title: "增强模式(实验)").isNonEmpty)

        config.experimentalSidecar = false
        let offMenu = buildWith(
            displays: [sidecar], config: config,
            extraModes: [sidecar.stableID: extra]
        )
        XCTAssertNil(find(offMenu.entries, title: "增强模式").first)
    }

    // MARK: - 恢复默认与高级

    func testRestoreDefaultActionPresentPerDisplay() {
        let external = DisplayCatalog.display(from: Fixtures.externalDisplay())
        let menu = buildWith(displays: [external])
        let actions = findAction(menu.entries) {
            if case .restoreDefaultMode(let id) = $0 { return id == external.stableID }
            return false
        }
        XCTAssertEqual(actions.count, 1)
    }

    func testAdvancedSubmenuMirrorsExperimentalToggle() {
        let sidecar = DisplayCatalog.display(from: Fixtures.sidecarDisplay())
        var config = DisplayTunerConfig()
        config.experimentalSidecar = true
        let menu = buildWith(displays: [sidecar], config: config)

        let advanced = find(menu.entries, title: "高级").first
        XCTAssertNotNil(advanced)
        let toggle = advanced!.children!.first { $0.title == "实验性 Sidecar 增强" }!
        XCTAssertTrue(toggle.hasCheckmark)
    }
}

extension Array {
    var isNonEmpty: Bool { !isEmpty }
}
