import XCTest
import CoreGraphics
@testable import DisplayTunerCore

/// 影子 HiDPI 真机端到端验收(危险级)。
///
/// 前提:Sidecar 已连接、当前处于清晰态(系统路径刚设置过,如控制中心
/// 切换一次边栏);有人在场。门控:`DISPLAYTUNER_RUN_DANGEROUS_TESTS=1`。
///
/// 验证闭环(2026-09-28 定性"第五条路径"):
/// 1. 清晰态快照捕获影子 2x 对象,模式表注入 HiDPI 条目;
/// 2. 程序切走(1x 档,糊);
/// 3. 再切回原逻辑档 —— 升级链经影子缓存落到 2x,清晰态程序路径恢复。
///
/// 断言纪律:尺寸用运行时记录值,不硬编码 1116/1180(边栏家族随几何平移)。
final class LiveShadowHiDPIIntegrationTests: XCTestCase {

    func testDangerousShadowHiDPISurvivesRoundTrip() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["DISPLAYTUNER_RUN_DANGEROUS_TESTS"] == "1",
            "设置 DISPLAYTUNER_RUN_DANGEROUS_TESTS=1 且确保 Sidecar 已连接、处于清晰态、有人在场"
        )
        let logger = DTLogger.makeDefault()
        let cache = HiDPIModeCache()
        let service = CoreGraphicsDisplayService(logger: logger, hidpiCache: cache)
        let controller = CoreGraphicsDisplayModeController(logger: logger, hidpiCache: cache)

        guard let sidecar = service.snapshotDisplays().first(where: \.isSidecar) else {
            throw XCTSkip("当前无 Sidecar 连接")
        }
        guard let sharp = sidecar.currentMode, sharp.isHiDPI else {
            throw XCTSkip("Sidecar 不在清晰态(当前档非 HiDPI):先在控制中心切换一次边栏,再重跑")
        }

        // 捕获 → 注入:清晰态下快照的模式表必须含同尺寸 HiDPI 条目
        XCTAssertTrue(
            sidecar.modes.contains { $0.isHiDPI && $0.width == sharp.width && $0.height == sharp.height },
            "影子 HiDPI 条目应注入模式表"
        )

        // 程序切走:选一个不同逻辑尺寸的安全 1x 档
        guard let away = sidecar.modes.first(where: {
            $0.isSafe && !$0.isHiDPI
                && $0.width != sharp.width && $0.height != sharp.height
        }) else {
            throw XCTSkip("无可用切走档")
        }
        _ = try controller.apply(away, to: sidecar)
        Thread.sleep(forTimeInterval: 2.0)
        guard let blurred = controller.currentMode(for: sidecar.displayID) else {
            return XCTFail("切走后读不到当前档")
        }
        XCTAssertFalse(blurred.isHiDPI, "切走后应落在 1x(糊态)")

        // 切回原逻辑档:清晰态快照经同尺寸收敛后,菜单上该尺寸只有 HiDPI
        // 条目(1x 已被收敛)—— 用户实际点选的就是它
        guard let backTarget = sidecar.modes.first(where: {
            $0.width == sharp.width && $0.height == sharp.height
        }) else {
            return XCTFail("找不到原逻辑档条目")
        }
        let change = try controller.apply(backTarget, to: sidecar)
        Thread.sleep(forTimeInterval: 2.0)
        guard let restored = controller.currentMode(for: sidecar.displayID) else {
            return XCTFail("切回后读不到当前档")
        }

        print("📺 影子往返: \(sharp.modeKey) → \(blurred.modeKey) → \(restored.modeKey) (applied \(change.appliedMode.modeKey))")
        XCTAssertTrue(restored.isHiDPI, "切回后应恢复 2x 清晰态,实际 \(restored.modeKey)")
        XCTAssertEqual(change.appliedMode.modeKey, restored.modeKey, "应用凭据应与读回一致")
        XCTAssertEqual(restored.pixelWidth, sharp.pixelWidth, "物理渲染像素应与清晰态一致")
    }
}
