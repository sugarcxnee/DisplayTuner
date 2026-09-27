import XCTest
@testable import DisplayTunerCore

/// 可编程虚拟屏工厂 Mock。
final class MockVirtualDisplayFactory: VirtualDisplayCreating {
    var availabilityResult: VirtualDisplayAvailability
    var createError: Error?
    private(set) var createdSpecs: [VirtualDisplaySpec] = []
    private(set) var destroyedIDs: [UInt32] = []
    private var nextID: UInt32 = 100

    init(available: Bool = true) {
        availabilityResult = VirtualDisplayAvailability(
            isAvailable: available,
            missingClasses: available ? [] : ["CGVirtualDisplay"]
        )
    }

    func availability() -> VirtualDisplayAvailability { availabilityResult }

    func create(spec: VirtualDisplaySpec) throws -> VirtualDisplayHandle {
        if let createError = createError { throw createError }
        createdSpecs.append(spec)
        nextID += 1
        return VirtualDisplayHandle(displayID: nextID, spec: spec, object: NSObject())
    }

    func destroy(_ handle: VirtualDisplayHandle) {
        destroyedIDs.append(handle.displayID)
        handle.retainedObject = nil
    }
}

/// 可编程镜像服务 Mock。
final class MockMirrorService: DisplayMirrorControlling {
    private(set) var mirrored: [(display: UInt32, master: UInt32)] = []
    private(set) var unmirrored: [UInt32] = []
    var mirrorError: Error?
    var unmirrorError: Error?
    /// mirror 调用后是否真的进入镜像组(模拟"配置成功但未生效")。
    var mirrorTakesEffect = true
    private var members: Set<UInt32> = []

    func mirror(display: UInt32, toMaster master: UInt32) throws {
        if let mirrorError = mirrorError { throw mirrorError }
        mirrored.append((display, master))
        if mirrorTakesEffect { members.insert(display) }
    }

    func unmirror(display: UInt32) throws {
        if let unmirrorError = unmirrorError { throw unmirrorError }
        unmirrored.append(display)
        members.remove(display)
    }

    func isInMirrorSet(_ display: UInt32) -> Bool { members.contains(display) }
}

final class VirtualDisplayOutcomeRecorder: VirtualDisplayCoordinatorDelegate {
    private(set) var outcomes: [VirtualDisplayOutcome] = []

    func virtualDisplayCoordinator(
        _ coordinator: VirtualDisplayCoordinator,
        didProduce outcome: VirtualDisplayOutcome
    ) {
        outcomes.append(outcome)
    }
}

final class VirtualDisplayCoordinatorTests: XCTestCase {

    private var factory: MockVirtualDisplayFactory!
    private var mirror: MockMirrorService!
    private var scheduler: MockCountdownScheduler!
    private var recorder: VirtualDisplayOutcomeRecorder!
    private var coordinator: VirtualDisplayCoordinator!
    private var sidecar: DisplayInfo!

    override func setUp() {
        super.setUp()
        factory = MockVirtualDisplayFactory()
        mirror = MockMirrorService()
        scheduler = MockCountdownScheduler()
        recorder = VirtualDisplayOutcomeRecorder()
        sidecar = DisplayCatalog.display(from: Fixtures.sidecarDisplay())
        coordinator = VirtualDisplayCoordinator(
            factory: factory,
            mirror: mirror,
            scheduler: scheduler,
            logger: DTLogger(sinks: [MemoryLogSink()])
        )
        coordinator.delegate = recorder
    }

    private var spec: VirtualDisplaySpec { VirtualDisplaySpec(width: 2360, height: 1640) }

    // MARK: - 启动

    func testStartCreatesMirrorsAndStartsCountdown() {
        coordinator.start(spec: spec, mirroring: sidecar)

        XCTAssertEqual(factory.createdSpecs.map(\.key), [spec.key])
        XCTAssertEqual(mirror.mirrored.map(\.display), [sidecar.displayID])
        XCTAssertEqual(mirror.mirrored.map(\.master), [101])
        XCTAssertEqual(scheduler.lastDelay, 10, "默认 10 秒倒计时")
        XCTAssertTrue(coordinator.hasPendingConfirmation)
        XCTAssertEqual(
            recorder.outcomes,
            [.started(spec: spec, virtualDisplayID: 101, sidecarStableID: sidecar.stableID)]
        )
    }

