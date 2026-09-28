import Foundation

/// 播种结果。
public enum SeedOutcome: Equatable {
    /// 模式表已有高档,无需播种。
    case alreadyUnlocked
    /// 播种流程执行完毕(高档已由系统写入持久模式表)。
    case seeded(specKey: String)
}

/// 播种协议(测试注入 Mock)。
public protocol SidecarSeeding: AnyObject {
    /// 对 Sidecar 走一遍"创建高档虚拟屏 → 镜像 → 等系统持久化 → 撤除",
    /// 让系统把高分辨率档写入其持久化模式表。失败时清理并抛错。
    func seedHighResolutionModes(on sidecar: DisplayInfo) throws -> SeedOutcome
}

/// 播种引擎(v1.0,进程内)。
///
/// 机理(2026-09-28 真机实验确立):Sidecar 的持久模式表出厂只含保守报价
/// (原生 1180×820 及更低),镜像到高档虚拟屏会逼系统协商出完整能力并把
/// 新档写入持久模式表 —— 断开重连、重启都不丢。一次播种,终身直接切档。
///
/// 流程纪律(全部来自真机对照实验,详见 TESTING.md):
/// - 声明用 v0.2.0/2.1 的实证配置:单模式表 + 逻辑尺寸(×2 档)。
///   勿引入 v0.2.2+ 的多模式表/HiDPI 翻倍语义(未证实收益、已证实风险);
/// - Sidecar 处于非原生档时镜像协商会被系统拒绝 —— 不在原生档先回原生;
/// - 失败路径必须销毁虚拟屏(ARC release),成功路径同样干净离场;
/// - 引擎不重新查询 Sidecar 模式:档位先验均来自调用方枚举的 DisplayInfo。
public final class SeedEngine: SidecarSeeding {

    private let factory: VirtualDisplayCreating
    private let mirror: DisplayMirrorControlling
    private let logger: DTLogger

    public init(
        factory: VirtualDisplayCreating,
        mirror: DisplayMirrorControlling,
        logger: DTLogger = DTLogger()
    ) {
        self.factory = factory
        self.mirror = mirror
        self.logger = logger
    }

    // MARK: - 解锁判定与基准

    /// 表里是否存在超过原生档(锚定尺寸)两倍面积的安全模式。
    /// 已解锁的机器不需要播种入口,菜单直接显示高档。
    public static func hasHighResolutionModes(_ display: DisplayInfo) -> Bool {
        guard let native = display.nativeAnchoredSize else { return false }
        let nativeArea = native.width * native.height
        return display.modes.contains {
            $0.isSafe && $0.width * $0.height > nativeArea * 2
        }
    }

    /// 原生基准档:锚点优先,退回 defaultFlag → 宽 ≤1400 的最大安全档 → 当前档。
    public static func nativeBase(of display: DisplayInfo) -> DisplaySize {
        if let anchored = display.nativeAnchoredSize {
            return anchored
        }
        let safe = display.modes.filter(\.isSafe)
        if let flagged = safe.first(where: { $0.ioFlags & DisplayModeIOFlags.defaultFlag != 0 }) {
            return DisplaySize(width: flagged.width, height: flagged.height)
        }
        if let small = safe.filter({ $0.width <= 1400 }).max(by: { $0.width * $0.height < $1.width * $1.height }) {
            return DisplaySize(width: small.width, height: small.height)
        }
        if let current = display.currentMode {
            return DisplaySize(width: current.width, height: current.height)
        }
        return DisplaySize(width: 0, height: 0)
    }

    /// 播种目标档:基准 ×2(接近 iPad 物理像素,点对点)。
    static func targetSpec(base: DisplaySize) -> VirtualDisplaySpec {
        VirtualDisplaySpec(width: rounded10(base.width * 2), height: rounded10(base.height * 2))
    }

    private static func rounded10(_ value: Int) -> Int {
        Int((Double(value) / 10).rounded() * 10)
    }

    // MARK: - 播种流程

    public func seedHighResolutionModes(on sidecar: DisplayInfo) throws -> SeedOutcome {
        if Self.hasHighResolutionModes(sidecar) {
            logger.info("already unlocked, seeding skipped for \(sidecar.logDescriptor)", context: "Seed")
            return .alreadyUnlocked
        }
        let base = Self.nativeBase(of: sidecar)
        guard base.width > 0, base.height > 0 else {
            throw VirtualDisplayError.createFailed("无法确定 Sidecar 的原生基准档")
        }
        let spec = Self.targetSpec(base: base)
        logger.info(
            "seeding high-resolution modes for \(sidecar.logDescriptor) (base \(base.width)x\(base.height), target \(spec.key))",
            context: "Seed"
        )

        // 前置:非原生档先回原生(镜像协商硬性前提;基准档与当前档均为先验,
        // 同逻辑尺寸即视为已在原生档,不做无谓的 CG 事务)。
        if let current = sidecar.currentMode,
           current.width != base.width || current.height != base.height {
            mirror.resetToDefaultMode(displayID: sidecar.displayID)
            Thread.sleep(forTimeInterval: 1.0)
        }

        var handle: VirtualDisplayHandle?
        do {
            let created = try factory.create(spec: spec)
            handle = created
            Thread.sleep(forTimeInterval: 1.0)   // 创建后稳定(实验:过早镜像会被拒)

            try mirror.mirror(display: sidecar.displayID, toMaster: created.displayID)
            guard mirror.isInMirrorSet(sidecar.displayID) else {
                throw VirtualDisplayError.createFailed("镜像未生效")
            }
            Thread.sleep(forTimeInterval: 2.0)   // 等系统把高档写入持久模式表

            try mirror.unmirror(display: sidecar.displayID)
            factory.destroy(created)
            handle = nil
            Thread.sleep(forTimeInterval: 0.5)   // 拔出稳定
            logger.info("seeded high-resolution modes for \(sidecar.logDescriptor)", context: "Seed")
        } catch {
            if let created = handle {
                try? mirror.unmirror(display: sidecar.displayID)
                factory.destroy(created)
            }
            logger.error("seeding failed for \(sidecar.logDescriptor): \(error)", context: "Seed")
            throw error
        }
        return .seeded(specKey: spec.key)
    }
}
