import AppKit
import DisplayTunerCore

/// 安全倒计时确认框(规格 2/7):应用新模式/开启虚拟屏后弹出,10 秒无操作自动还原。
/// 使用系统 NSAlert —— 不是自定义页面;倒计时文字随秒刷新。
///
/// 双保险:本类的 NSTimer(common modes)与协调器内部的 Dispatch 倒计时
/// 都会触发回滚,两者幂等,谁先到谁生效。
final class SafetyAlertPresenter: NSObject {

    private let coordinator: ModeChangeCoordinator
    private let virtualCoordinator: VirtualDisplayCoordinator
    private let displaysProvider: () -> [DisplayInfo]
    private let logger: DTLogger

    private var countdownTimer: Timer?
    private var isShowingAlert = false

    init(
        coordinator: ModeChangeCoordinator,
        virtualCoordinator: VirtualDisplayCoordinator,
        displaysProvider: @escaping () -> [DisplayInfo],
        logger: DTLogger
    ) {
        self.coordinator = coordinator
        self.virtualCoordinator = virtualCoordinator
        self.displaysProvider = displaysProvider
        self.logger = logger
    }

    // MARK: - 模式切换确认

    /// 订阅协调器结果(由 AppDelegate 桥接)。
    func handle(_ outcome: ModeChangeOutcome) {
        switch outcome {
        case .applied(let stableID, let modeKey):
            showModeConfirmation(stableID: stableID, modeKey: modeKey)
        case .confirmed:
            break
        case .reverted, .failed:
            // 倒计时超时的回滚会走到这里:如果确认框还在,收起它
            if isShowingAlert {
                NSApp.stopModal(withCode: .abort)
            }
        }
    }

    // MARK: - 虚拟屏确认

    /// 订阅虚拟屏会话结果(由 AppDelegate 桥接)。
    func handleVirtual(_ outcome: VirtualDisplayOutcome) {
        switch outcome {
        case .started(let spec, _, let sidecarStableID):
            showVirtualConfirmation(spec: spec, sidecarStableID: sidecarStableID)
        case .confirmed:
            break
        case .resolutionChanged:
            // 原地切档即时生效、失败自动回退,无需确认框
            break
        case .stopped, .failed:
            if isShowingAlert {
                NSApp.stopModal(withCode: .abort)
            }
        }
    }

    // MARK: - 确认框实现

    private func showModeConfirmation(stableID: String, modeKey: String) {
        guard !isShowingAlert else { return }
        let change = coordinator.pendingChange
        let display = displaysProvider().first { $0.stableID == stableID }
        let isMain = display?.isMain ?? false

        var info = "新模式:\(change?.appliedMode.title ?? modeKey)"
        if let previous = change?.previousMode {
            info += "\n原模式:\(previous.title)"
        }
        info += "\n\n若屏幕异常或想放弃修改,无需操作,倒计时结束后自动还原。"
        if isMain {
            info += "\n\n⚠️ 这是对主显示器的修改,可能短暂影响所有窗口布局。"
        }

        runCountdownAlert(
            message: "已切换显示模式",
            info: info,
            isWarning: isMain,
            confirmTitle: "保留更改",
            revertTitle: "还原",
            onConfirm: { [weak self] in self?.coordinator.confirmPending() },
            onRevert: { [weak self] in self?.coordinator.revertPending(reason: .userRequested) },
            onTimeout: { [weak self] in self?.coordinator.revertPending(reason: .timeout) }
        )
    }

    private func showVirtualConfirmation(spec: VirtualDisplaySpec, sidecarStableID: String) {
        guard !isShowingAlert else { return }
        let display = displaysProvider().first { $0.stableID == sidecarStableID }

        var info = "虚拟屏:\(spec.title)(工作区已扩大)\n镜像到:\(display?.menuTitle ?? "Sidecar")"
        info += "\n\niPad 显示的是虚拟屏的镜像,界面元素会变小、工作区变大。"
        info += "\n倒计时内不确认将自动停止并恢复原状。"

        runCountdownAlert(
            message: "已开启虚拟屏增强(实验)",
            info: info,
            isWarning: false,
            confirmTitle: "保留",
            revertTitle: "停止虚拟屏",
            onConfirm: { [weak self] in self?.virtualCoordinator.confirmActive() },
            onRevert: { [weak self] in self?.virtualCoordinator.stop(reason: .userRequested) },
            onTimeout: { [weak self] in self?.virtualCoordinator.stop(reason: .timeout) }
        )
    }

    /// 通用倒计时确认框:双按钮 + 每秒刷新倒计时;超时执行 onTimeout 并收起。
    private func runCountdownAlert(
        message: String,
        info: String,
        isWarning: Bool,
        confirmTitle: String,
        revertTitle: String,
        onConfirm: @escaping () -> Void,
        onRevert: @escaping () -> Void,
        onTimeout: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.alertStyle = isWarning ? .warning : .informational
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: revertTitle)

        NSApp.activate(ignoringOtherApps: true)

        let totalSeconds = 10
        var remaining = totalSeconds
        updateCountdown(in: alert, remaining: remaining, total: totalSeconds)

        let timer = Timer(timeInterval: 1, repeats: true) { timer in
            remaining -= 1
            if remaining <= 0 {
                timer.invalidate()
                onTimeout()
            } else {
                self.updateCountdown(in: alert, remaining: remaining, total: totalSeconds)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer

        logger.debug("showing safety confirmation: \(message)", context: "SafetyAlert")
        isShowingAlert = true
        let response = alert.runModal()
        isShowingAlert = false
        countdownTimer?.invalidate()
        countdownTimer = nil

        switch response {
        case .alertFirstButtonReturn:
            onConfirm()
        case .alertSecondButtonReturn:
            onRevert()
        default:
            // 超时路径已经回滚并 stopModal;按钮未按下时保持现状
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
