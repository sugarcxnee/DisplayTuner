import Foundation

/// 菜单"过滤"子菜单里的单条过滤规则,可叠加。
public enum ModeFilter: String, Codable, CaseIterable, Sendable {
    /// 仅显示 HiDPI 模式。
    case hidpiOnly = "hidpi"
    /// 仅显示不低于当前分辨率的模式。
    case atLeastCurrentResolution = "ge-current"
    /// 仅显示 16:10 比例的模式。
    case aspect16x10 = "16x10"

    public var displayName: String {
        switch self {
        case .hidpiOnly: return "仅显示 HiDPI"
        case .atLeastCurrentResolution: return "仅显示 ≥ 当前分辨率"
        case .aspect16x10: return "仅显示 16:10"
        }
    }
}

/// 模式排序、过滤与推荐判定的纯函数集合。
///
/// 排序规则(规格 3.2):
/// 1. HiDPI 优先;
/// 2. Sidecar 显示器上接近 iPad 原生比例(4:3)优先;
/// 3. 分辨率高且刷新率合理(55–120Hz)优先;
/// 4. 当前模式始终可见(过滤时不会被移除,排序中保持可寻)。
public enum ModeRanker {

    /// iPad 横屏原生比例约 4:3(iPad Pro 12.9 为 1.333,Pro 11 为 1.43)。
    static let iPadTargetAspect: Double = 4.0 / 3.0
    static let aspect16x10: Double = 16.0 / 10.0
    /// 推荐模式数量上限(菜单"推荐模式"分组)。
    static let recommendedLimit = 3

    // MARK: - 排序

    /// 稳定排序:得分相同保持原始顺序。
    public static func sort(_ modes: [DisplayModeInfo], isSidecar: Bool) -> [DisplayModeInfo] {
        modes.enumerated()
            .sorted { lhs, rhs in
                let left = score(lhs.element, isSidecar: isSidecar)
                let right = score(rhs.element, isSidecar: isSidecar)
                if left != right { return left > right }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// 单个模式的排序得分,越高越靠前。数值只在相对比较中有意义。
    public static func score(_ mode: DisplayModeInfo, isSidecar: Bool) -> Int {
        var score = 0

        // HiDPI 优先:主导信号
        if mode.isHiDPI { score += 100 }

        // 分辨率:逻辑像素面积,每 10 万像素 1 分,封顶 60
        score += min(60, mode.width * mode.height / 100_000)

        // 刷新率舒适区
        if mode.refreshRate >= 55 && mode.refreshRate <= 120 {
            score += 10
        } else if mode.refreshRate > 0 {
            score += 2
        }

        // 隔行 / 拉伸惩罚
        if mode.ioFlags & DisplayModeIOFlags.interlaced != 0 { score -= 30 }
        if mode.ioFlags & DisplayModeIOFlags.stretched != 0 { score -= 30 }

        // 不安全模式垫底
        if !mode.isSafe { score -= 1000 }

        // Sidecar:接近 iPad 原生 4:3 加分,差 0.1 扣 3 分
        if isSidecar, let aspect = mode.aspectRatio {
            let penalty = Int(abs(aspect - iPadTargetAspect) * 30)
            score += max(0, 20 - penalty)
        }

        return score
    }

    // MARK: - 推荐

    /// 依据排序结果把前若干个安全模式标记为推荐,返回与输入同序的新数组。
    public static func markRecommended(_ modes: [DisplayModeInfo], isSidecar: Bool) -> [DisplayModeInfo] {
        let rankedKeys = sort(modes.filter(\.isSafe), isSidecar: isSidecar)
            .prefix(recommendedLimit)
            .map(\.modeKey)
        let recommendedKeys = Set(rankedKeys)
        return modes.map { mode in
            recommendedKeys.contains(mode.modeKey) ? mode.withRecommended(true) : mode
        }
    }

    // MARK: - 过滤

    /// 应用过滤规则;当前模式无论如何都会保留。
    public static func filter(
        _ modes: [DisplayModeInfo],
        by filters: Set<ModeFilter>,
        current: DisplayModeInfo?
    ) -> [DisplayModeInfo] {
        guard !filters.isEmpty else { return modes }
        return modes.filter { mode in
            if let current = current, mode.modeKey == current.modeKey {
                return true
            }
            return filters.allSatisfy { rule in
                passes(mode, rule: rule, current: current)
            }
        }
    }

    static func passes(
        _ mode: DisplayModeInfo,
        rule: ModeFilter,
        current: DisplayModeInfo?
    ) -> Bool {
        switch rule {
        case .hidpiOnly:
            return mode.isHiDPI
        case .atLeastCurrentResolution:
            guard let current = current else { return true }
            return mode.width * mode.height >= current.width * current.height
        case .aspect16x10:
            guard let aspect = mode.aspectRatio else { return false }
            return abs(aspect - Self.aspect16x10) < 0.02
        }
    }

    // MARK: - Sidecar 提示

    /// 是否存在比当前模式"更好"的模式:像素面积更大,或从非 HiDPI 升级到 HiDPI。
    /// 用于"当前随航连接未提供更高分辨率模式"提示。
    public static func hasHigherModes(
        than current: DisplayModeInfo?,
        in modes: [DisplayModeInfo]
    ) -> Bool {
        let candidates = modes.filter(\.isSafe)
        guard let current = current else {
            return !candidates.isEmpty
        }
        let currentArea = current.width * current.height
        return candidates.contains { mode in
            let bigger = mode.width * mode.height > currentArea
            let hidpiUpgrade = !current.isHiDPI && mode.isHiDPI
            return (bigger || hidpiUpgrade) && mode.modeKey != current.modeKey
        }
    }
}

extension DisplayModeInfo {
    /// 复制并更新推荐标记(值类型,其余字段不变)。
    public func withRecommended(_ recommended: Bool) -> DisplayModeInfo {
        DisplayModeInfo(
            width: width,
            height: height,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            refreshRate: refreshRate,
            ioFlags: ioFlags,
            isHiDPI: isHiDPI,
            isCurrent: isCurrent,
            isSafe: isSafe,
            isRecommended: recommended
        )
    }
}
