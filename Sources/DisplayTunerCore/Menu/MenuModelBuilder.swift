import Foundation

/// 菜单模型构建器(纯函数)。每次菜单打开时以最新枚举 + 配置重建,避免状态过期。
public final class MenuModelBuilder {

    public init() {}

    /// - Parameters:
    ///   - displays: 最新枚举结果。
    ///   - config: 当前配置(过滤偏好、开关)。
    ///   - loginItemEnabled: 开机启动当前状态。
    ///   - privateProbe: 私有符号探测报告(实验开关开启且已探测时提供)。
    ///   - extraModes: 实验增强揭示的额外模式,按稳定 ID 索引。
    ///   - activeVirtualDisplays: 运行中的虚拟屏会话(稳定 ID → 规格)。
    ///   - virtualDisplayAvailability: 虚拟屏能力报告(nil = 未探测)。
    public func build(
        displays: [DisplayInfo],
        config: DisplayTunerConfig,
        loginItemEnabled: Bool,
        privateProbe: PrivateSymbolReport?,
        extraModes: [String: [DisplayModeInfo]] = [:],
        activeVirtualDisplays: [String: VirtualDisplaySpec] = [:],
        virtualDisplayAvailability: VirtualDisplayAvailability? = nil
    ) -> MenuModel {
        var entries: [MenuEntry] = []

        // 头部:概览 + 刷新
        entries.append(headerEntry(displays: displays))
        entries.append(MenuEntry(title: "刷新显示器", action: .refresh))
        entries.append(.separator())

        // 显示器列表
        if displays.isEmpty {
            entries.append(MenuEntry(title: "未检测到显示器", isEnabled: false))
        } else {
            for display in displays {
                entries.append(displayEntry(
                    display,
                    config: config,
                    extraModes: extraModes[display.stableID] ?? [],
                    activeVirtualDisplay: activeVirtualDisplays[display.stableID],
                    virtualDisplayAvailability: virtualDisplayAvailability
                ))
            }
        }

        // 全局开关
        entries.append(.separator())
        entries.append(MenuEntry(
            title: "自动恢复上次配置",
            state: config.autoRestore ? .on : .none,
            action: .toggleAutoRestore
        ))
        entries.append(experimentalEntry(config: config, probe: privateProbe))
        entries.append(MenuEntry(
            title: "开机启动",
            state: loginItemEnabled ? .on : .none,
            action: .toggleLaunchAtLogin
        ))
        entries.append(logLevelEntry(config: config))
        entries.append(MenuEntry(title: "打开日志文件", action: .openLogFile))
        entries.append(MenuEntry(title: "关于 DisplayTuner", action: .showAbout))
        entries.append(.separator())
        entries.append(MenuEntry(title: "退出", action: .quit))

        return MenuModel(entries: entries)
    }

    // MARK: - 头部

    private func headerEntry(displays: [DisplayInfo]) -> MenuEntry {
        let summary: String
        switch displays.count {
        case 0: summary = "无"
        case 1: summary = displays[0].category.displayName
        default:
            summary = displays
                .map(\.category.displayName)
                .joined(separator: " / ")
        }
        return MenuEntry(title: "当前显示器:\(summary)", isEnabled: false)
    }

    // MARK: - 单个显示器

    private func displayEntry(
        _ display: DisplayInfo,
        config: DisplayTunerConfig,
        extraModes: [DisplayModeInfo],
        activeVirtualDisplay: VirtualDisplaySpec?,
        virtualDisplayAvailability: VirtualDisplayAvailability?
    ) -> MenuEntry {
        let perDisplay = config.perDisplay[display.stableID] ?? PerDisplayConfig()
        let filtered = ModeRanker.filter(
            display.modes,
            by: perDisplay.filters,
            current: display.currentMode
        )
        let recommended = filtered.filter(\.isRecommended)
        let current = filtered.first(where: \.isCurrent)
        let others = filtered.filter { !$0.isRecommended && !$0.isCurrent }

        var children: [MenuEntry] = []

        // 当前模式信息行
        let currentTitle = display.currentMode.map { "当前模式:\($0.title)" } ?? "当前模式:未知"
        children.append(MenuEntry(title: currentTitle, isEnabled: false))
        children.append(.separator())

        // 推荐分组:当前模式(若有)置顶 + 其余推荐
        var recommendedItems: [MenuEntry] = []
        if let current = current {
            recommendedItems.append(modeEntry(current, display: display, isCurrent: true))
        }
        recommendedItems.append(contentsOf: recommended
            .filter { !$0.isCurrent }
            .map { modeEntry($0, display: display, isCurrent: false) })
        if !recommendedItems.isEmpty {
            children.append(submenu(title: "推荐模式", items: recommendedItems))
        }

        // 其他模式
        if !others.isEmpty {
            children.append(submenu(
                title: "其他模式",
                items: others.map { modeEntry($0, display: display, isCurrent: false) }
            ))
        }

        // Sidecar 且无更高模式:如实提示,不伪造
        if display.isSidecar,
           !ModeRanker.hasHigherModes(than: display.currentMode, in: filtered) {
            children.append(MenuEntry(
                title: "当前随航连接未提供更高分辨率模式",
                isEnabled: false
            ))
        }

        // 实验增强揭示的额外模式
        if config.experimentalSidecar, !extraModes.isEmpty {
            children.append(submenu(
                title: "增强模式(实验)",
                items: extraModes.map { modeEntry($0, display: display, isCurrent: false) }
            ))
        }

        // 过滤
        children.append(filterEntry(display: display, filters: perDisplay.filters))

        // 恢复默认 + 高级
        children.append(MenuEntry(
            title: "恢复默认模式",
            action: .restoreDefaultMode(displayStableID: display.stableID)
        ))
        var advancedChildren: [MenuEntry] = [
            MenuEntry(
                title: "实验性 Sidecar 增强",
                state: config.experimentalSidecar ? .on : .none,
                action: .toggleExperimentalSidecar
            )
        ]
        if display.isSidecar {
            advancedChildren.append(virtualDisplayEntry(
                display,
                activeSpec: activeVirtualDisplay,
                availability: virtualDisplayAvailability
            ))
        }
        children.append(MenuEntry(title: "高级", children: advancedChildren))

        return MenuEntry(
            title: displayMenuTitle(display),
            children: children
        )
    }

