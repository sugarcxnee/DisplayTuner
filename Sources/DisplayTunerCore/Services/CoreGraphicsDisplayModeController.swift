import Foundation
import CoreGraphics

/// 基于 CoreGraphics 公共 API 的真实控制器。
///
/// 应用路径(规格 3.3):
/// 1. `CGDisplayCopyDisplayMode` 保存当前模式;
/// 2. `CGBeginDisplayConfiguration` + `CGConfigureDisplayWithDisplayMode` + `CGCompleteDisplayConfiguration`;
/// 3. 失败时回退 `CGDisplaySetDisplayMode`;
/// 4. 重新读取当前模式做验证,不一致立即恢复并抛 `verificationFailed`。
///
/// Sidecar 影子 HiDPI(2026-09-28 真机定性):清晰态的 2x 模式对象由系统内部
/// 合成、从不进枚举,但对象引用可直接 configure。目标规范化因此在枚举变体
/// 之外增加影子缓存升级;`findCGMode` 枚举未命中时回退影子对象。
public final class CoreGraphicsDisplayModeController: DisplayModeController {

    private let logger: DTLogger
    private let hidpiCache: HiDPIModeCache

    public init(logger: DTLogger = DTLogger(), hidpiCache: HiDPIModeCache = HiDPIModeCache()) {
        self.logger = logger
        self.hidpiCache = hidpiCache
    }

    // MARK: - DisplayModeController

    public func currentMode(for displayID: UInt32) -> DisplayModeInfo? {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
        hidpiCache.captureIfHiDPI(mode, displayID: displayID)
        return DisplayCatalog.modeInfo(from: Self.rawMode(mode), isCurrent: true)
    }

    public func apply(_ mode: DisplayModeInfo, to display: DisplayInfo) throws -> AppliedChange {
        let displayID = display.displayID
        // 目标规范化:同尺寸存在 HiDPI 变体时一律升级到它 —— 1x 渲染会被
        // 拉伸到面板导致字体发虚(2026-09-28 真机"切档变糊"根因),任何
        // 1x 目标(旧配置残留的 key 等)都不应被忠实执行。
        // 变体来源两层:枚举条目 → 影子缓存(Sidecar 的 2x 对象不进枚举)。
        let mode = highResolutionVariant(of: mode, in: display.modes)
            ?? shadowHiDPIVariant(of: mode, displayID: displayID)
            ?? mode

        guard let currentCG = CGDisplayCopyDisplayMode(displayID) else {
            throw ModeApplicationError.displayNotFound(displayID)
        }
        hidpiCache.captureIfHiDPI(currentCG, displayID: displayID)
        let previous = DisplayCatalog.modeInfo(from: Self.rawMode(currentCG), isCurrent: true)

        guard let targetCG = findCGMode(displayID: displayID, matching: mode) else {
            throw ModeApplicationError.modeNotFound(mode.modeKey)
        }

        do {
            try configure(displayID: displayID, to: targetCG)
        } catch {
            // 配置失败:直接走兼容路径单独重试一次,再不行抛出
            let fallbackError = CGDisplaySetDisplayMode(displayID, targetCG, nil)
            guard fallbackError == .success else {
                invalidateShadowIfNeeded(mode, displayID: displayID)
                throw ModeApplicationError.applyFailed("\(error); fallback CGDisplaySetDisplayMode: \(fallbackError)")
            }
        }

        // 验证
        guard let actual = CGDisplayCopyDisplayMode(displayID) else {
            try? restore(previousCG: currentCG, displayID: displayID)
            throw ModeApplicationError.verificationFailed(expected: mode.modeKey, actual: "<none>")
        }
        let actualInfo = DisplayCatalog.modeInfo(from: Self.rawMode(actual), isCurrent: true)
        guard actualInfo.modeKey == mode.modeKey else {
            let restoreError = restore(previousCG: currentCG, displayID: displayID)
            if let restoreError = restoreError {
                logger.error(
                    "auto-restore after verification failure also failed: \(restoreError)",
                    context: "ModeController"
                )
            }
            invalidateShadowIfNeeded(mode, displayID: displayID)
            throw ModeApplicationError.verificationFailed(expected: mode.modeKey, actual: actualInfo.modeKey)
        }

        logger.info(
            "applied \(mode.modeKey) to \(display.logDescriptor) (previous \(previous.modeKey))",
            context: "ModeController"
        )
        return AppliedChange(
            displayStableID: display.stableID,
            displayID: displayID,
            displayLogDescriptor: display.logDescriptor,
            previousMode: previous,
            appliedMode: mode,
            timestamp: Date()
        )
    }

    public func rollback(_ change: AppliedChange) throws {
        guard let targetCG = findCGMode(displayID: change.displayID, matching: change.previousMode) else {
            throw ModeApplicationError.rollbackFailed(
                "previous mode \(change.previousMode.modeKey) no longer available"
            )
        }
        do {
            try configure(displayID: change.displayID, to: targetCG)
        } catch {
            let fallbackError = CGDisplaySetDisplayMode(change.displayID, targetCG, nil)
            guard fallbackError == .success else {
                throw ModeApplicationError.rollbackFailed("\(error); fallback: \(fallbackError)")
            }
        }
        logger.info(
            "rolled back \(change.displayLogDescriptor) to \(change.previousMode.modeKey)",
            context: "ModeController"
        )
    }