    func testConfirmKeepsSessionWithoutTeardown() {
        coordinator.start(spec: spec, mirroring: sidecar)
        coordinator.confirmActive()

        XCTAssertEqual(
            recorder.outcomes.last,
            .confirmed(spec: spec, sidecarStableID: sidecar.stableID)
        )
        XCTAssertFalse(coordinator.hasPendingConfirmation, "确认后倒计时结束")
        XCTAssertNotNil(coordinator.activeSession, "确认后会话保留,可手动停止")
        XCTAssertEqual(mirror.unmirrored.count, 0, "确认保留绝不解除镜像")
        XCTAssertEqual(factory.destroyedIDs.count, 0)
    }

    // MARK: - 停止与回滚

    func testTimeoutStopsAndTearsDown() {
        coordinator.start(spec: spec, mirroring: sidecar)
        scheduler.fireLast()

        XCTAssertEqual(mirror.unmirrored, [sidecar.displayID])
        XCTAssertEqual(factory.destroyedIDs.count, 1, "虚拟屏必须销毁")
        XCTAssertEqual(
            recorder.outcomes.last,
            .stopped(sidecarStableID: sidecar.stableID, reason: .timeout, teardownError: nil)
        )
        XCTAssertNil(coordinator.activeSession)
    }

    func testUserStopTearsDown() {
        coordinator.start(spec: spec, mirroring: sidecar)
        coordinator.stop(reason: .userRequested)

        XCTAssertEqual(
            recorder.outcomes.last,
            .stopped(sidecarStableID: sidecar.stableID, reason: .userRequested, teardownError: nil)
        )
        XCTAssertEqual(factory.destroyedIDs.count, 1)
    }

    func testStopIsIdempotent() {
        coordinator.start(spec: spec, mirroring: sidecar)
        scheduler.fireLast()
        coordinator.stop(reason: .userRequested)

        XCTAssertEqual(factory.destroyedIDs.count, 1, "重复停止只销毁一次")
        XCTAssertEqual(mirror.unmirrored.count, 1)
    }

    // MARK: - 启动失败路径

    func testFactoryFailureReportsFailedWithoutMirror() {
        factory.createError = VirtualDisplayError.classesUnavailable(["CGVirtualDisplay"])
        coordinator.start(spec: spec, mirroring: sidecar)

        XCTAssertEqual(
            recorder.outcomes.last,
            .failed(sidecarStableID: sidecar.stableID, error: "private virtual display classes unavailable: CGVirtualDisplay")
        )
        XCTAssertTrue(mirror.mirrored.isEmpty)
        XCTAssertNil(coordinator.activeSession)
    }

    func testMirrorFailureDestroysCreatedHandle() {
        mirror.mirrorError = MirrorError.failed("nope")
        coordinator.start(spec: spec, mirroring: sidecar)

        guard case .failed(_, let error) = recorder.outcomes.last ?? .failed(sidecarStableID: "", error: "") else {
            return XCTFail("应产生 failed")
        }
        XCTAssertTrue(error.contains("nope"))
        XCTAssertEqual(factory.destroyedIDs.count, 1, "创建成功但镜像失败 → 立即销毁,无残留")
    }

    func testMirrorNotTakingEffectTearsDown() {
        mirror.mirrorTakesEffect = false
        coordinator.start(spec: spec, mirroring: sidecar)

        guard case .failed = recorder.outcomes.last ?? .failed(sidecarStableID: "", error: "") else {
            return XCTFail("镜像未生效应报告 failed")
        }
        XCTAssertEqual(factory.destroyedIDs.count, 1)
    }

    // MARK: - 会话取代与断开

    func testNewStartSupersedesActiveSession() {
        coordinator.start(spec: spec, mirroring: sidecar)
        let second = VirtualDisplaySpec(width: 1770, height: 1230)
        coordinator.start(spec: second, mirroring: sidecar)

        XCTAssertEqual(recorder.outcomes.count, 3)
        XCTAssertEqual(
            recorder.outcomes[1],
            .stopped(sidecarStableID: sidecar.stableID, reason: .superseded, teardownError: nil)
        )
        XCTAssertEqual(factory.createdSpecs.count, 2)
        XCTAssertEqual(factory.destroyedIDs.count, 1)
    }

    func testUnmirrorFailureStillDestroysVirtualDisplay() {
        mirror.unmirrorError = MirrorError.failed("display gone")
        coordinator.start(spec: spec, mirroring: sidecar)
        scheduler.fireLast()

        guard case .stopped(_, .timeout, let teardownError) = recorder.outcomes.last ?? .stopped(sidecarStableID: "", reason: .timeout, teardownError: nil) else {
            return XCTFail("应为 stopped/timeout")
        }
        XCTAssertNotNil(teardownError, "解除镜像失败要如实上报")
        XCTAssertEqual(factory.destroyedIDs.count, 1, "虚拟屏无论如何都要销毁")
    }
}