    private func displayMenuTitle(_ display: DisplayInfo) -> String {
        var title = display.menuTitle
        var badges: [String] = []
        if display.isMain { badges.append("主屏") }
        if display.category == .sidecar { badges.append("Sidecar") }
        if !badges.isEmpty {
            title += "(\(badges.joined(separator: "·")))"
        }
        if let current = display.currentMode {
            title += " — \(current.title)"
        }
        return title
    }

    private func modeEntry(
        _ mode: DisplayModeInfo,
        display: DisplayInfo,
        isCurrent: Bool
    ) -> MenuEntry {
        var title = mode.title
        if !mode.isSafe { title += "(未验证安全)" }
        return MenuEntry(
            title: title,
            isEnabled: !isCurrent,
            state: isCurrent ? .on : .none,
            action: isCurrent
                ? nil
                : .selectMode(displayStableID: display.stableID, modeKey: mode.modeKey)
        )
    }

    // MARK: - 虚拟屏(实验)

    private func virtualDisplayEntry(
        _ display: DisplayInfo,
        activeSpec: VirtualDisplaySpec?,
        availability: VirtualDisplayAvailability?
    ) -> MenuEntry {
        // 能力不可用:如实提示,不显示档位
        if let availability = availability, !availability.isAvailable {
            return MenuEntry(title: "虚拟屏(实验)— \(availability.statusDescription)", isEnabled: false)
        }

        if let activeSpec = activeSpec {
            return MenuEntry(title: "虚拟屏(实验)", children: [
                MenuEntry(
                    title: "运行中 \(activeSpec.title)",
                    isEnabled: false,
                    state: .on
                ),
                MenuEntry(
                    title: "停止虚拟屏",
                    action: .stopVirtualDisplay(displayStableID: display.stableID)
                ),
            ])
        }

        let presets = VirtualDisplayPresets.presets(for: display)
        if presets.isEmpty {
            return MenuEntry(title: "虚拟屏(实验)— 无可用基准分辨率", isEnabled: false)
        }
        return MenuEntry(title: "虚拟屏(实验)", children: presets.map { preset in
            MenuEntry(
                title: preset.title,
                action: .startVirtualDisplay(
                    displayStableID: display.stableID,
                    width: preset.spec.width,
                    height: preset.spec.height
                )
            )
        })
    }

    private func filterEntry(display: DisplayInfo, filters: Set<ModeFilter>) -> MenuEntry {
        let items = ModeFilter.allCases.map { filter in
            MenuEntry(
                title: filter.displayName,
                state: filters.contains(filter) ? .on : .none,
                action: .toggleFilter(displayStableID: display.stableID, filter: filter)
            )
        }
        return MenuEntry(title: "过滤", children: items)
    }

    // MARK: - 全局

    private func experimentalEntry(config: DisplayTunerConfig, probe: PrivateSymbolReport?) -> MenuEntry {
        var title = "实验性 Sidecar 增强"
        if config.experimentalSidecar, let probe = probe {
            title += " — \(probe.statusDescription)"
        }
        return MenuEntry(
            title: title,
            state: config.experimentalSidecar ? .on : .none,
            action: .toggleExperimentalSidecar
        )
    }

    private func logLevelEntry(config: DisplayTunerConfig) -> MenuEntry {
        let items = LogLevel.allCases.map { level in
            MenuEntry(
                title: level.displayName,
                state: config.logLevel == level ? .on : .none,
                action: .setLogLevel(level)
            )
        }
        return MenuEntry(title: "日志级别", children: items)
    }

    private func submenu(title: String, items: [MenuEntry]) -> MenuEntry {
        MenuEntry(title: title, children: items)
    }
}
