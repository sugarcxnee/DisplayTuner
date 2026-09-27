import AppKit
import DisplayTunerCore

/// 安全倒计时确认框(规格 2/7):应用新模式后弹出,10 秒无操作自动还原。
/// 使用系统 NSAlert —— 不是自定义页面;倒计时文字随秒刷新。
///
/// 双保险:本类的 NSTimer(common modes)与协调器内部的 Dispatch 倒计时
/// 都会触发回滚,两者幂等,谁先到谁生效。
final class SafetyAlertPresenter: NSObject {

    private let coordinator: ModeChangeCoordinator
    private let displaysProvider: () -> [DisplayInfo]
    private let logger: DTLogger

    private var countdownTimer: Timer?
    private var isShowingAlert = false

    init(
        coordinator: ModeChangeCoordinator,
        displaysProvider: @escaping () -> [DisplayInfo],
        logger: DTLogger
    ) {
        self.coordinator = coordinator
        self.displaysProvider = displaysProvider
        self.logger = logger
    }

    /// 订阅协调器结果(由 AppDelegate 桥接)。
    func handle(_ outcome: ModeChangeOutcome) {
        switch outcome {
        case .applied(let stableID, let modeKey):
            showConfirmation(stableID: stableID, modeKey: modeKey)
        case .confirmed:
            break
        case .reverted, .failed:
            // 倒计时超时的回滚会走到这里:如果确认框还在,收起它
            if isShowingAlert {
                NSApp.stopModal(withCode: .abort)
            }
        }
    }

    // MARK: - 确认框

    private func showConfirmation(stableID: String, modeKey: String) {
        // 已有确认框显示(例如自动恢复连续触发)时不叠加:
        // 后来的变更会被协调器作为新 pending 处理,旧的已 revert(superseded)。
        guard !isShowingAlert else { return }

        let change = coordinator.pendingChange
        let display = displaysProvider().first { $0.stableID == stableID }
        let isMain = display?.isMain ?? false

        let alert = NSAlert()
        alert.messageText = "已切换显示模式"
        var info = "新模式:\(change?.appliedMode.title ?? modeKey)"
        if let previous = change?.previousMode {
            info += "\n原模式:\(previous.title)"
        }
        info += "\n\n若屏幕异常或想放弃修改,无需操作,倒计时结束后自动还原。"
        if isMain {
            info += "\n\n⚠️ 这是对主显示器的修改,可能短暂影响所有窗口布局。"
        }
        alert.informativeText = info
        alert.alertStyle = isMain ? .warning : .informational
        alert.addButton(withTitle: "保留更改")
        alert.addButton(withTitle: "还原")

        NSApp.activate(ignoringOtherApps: true)

        let totalSeconds = Int(coordinator.confirmInterval)
        var remaining = totalSeconds
        updateCountdown(in: alert, remaining: remaining, total: totalSeconds)

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            remaining -= 1
            if remaining <= 0 {
                timer.invalidate()
                self.countdownTimer = nil
                self.coordinator.revertPending(reason: .timeout)
            } else {
                self.updateCountdown(in: alert, remaining: remaining, total: totalSeconds)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer

        logger.debug("showing safety confirmation for \(modeKey)", context: "SafetyAlert")
        isShowingAlert = true
        let response = alert.runModal()
        isShowingAlert = false
        countdownTimer?.invalidate()
        countdownTimer = nil

        switch response {
        case .alertFirstButtonReturn:
            coordinator.confirmPending()
        case .alertSecondButtonReturn:
            coordinator.revertPending(reason: .userRequested)
        default:
            // 倒计时到点路径已经回滚并 stopModal;确认/还原按钮未按下时保持现状
            break
        }
    }

    private func updateCountdown(in alert: NSAlert, remaining: Int, total: Int) {
        // 把倒计时行维护在 informativeText 末尾,每秒重写
        var lines = alert.informativeText.components(separatedBy: "\n")
        if let last = lines.last, last.hasPrefix("⏱") {
            lines.removeLast()
        }
        lines.append("⏱ \(remaining) 秒后自动还原(共 \(total) 秒)")
        alert.informativeText = lines.joined(separator: "\n")
    }
}
