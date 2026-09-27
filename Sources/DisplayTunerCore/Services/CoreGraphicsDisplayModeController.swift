import Foundation
import CoreGraphics

/// 基于 CoreGraphics 公共 API 的真实控制器。
///
/// 应用路径(规格 3.3):
/// 1. `CGDisplayCopyDisplayMode` 保存当前模式;
/// 2. `CGBeginDisplayConfiguration` + `CGConfigureDisplayWithDisplayMode` + `CGCompleteDisplayConfiguration`;
/// 3. 失败时回退 `CGDisplaySetDisplayMode`;
/// 4. 重新读取当前模式做验证,不一致立即恢复并抛 `verificationFailed`。
public final class CoreGraphicsDisplayModeController: DisplayModeController {

    private let logger: DTLogger

    public init(logger: DTLogger = DTLogger()) {
        self.logger = logger
    }

    // MARK: - DisplayModeController

    public func currentMode(for displayID: UInt32) -> DisplayModeInfo? {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
        return DisplayCatalog.modeInfo(from: Self.rawMode(mode), isCurrent: true)
    }

    public func apply(_ mode: DisplayModeInfo, to display: DisplayInfo) throws -> AppliedChange {
        let displayID = display.displayID

        guard let currentCG = CGDisplayCopyDisplayMode(displayID) else {
            throw ModeApplicationError.displayNotFound(displayID)
        }
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

    /// 在该显示器可用模式里找到与目标"显示效果"一致的 CGDisplayMode。
    private func findCGMode(
        displayID: UInt32,
        matching target: DisplayModeInfo
    ) -> CGDisplayMode? {
        guard let list = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode] else {
            return nil
        }
        return list.first { cgMode in
            let info = DisplayCatalog.modeInfo(from: Self.rawMode(cgMode), isCurrent: false)
            return info.modeKey == target.modeKey
        }
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
