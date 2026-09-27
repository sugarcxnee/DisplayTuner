import Foundation
@testable import DisplayTunerCore

/// 可编程的显示器模式控制器 Mock:记录调用、可注入失败。
final class MockDisplayModeController: DisplayModeController {

    /// 每个 displayID 当前生效的模式。
    var currentModes: [UInt32: DisplayModeInfo] = [:]
    /// 非空时 apply 抛出该错误。
    var applyError: Error?
    /// 非空时 rollback 抛出该错误。
    var rollbackError: Error?

    private(set) var applyCalls: [String] = []
    private(set) var rollbackCalls: [String] = []

    func currentMode(for displayID: UInt32) -> DisplayModeInfo? {
        currentModes[displayID]
    }

    func apply(_ mode: DisplayModeInfo, to display: DisplayInfo) throws -> AppliedChange {
        applyCalls.append("\(mode.modeKey)@\(display.displayID)")
        if let applyError = applyError { throw applyError }
        let previous = currentModes[display.displayID] ?? mode
        currentModes[display.displayID] = mode
        return AppliedChange(
            displayStableID: display.stableID,
            displayID: display.displayID,
            displayLogDescriptor: display.logDescriptor,
            previousMode: previous,
            appliedMode: mode,
            timestamp: Date()
        )
    }

    func rollback(_ change: AppliedChange) throws {
        rollbackCalls.append(change.displayStableID)
        if let rollbackError = rollbackError { throw rollbackError }
        currentModes[change.displayID] = change.previousMode
    }
}

/// 同步可控的倒计时 Mock:测试里手动 fire 触发超时。
final class MockCountdownScheduler: CountdownScheduler {

    struct Entry {
        let id: Int
        let delay: TimeInterval
        var handler: (() -> Void)?
    }

    private(set) var entries: [Entry] = []
    private var nextID = 0

    func schedule(after delay: TimeInterval, handler: @escaping () -> Void) -> Cancellable {
        let id = nextID
        nextID += 1
        entries.append(Entry(id: id, delay: delay, handler: handler))
        return MockCancellable { [weak self] in
            self?.invalidate(id: id)
        }
    }

    var lastDelay: TimeInterval? { entries.last?.delay }

    func fire(id: Int) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let handler = entries[index].handler
        entries[index].handler = nil
        handler?()
    }

    func fireLast() {
        guard let id = entries.last?.id else { return }
        fire(id: id)
    }

    func handlerAlive(id: Int) -> Bool {
        entries.first(where: { $0.id == id })?.handler != nil
    }

    private func invalidate(id: Int) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].handler = nil
    }
}

final class MockCancellable: Cancellable {
    private(set) var cancelled = false
    private let action: () -> Void

    init(_ action: @escaping () -> Void = {}) {
        self.action = action
    }

    func cancel() {
        cancelled = true
        action()
    }
}

/// 收集协调器结果的 delegate 替身。
final class OutcomeRecorder: ModeChangeCoordinatorDelegate {
    private(set) var outcomes: [ModeChangeOutcome] = []

    func coordinator(_ coordinator: ModeChangeCoordinator, didProduce outcome: ModeChangeOutcome) {
        outcomes.append(outcome)
    }
}
