import XCTest
import CoreGraphics
@testable import DisplayTunerCore

/// 真机播种集成测试(危险级)。
///
/// 前提:Sidecar 已连接、有人在场;app 退出或在场观察。
/// 门控:`DISPLAYTUNER_RUN_DANGEROUS_TESTS=1`。
///
/// 断言纪律(2026-09-28 边栏几何):模式表是随有效面板面积实时再生的阶梯,
/// 档数与具体档位随 iPad 边栏状态平移(1180/2360 ↔ 1116/2232 家族)——
/// 本测试只用相对断言(播种前后高档数不降、收尾档 == 同次枚举的锚点)。
///
/// 已解锁机器上验证幂等(高档已在,流程跑通、不丢档、无残留);
/// "从零写入"需在未解锁机器(或新用户账户)上验证。
final class LiveSeedingIntegrationTests: XCTestCase {

    func testDangerousSeedHighResolutionModes() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["DISPLAYTUNER_RUN_DANGEROUS_TESTS"] == "1",
            "设置 DISPLAYTUNER_RUN_DANGEROUS_TESTS=1 且确保 Sidecar 已连接、有人在场"
        )
        let logger = DTLogger.makeDefault()
        // 播种期间画面会变化(重置 → 镜像 → 回收),全程约 5 秒。
        let service = CoreGraphicsDisplayService(logger: logger)
        guard let sidecar = service.snapshotDisplays().first(where: \.isSidecar) else {
            throw XCTSkip("当前无 Sidecar 连接")
        }
        let highBefore = sidecar.modes.filter {
            $0.isSafe && Double($0.width * $0.height) > 1_200_000
        }.count

        let engine = SeedEngine(
            factory: CoreDisplayVirtualDisplayFactory(logger: logger),
            mirror: CoreGraphicsMirrorService(logger: logger),
            logger: logger
        )
        let outcome = try engine.seedHighResolutionModes(on: sidecar)

        // 等系统稳定后重新枚举
        Thread.sleep(forTimeInterval: 2.0)
        let after = service.snapshotDisplays()
        guard let sidecarAfter = after.first(where: { $0.stableID == sidecar.stableID }) else {
            return XCTFail("播种后 Sidecar 消失")
        }
        let highAfter = sidecarAfter.modes.filter {
            $0.isSafe && Double($0.width * $0.height) > 1_200_000
        }.count

        print("📺 播种结果=\(outcome), 高档数 播种前=\(highBefore) 后=\(highAfter), 当前=\(sidecarAfter.currentMode?.modeKey ?? "?")")
        XCTAssertGreaterThanOrEqual(highAfter, highBefore, "播种不得丢失已有高档")
        XCTAssertFalse(CoreGraphicsMirrorService(logger: logger).isInMirrorSet(sidecarAfter.displayID), "不在镜像组")
        if let anchor = sidecarAfter.nativeAnchoredSize,
           let current = sidecarAfter.currentMode {
            XCTAssertEqual(current.width, anchor.width, "收尾应回到原生档")
            XCTAssertEqual(current.height, anchor.height)
        }
    }
}
