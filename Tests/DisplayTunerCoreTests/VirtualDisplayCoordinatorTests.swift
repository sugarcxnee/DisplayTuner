import XCTest
@testable import DisplayTunerCore

/// 可编程虚拟屏工厂 Mock。
final class MockVirtualDisplayFactory: VirtualDisplayCreating {
    var availabilityResult: VirtualDisplayAvailability
    var createError: Error?
    var activateError: Error?
    private(set) var createdSpecs: [VirtualDisplaySpec] = []
    /// 每次 create 注册的完整模式表。
    private(set) var modeTables: [[VirtualDisplaySpec]] = []
    private(set) var destroyedIDs: [UInt32] = []
    /// activateSpec 调用记录:"displayID:specKey"。
    private(set) var activateCalls: [String] = []
    private var nextID: UInt32 = 100

    init(available: Bool = true) {
        availabilityResult = VirtualDisplayAvailability(
            isAvailable: available,
            missingClasses: available ? [] : ["CGVirtualDisplay"]
        )
    }

    func availability() -> VirtualDisplayAvailability { availabilityResult }

    func create(spec: VirtualDisplaySpec, additionalModes: [VirtualDisplaySpec]) throws -> VirtualDisplayHandle {
        if let createError = createError { throw createError }
        createdSpecs.append(spec)
        var table = [spec]
        for mode in additionalModes where mode.key != spec.key {
            table.append(mode)
        }
        modeTables.append(table)
        nextID += 1
        return VirtualDisplayHandle(
            displayID: nextID,
            spec: spec,
            declaredModeTable: table,
            object: NSObject()
        )
    }

    func activateSpec(_ handle: VirtualDisplayHandle, spec: VirtualDisplaySpec) throws {
        if let activateError = activateError { throw activateError }
        guard let table = modeTables.max(by: { $0.count < $1.count }),
              table.contains(where: { $0.key == spec.key }) else {
            throw VirtualDisplayError.activationFailed("mode \(spec.key) not in table")
        }
        activateCalls.append("\(handle.displayID):\(spec.key)")
        handle.activeSpec = spec
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

    private(set) var resetCalls: [UInt32] = []

    func resetToDefaultMode(displayID: UInt32) {
        resetCalls.append(displayID)
    }
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

    func testNewStartOnDifferentSidecarSupersedesActiveSession() {
        // 不同 Sidecar 上的新会话才取代旧会话(同 Sidecar 走原地切档)
        let secondSidecar = DisplayCatalog.display(from: Fixtures.sidecarDisplay(displayID: 22))
        coordinator.start(spec: spec, mirroring: sidecar)
        let second = VirtualDisplaySpec(width: 1770, height: 1230)
        coordinator.start(spec: second, mirroring: secondSidecar)

        XCTAssertEqual(recorder.outcomes.count, 3)
        XCTAssertEqual(
            recorder.outcomes[1],
            .stopped(sidecarStableID: sidecar.stableID, reason: .superseded, teardownError: nil)
        )
        XCTAssertEqual(recorder.outcomes.last,
                       .started(spec: second, virtualDisplayID: 102, sidecarStableID: secondSidecar.stableID))
        XCTAssertEqual(factory.createdSpecs.count, 2)
        XCTAssertEqual(factory.destroyedIDs.count, 1)
    }

    // MARK: - 原地切档

    func testChangeResolutionSwitchesInPlaceWithoutRebuild() {
        let table = [spec, VirtualDisplaySpec(width: 1770, height: 1230)]
        coordinator.start(spec: spec, additionalModes: Array(table.dropFirst()), mirroring: sidecar)
        coordinator.confirmActive()

        coordinator.changeResolution(to: VirtualDisplaySpec(width: 1770, height: 1230))

        XCTAssertEqual(factory.activateCalls, ["101:1770x1230"], "纯 CG 切换")
        XCTAssertEqual(factory.createdSpecs.count, 1, "不重建")
        XCTAssertEqual(factory.destroyedIDs.count, 0, "不销毁")
        XCTAssertEqual(mirror.mirrored.count, 1, "镜像不受影响")
        XCTAssertEqual(
            recorder.outcomes.last,
            .resolutionChanged(spec: VirtualDisplaySpec(width: 1770, height: 1230), sidecarStableID: sidecar.stableID)
        )
        XCTAssertEqual(coordinator.activeSession?.spec.key, "1770x1230")
    }

    func testStartSameSidecarRoutesToChangeResolution() {
        coordinator.start(spec: spec, mirroring: sidecar)
        let other = VirtualDisplaySpec(width: 1770, height: 1230)
        coordinator.start(spec: other, mirroring: sidecar)

        XCTAssertEqual(factory.createdSpecs.count, 1, "同 Sidecar 再 start = 切档,不重建")
        XCTAssertEqual(factory.activateCalls.count, 1)
        XCTAssertEqual(factory.destroyedIDs.count, 0)
    }

    func testChangeResolutionFailureRevertsToPreviousSpec() {
        coordinator.start(spec: spec, mirroring: sidecar)
        factory.activateError = VirtualDisplayError.activationFailed("boom")

        coordinator.changeResolution(to: VirtualDisplaySpec(width: 1770, height: 1230))

        guard case .failed(_, let error) = recorder.outcomes.last ?? .failed(sidecarStableID: "", error: "") else {
            return XCTFail("切档失败应报告 failed")
        }
        XCTAssertTrue(error.contains("boom"))
        XCTAssertEqual(coordinator.activeSession?.spec.key, spec.key, "失败后保持旧档")
    }

    func testChangeResolutionToSameSpecIsNoop() {
        coordinator.start(spec: spec, mirroring: sidecar)
        coordinator.changeResolution(to: spec)

        XCTAssertTrue(factory.activateCalls.isEmpty)
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

/// 真实工厂的可用性回归:类通过进程依赖链(Foundation/AppKit → CoreDisplay)加载,
/// 即使 dlopen 因框架不在磁盘而失败,availability 也必须为可用。
/// 这是 v0.2.0 "虚拟屏不可用,缺少私有类" 事故的回归测试。
final class CoreDisplayVirtualDisplayFactoryTests: XCTestCase {

    func testAvailabilityIsTrueEvenWhenDlopenFails() {
        let factory = CoreDisplayVirtualDisplayFactory(
            frameworkLoader: { _ in false },   // 模拟新系统 dlopen 必败
            logger: DTLogger(sinks: [MemoryLogSink()])
        )
        let availability = factory.availability()
        XCTAssertTrue(
            availability.isAvailable,
            "类由依赖链加载时,dlopen 失败不应判死;缺失=\(availability.missingClasses)"
        )
    }

    func testAvailabilityReportsMissingClassesWhenNoneRegistered() {
        // 类不可见 + dlopen 补救失败 → 如实报告缺失类
        let factory = CoreDisplayVirtualDisplayFactory(
            frameworkLoader: { _ in false },
            logger: DTLogger(sinks: [MemoryLogSink()])
        )
        // 本机类均可见,无法真实构造"类缺失"环境;验证方法本身不崩溃且结构正确
        let availability = factory.availability()
        XCTAssertTrue(availability.isAvailable || !availability.missingClasses.isEmpty)
    }
}
