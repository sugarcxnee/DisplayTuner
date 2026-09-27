import XCTest
@testable import DisplayTunerCore

final class ModeChangeCoordinatorTests: XCTestCase {

    private var controller: MockDisplayModeController!
    private var scheduler: MockCountdownScheduler!
    private var recorder: OutcomeRecorder!
    private var coordinator: ModeChangeCoordinator!
    private var display: DisplayInfo!

    override func setUp() {
        super.setUp()
        controller = MockDisplayModeController()
        scheduler = MockCountdownScheduler()
        recorder = OutcomeRecorder()
        display = DisplayCatalog.display(from: Fixtures.externalDisplay())
        coordinator = ModeChangeCoordinator(
            controller: controller,
            scheduler: scheduler,
            logger: DTLogger(sinks: [MemoryLogSink()]),
            confirmInterval: 10
        )
        coordinator.delegate = recorder
        // 预置当前模式,模拟真实控制器状态
        controller.currentModes[display.displayID] = display.currentMode
    }

    private var higherMode: DisplayModeInfo {
        display.modes.first { !$0.isCurrent }!
    }

    // MARK: - 成功路径

    func testRequestSuccessStartsCountdownAndNotifiesApplied() {
        coordinator.request(mode: higherMode, on: display)

        XCTAssertTrue(coordinator.hasPendingConfirmation)
        XCTAssertEqual(recorder.outcomes, [.applied(display: display.stableID, modeKey: higherMode.modeKey)])
        XCTAssertEqual(scheduler.lastDelay, 10, "默认 10 秒安全倒计时")
        XCTAssertEqual(controller.applyCalls.count, 1)
    }

    func testConfirmKeepsModeWithoutRollback() {
        coordinator.request(mode: higherMode, on: display)
        coordinator.confirmPending()

        XCTAssertEqual(
            recorder.outcomes.last,
            .confirmed(display: display.stableID, modeKey: higherMode.modeKey)
        )
        XCTAssertFalse(coordinator.hasPendingConfirmation)
        XCTAssertEqual(controller.rollbackCalls.count, 0, "确认保留后绝不能回滚")
        XCTAssertEqual(controller.currentModes[display.displayID]?.modeKey, higherMode.modeKey)
    }

    // MARK: - 超时回滚

    func testTimeoutRevertsAutomatically() {
        coordinator.request(mode: higherMode, on: display)
        scheduler.fireLast()

        XCTAssertEqual(
            recorder.outcomes.last,
            .reverted(display: display.stableID, reason: .timeout, rollbackError: nil)
        )
        XCTAssertEqual(controller.rollbackCalls, [display.stableID])
        XCTAssertEqual(controller.currentModes[display.displayID]?.modeKey, display.currentMode?.modeKey,
                       "回滚后应恢复原模式")
    }

    func testUserRequestedRevertRestoresPreviousMode() {
        coordinator.request(mode: higherMode, on: display)
        coordinator.revertPending(reason: .userRequested)

        XCTAssertEqual(
            recorder.outcomes.last,
            .reverted(display: display.stableID, reason: .userRequested, rollbackError: nil)
        )
        XCTAssertEqual(controller.rollbackCalls.count, 1)
    }

    // MARK: - 应用失败

    func testApplyFailureReportsFailedAndSchedulesNoCountdown() {
        controller.applyError = ModeApplicationError.applyFailed("mock failure")

        coordinator.request(mode: higherMode, on: display)

        guard case .failed(let displayID, let error) = recorder.outcomes.last ?? .applied(display: "", modeKey: "") else {
            return XCTFail("应产生 failed 结果")
        }
        XCTAssertEqual(displayID, display.stableID)
        XCTAssertTrue(error.contains("mock failure"))
        XCTAssertFalse(coordinator.hasPendingConfirmation)
        XCTAssertTrue(scheduler.entries.isEmpty, "应用失败不应启动倒计时")
        XCTAssertEqual(controller.rollbackCalls.count, 0, "apply 抛错即代表控制器已恢复,无需再回滚")
    }

    // MARK: - 幂等

    func testRevertIsIdempotentWhenTimeoutFiresTwice() {
        coordinator.request(mode: higherMode, on: display)
        scheduler.fireLast()
        scheduler.fireLast()   // 第二次触发同一倒计时

        XCTAssertEqual(controller.rollbackCalls.count, 1, "重复超时只回滚一次")
    }

    func testConfirmWithoutPendingIsNoop() {
        coordinator.confirmPending()
        XCTAssertTrue(recorder.outcomes.isEmpty)
    }

    func testRevertWithoutPendingIsNoop() {
        coordinator.revertPending(reason: .timeout)
        XCTAssertTrue(recorder.outcomes.isEmpty)
        XCTAssertTrue(controller.rollbackCalls.isEmpty)
    }

    func testConfirmAfterTimeoutDoesNothing() {
        coordinator.request(mode: higherMode, on: display)
        scheduler.fireLast()
        coordinator.confirmPending()

        XCTAssertEqual(
            recorder.outcomes.last,
            .reverted(display: display.stableID, reason: .timeout, rollbackError: nil)
        )
    }

    // MARK: - 取代与回滚失败

    func testNewRequestSupersedesPendingChange() {
        let first = display.modes[0]
        coordinator.request(mode: first, on: display)

        let second = display.modes[1]
        coordinator.request(mode: second, on: display)

        XCTAssertEqual(recorder.outcomes.count, 3)
        XCTAssertEqual(recorder.outcomes[0], .applied(display: display.stableID, modeKey: first.modeKey))
        XCTAssertEqual(
            recorder.outcomes[1],
            .reverted(display: display.stableID, reason: .superseded, rollbackError: nil)
        )
        XCTAssertEqual(recorder.outcomes[2], .applied(display: display.stableID, modeKey: second.modeKey))
        XCTAssertEqual(controller.rollbackCalls.count, 1, "旧待确认项被回滚一次")
    }

    func testRollbackFailureStillReportsRevertedWithError() {
        controller.rollbackError = ModeApplicationError.rollbackFailed("display gone")
        coordinator.request(mode: higherMode, on: display)
        scheduler.fireLast()

        XCTAssertEqual(
            recorder.outcomes.last,
            .reverted(display: display.stableID, reason: .timeout, rollbackError: "rollback failed: display gone")
        )
        XCTAssertFalse(coordinator.hasPendingConfirmation, "回滚失败也必须结束 pending,不能悬挂")
    }

    // MARK: - 倒计时区间

    func testConfirmIntervalIsClampedToAtLeastOneSecond() {
        let aggressive = ModeChangeCoordinator(
            controller: controller,
            scheduler: scheduler,
            logger: DTLogger(sinks: [MemoryLogSink()]),
            confirmInterval: 0
        )
        XCTAssertEqual(aggressive.confirmInterval, 1, "不允许 0 秒倒计时")
    }

    func testCancelledCountdownNeverFires() {
        coordinator.request(mode: higherMode, on: display)
        coordinator.confirmPending()
        // 确认后倒计时应已取消:即使 handler 泄漏触发也不回滚
        let id = scheduler.entries[0].id
        scheduler.fire(id: id)

        XCTAssertEqual(controller.rollbackCalls.count, 0)
    }
}