    // MARK: - 内部

    private static func rawMode(_ mode: CGDisplayMode) -> RawModeRecord {
        RawModeRecord(
            width: Int(mode.width),
            height: Int(mode.height),
            pixelWidth: Int(mode.pixelWidth),
            pixelHeight: Int(mode.pixelHeight),
            refreshRate: mode.refreshRate,
            ioFlags: mode.ioFlags
        )
    }

    /// 在该显示器可用模式里找到与目标"显示效果"一致的 HiDPI 变体;
    /// 不存在则返回 nil(调用方再试影子缓存)。
    private func highResolutionVariant(
        of mode: DisplayModeInfo,
        in modes: [DisplayModeInfo]
    ) -> DisplayModeInfo? {
        guard !mode.isHiDPI else { return nil }
        guard let hidpi = modes.first(where: {
            $0.isHiDPI && $0.width == mode.width && $0.height == mode.height
                && $0.refreshRate == mode.refreshRate
        }) else { return nil }
        logger.info(
            "upgrading target \(mode.modeKey) to HiDPI variant \(hidpi.modeKey)",
            context: "ModeController"
        )
        return hidpi
    }

    /// 影子 HiDPI 升级:Sidecar 的 2x 对象不进枚举,但在曾处于清晰态时
    /// 已被捕获缓存。命中则目标升级为该 2x 档;缓存未命中返回 nil。
    private func shadowHiDPIVariant(of mode: DisplayModeInfo, displayID: UInt32) -> DisplayModeInfo? {
        guard !mode.isHiDPI,
              let cached = hidpiCache.hidpiMode(
                  displayID: displayID,
                  width: mode.width,
                  height: mode.height,
                  refreshRate: mode.refreshRate
              )
        else { return nil }
        let upgraded = DisplayCatalog.modeInfo(from: Self.rawMode(cached), isCurrent: false)
        logger.info(
            "upgrading target \(mode.modeKey) to shadow HiDPI variant \(upgraded.modeKey) (unlisted 2x object)",
            context: "ModeController"
        )
        return upgraded
    }

    /// 影子对象配置失败或验证未落在 2x 时失效该缓存条目,防止反复使用陈旧对象
    /// (例如边栏几何互换后旧家族对象可能已不可用)。
    private func invalidateShadowIfNeeded(_ mode: DisplayModeInfo, displayID: UInt32) {
        guard mode.isHiDPI else { return }
        hidpiCache.invalidate(
            displayID: displayID,
            width: mode.width,
            height: mode.height,
            refreshRate: mode.refreshRate
        )
        logger.info(
            "invalidated shadow HiDPI entry \(mode.modeKey) on display \(displayID)",
            context: "ModeController"
        )
    }

    private func findCGMode(
        displayID: UInt32,
        matching target: DisplayModeInfo
    ) -> CGDisplayMode? {
        guard let list = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode] else {
            return nil
        }
        if let found = list.first(where: { cgMode in
            let info = DisplayCatalog.modeInfo(from: Self.rawMode(cgMode), isCurrent: false)
            return info.modeKey == target.modeKey
        }) {
            return found
        }
        // Sidecar 影子 HiDPI:2x 对象不进枚举但缓存对象可配置(2026-09-28 实测)
        return hidpiCache.hidpiMode(displayID: displayID, matching: target)
    }

    /// 首选配置路径:begin/configure/complete。
    private func configure(displayID: UInt32, to cgMode: CGDisplayMode) throws {
        var config: CGDisplayConfigRef?
        let beginStatus = CGBeginDisplayConfiguration(&config)
        guard beginStatus == .success, let config = config else {
            throw ModeApplicationError.applyFailed("CGBeginDisplayConfiguration: \(beginStatus)")
        }

        let configureStatus = CGConfigureDisplayWithDisplayMode(config, displayID, cgMode, nil)
        guard configureStatus == .success else {
            CGCancelDisplayConfiguration(config)
            throw ModeApplicationError.applyFailed("CGConfigureDisplayWithDisplayMode: \(configureStatus)")
        }

        let completeStatus = CGCompleteDisplayConfiguration(config, .permanently)
        guard completeStatus == .success else {
            throw ModeApplicationError.applyFailed("CGCompleteDisplayConfiguration: \(completeStatus)")
        }
    }

    /// 验证失败后的自动恢复;返回错误供调用方记日志。
    private func restore(previousCG: CGDisplayMode, displayID: UInt32) -> ModeApplicationError? {
        do {
            try configure(displayID: displayID, to: previousCG)
            return nil
        } catch {
            let fallbackError = CGDisplaySetDisplayMode(displayID, previousCG, nil)
            return fallbackError == .success
                ? nil
                : ModeApplicationError.applyFailed("auto-restore failed: \(fallbackError)")
        }
    }
}
