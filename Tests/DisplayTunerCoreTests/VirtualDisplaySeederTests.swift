import XCTest
@testable import DisplayTunerCore

final class VirtualDisplaySeederTests: XCTestCase {

    private var factory: MockVirtualDisplayFactory!
    private var mirror: MockMirrorService!
    private var seeder: VirtualDisplaySeeder!
    private var sidecar: DisplayInfo!

    override func setUp() {
        super.setUp()
        factory = MockVirtualDisplayFactory()
        mirror = MockMirrorService()
        seeder = VirtualDisplaySeeder(
            factory: factory,
            mirror: mirror,
            logger: DTLogger(sinks: [MemoryLogSink()])
        )
        // 原始 7 档形态的 Sidecar(无高档、无锚点)
        sidecar = DisplayCatalog.display(from: Fixtures.sidecarDisplay(modes: [
            Fixtures.mode(1180, 820),
        ]))
    }

    private var expectedPreferred: VirtualDisplaySpec {
        // 基准 1180×820 → 推荐 ×2 档 2360×1640
        VirtualDisplaySpec(width: 2360, height: 1640)
    }

    // MARK: - hasHighResolutionModes

    func testHasHighResolutionModesFalseForVanillaSidecar() {
        XCTAssertFalse(VirtualDisplaySeeder.hasHighResolutionModes(sidecar))
    }

    func testHasHighResolutionModesTrueWhenHighModesWithAnchor() {
        // 双 1180×820 变体(锚点)+ 2360×1640 高档
        let record = RawDisplayRecord(
            displayID: 5,
            vendorNumber: 0x6161706c,
            modelNumber: 0x69506164,
            serialNumber: 0,
            name: "iPad",
            bounds: .zero,
            currentModeIndex: 0,
            modes: [
                Fixtures.mode(1180, 820),
                Fixtures.mode(2360, 1640),
                Fixtures.mode(1180, 820, ioFlags: DisplayModeIOFlags.valid),   // 污染变体
            ]
        )
        let display = DisplayCatalog.display(from: record)
        XCTAssertEqual(display.nativeAnchoredSize?.width, 1180, "变体锚点应被识别")
        XCTAssertTrue(VirtualDisplaySeeder.hasHighResolutionModes(display))
    }

    // MARK: - 播种流程

    func testSeedRunsFullSequenceAndCleansUp() throws {
        try seeder.seedHighResolutionModes(on: sidecar)

        XCTAssertEqual(factory.createdSpecs.map(\.key), [expectedPreferred.key], "以 ×2 档创建")
        XCTAssertEqual(factory.activateCalls.map(\.keyInCall), [expectedPreferred.key], "切到 ×2 触发持久化")
        XCTAssertEqual(mirror.mirrored.count, 1, "建立镜像")
        XCTAssertEqual(mirror.unmirrored.count, 1, "解除镜像")
        XCTAssertEqual(factory.destroyedIDs.count, 1, "销毁虚拟屏")
        XCTAssertEqual(
            mirror.resetCalls,
            [sidecar.displayID, sidecar.displayID],
            "前置(回原生档保证发布/镜像可行)+ 收尾(干净离场)各重置一次"
        )
        XCTAssertFalse(mirror.isInMirrorSet(sidecar.displayID))
    }

    func testSeedResetsLegacyHighModeBeforeStarting() throws {
        // Sidecar 停留在遗留高档(2360×1640)→ 先重置
        let highSidecar = DisplayCatalog.display(from: Fixtures.sidecarDisplay(modes: [
            Fixtures.mode(2360, 1640),
            Fixtures.mode(1180, 820),
        ]))
        try seeder.seedHighResolutionModes(on: highSidecar)

        XCTAssertEqual(mirror.resetCalls.first, highSidecar.displayID, "遗留高档先回原生")
    }

    func testSeedFailureTearsDownWithoutResidue() {
        factory.activateError = VirtualDisplayError.activationFailed("boom")
        // 需要 mirror 成功后才会到 activateSpec
        XCTAssertThrowsError(try seeder.seedHighResolutionModes(on: sidecar))

        XCTAssertEqual(factory.destroyedIDs.count, 1, "失败也必须销毁虚拟屏")
        XCTAssertEqual(mirror.unmirrored.count, 1, "失败必须解除镜像")
    }

    func testSeedCreateFailureLeavesNoMirror() {
        factory.createError = VirtualDisplayError.classesUnavailable(["CGVirtualDisplay"])
        XCTAssertThrowsError(try seeder.seedHighResolutionModes(on: sidecar))
        XCTAssertTrue(mirror.mirrored.isEmpty)
        XCTAssertEqual(factory.destroyedIDs.count, 0)
    }
}

private extension String {
    /// "101:2360x1640" → "2360x1640"
    var keyInCall: String {
        split(separator: ":").last.map(String.init) ?? self
    }
}

/// 可编程播种器 Mock(VM 测试用)。
final class MockSeeder: VirtualDisplaySeeding {
    private(set) var seedCalls: [String] = []
    var error: Error?

    func seedHighResolutionModes(on sidecar: DisplayInfo) throws {
        seedCalls.append(sidecar.stableID)
        if let error = error { throw error }
    }
}
