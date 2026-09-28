import XCTest
@testable import DisplayTunerCore

/// SeedEngine 单元测试:流程顺序、前置条件、失败清理全部走 Mock,零真实系统调用。
final class SeedEngineTests: XCTestCase {

    private var factory: MockSeedFactory!
    private var mirror: MockSeedMirror!
    private var engine: SeedEngine!

    /// 原始 7 档形态:单 1180×820(无锚点变体、无高档)。
    private var vanillaSidecar: DisplayInfo {
        DisplayCatalog.display(from: Fixtures.sidecarDisplay(modes: [
            Fixtures.mode(1180, 820),
        ]))
    }

    override func setUp() {
        super.setUp()
        factory = MockSeedFactory()
        mirror = MockSeedMirror()
        engine = SeedEngine(
            factory: factory,
            mirror: mirror,
            logger: DTLogger(sinks: [MemoryLogSink()]),
            sleep: { _ in }
        )
    }

    // MARK: - 解锁判定

    func testHasHighResolutionModesFalseForVanillaSidecar() {
        XCTAssertFalse(SeedEngine.hasHighResolutionModes(vanillaSidecar))
    }

    func testHasHighResolutionModesTrueWithAnchorAndHighMode() {
        let unlocked = DisplayCatalog.display(from: Fixtures.sidecarDisplay(modes: [
            Fixtures.mode(1180, 820),
            Fixtures.mode(2360, 1640),
            Fixtures.mode(1180, 820, ioFlags: DisplayModeIOFlags.valid),   // 污染变体 → 锚点
        ]))
        XCTAssertTrue(SeedEngine.hasHighResolutionModes(unlocked))
    }

    // MARK: - 基准与目标档

    func testTargetSpecIsExactDouble() {
        // 精确 ×2:边栏显示态锚点 1116×2 = 2232,任何取整都会偏离能力边界
        let sidebar = SeedEngine.targetSpec(base: DisplaySize(width: 1116, height: 820))
        XCTAssertEqual(sidebar.key, "2232x1640")

        let hidden = SeedEngine.targetSpec(base: DisplaySize(width: 1180, height: 820))
        XCTAssertEqual(hidden.key, "2360x1640")
    }

    /// 边栏几何(2026-09-28 实测):边栏显示时锚点/顶档整体平移一个家族,
    /// 面积相对判定在两态下结论必须一致。
    private func sidebarShownSidecar(unlocked: Bool) -> DisplayInfo {
        var modes = [
            Fixtures.mode(1116, 820),
            Fixtures.mode(1116, 820, ioFlags: DisplayModeIOFlags.valid),   // 锚点变体
        ]
        if unlocked {
            modes.append(Fixtures.mode(2232, 1640))
        }
        return DisplayCatalog.display(from: Fixtures.sidecarDisplay(modes: modes))
    }

    func testUnlockCheckHoldsUnderSidebarGeometry() {
        XCTAssertFalse(
            SeedEngine.hasHighResolutionModes(sidebarShownSidecar(unlocked: false)),
            "边栏态未解锁:判定不变"
        )
        XCTAssertTrue(
            SeedEngine.hasHighResolutionModes(sidebarShownSidecar(unlocked: true)),
            "边栏态已解锁(2232 顶档 + 1116 锚):判定不变"
        )
    }

    func testSeedTargetUnderSidebarGeometry() throws {
        // 边栏态播种:目标必须是当前几何锚点的精确 ×2
        let outcome = try engine.seedHighResolutionModes(on: sidebarShownSidecar(unlocked: false))
        guard case .seeded(let key) = outcome else {
            return XCTFail("应执行播种: \(outcome)")
        }
        XCTAssertEqual(key, "2232x1640", "边栏态目标 = 1116×2,而非取整后的 2230")
    }

    func testNativeBasePrefersAnchorThenFlaggedThenSmall() {
        // 锚点:双变体
        let anchored = DisplayCatalog.display(from: Fixtures.sidecarDisplay(modes: [
            Fixtures.mode(1180, 820),
            Fixtures.mode(2360, 1640),
            Fixtures.mode(1180, 820, ioFlags: DisplayModeIOFlags.valid),
        ]))
        XCTAssertEqual(SeedEngine.nativeBase(of: anchored), DisplaySize(width: 1180, height: 820))

        // 无锚点:宽 ≤1400 的最大安全档
        XCTAssertEqual(SeedEngine.nativeBase(of: vanillaSidecar), DisplaySize(width: 1180, height: 820))
    }

    // MARK: - 播种流程

    func testSeedRunsFullSequenceWhenAtNativeMode() throws {
        let outcome = try engine.seedHighResolutionModes(on: vanillaSidecar)

        XCTAssertEqual(outcome, .seeded(specKey: "2360x1640"))
        XCTAssertEqual(factory.createdSpecs.map(\.key), ["2360x1640"], "以 ×2 档单模式创建")
        XCTAssertEqual(mirror.mirrored.count, 1, "建立镜像")
        XCTAssertEqual(mirror.unmirrored.count, 1, "解除镜像")
        XCTAssertEqual(factory.destroyedIDs.count, 1, "销毁虚拟屏")
        XCTAssertTrue(mirror.resetCalls.isEmpty, "已在原生档:不做无谓的 CG 事务")
        XCTAssertFalse(mirror.isInMirrorSet(vanillaSidecar.displayID))
    }

    func testSeedResetsSidecarToNativeWhenNotAtNative() throws {
        // 停在高档但无锚点(未解锁判定不触发):先回原生再播种
        let sidecar = DisplayCatalog.display(from: Fixtures.sidecarDisplay(modes: [
            Fixtures.mode(2360, 1640),
            Fixtures.mode(1600, 1200),
            Fixtures.mode(1180, 820),
        ]))
        // Fixtures 默认 currentModeIndex=0 → 当前档 2360×1640(非原生)

        let outcome = try engine.seedHighResolutionModes(on: sidecar)

        XCTAssertEqual(outcome, .seeded(specKey: "2360x1640"))
        XCTAssertEqual(mirror.resetCalls, [sidecar.displayID], "非原生档先回原生")
        XCTAssertEqual(factory.createdSpecs.count, 1)
    }

    func testSeedSkipsWhenAlreadyUnlocked() throws {
        let unlocked = DisplayCatalog.display(from: Fixtures.sidecarDisplay(modes: [
            Fixtures.mode(1180, 820),
            Fixtures.mode(2360, 1640),
            Fixtures.mode(1180, 820, ioFlags: DisplayModeIOFlags.valid),
        ]))

        let outcome = try engine.seedHighResolutionModes(on: unlocked)

        XCTAssertEqual(outcome, .alreadyUnlocked)
        XCTAssertTrue(factory.createdSpecs.isEmpty, "已解锁不创建虚拟屏")
        XCTAssertTrue(mirror.mirrored.isEmpty)
    }

    // MARK: - 失败清理

    func testMirrorFailureTearsDownWithoutResidue() {
        mirror.mirrorError = MirrorError.failed("boom")
        XCTAssertThrowsError(try engine.seedHighResolutionModes(on: vanillaSidecar))

        XCTAssertEqual(factory.createdSpecs.count, 1, "创建已发生")
        XCTAssertEqual(factory.destroyedIDs.count, 1, "失败必须销毁虚拟屏")
        XCTAssertEqual(mirror.unmirrored.count, 1, "失败必须解除镜像")
    }

    func testMirrorNotTakingEffectFailsAndTearsDown() {
        // 配置"成功"但镜像未生效(显示器刚断开时的真实形态)
        mirror.mirrorTakesEffect = false
        XCTAssertThrowsError(try engine.seedHighResolutionModes(on: vanillaSidecar))

        XCTAssertEqual(factory.destroyedIDs.count, 1, "失败必须销毁虚拟屏")
        XCTAssertEqual(mirror.unmirrored.count, 1)
    }

    func testCreateFailureLeavesNoMirror() {
        factory.createError = VirtualDisplayError.classesUnavailable(["CGVirtualDisplay"])
        XCTAssertThrowsError(try engine.seedHighResolutionModes(on: vanillaSidecar))

        XCTAssertTrue(mirror.mirrored.isEmpty, "创建失败不得触碰镜像")
        XCTAssertEqual(factory.destroyedIDs.count, 0)
    }
}

// MARK: - Mocks(适配 v0.2.0 语义:单模式 create,无 activateSpec)

/// 可编程虚拟屏工厂 Mock。
final class MockSeedFactory: VirtualDisplayCreating {
    var createError: Error?
    private(set) var createdSpecs: [VirtualDisplaySpec] = []
    private(set) var destroyedIDs: [UInt32] = []
    private var nextID: UInt32 = 100

    func availability() -> VirtualDisplayAvailability {
        VirtualDisplayAvailability(isAvailable: true, missingClasses: [])
    }

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
final class MockSeedMirror: DisplayMirrorControlling {
    private(set) var mirrored: [(display: UInt32, master: UInt32)] = []
    private(set) var unmirrored: [UInt32] = []
    private(set) var resetCalls: [UInt32] = []
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

    func resetToDefaultMode(displayID: UInt32) {
        resetCalls.append(displayID)
    }
}
