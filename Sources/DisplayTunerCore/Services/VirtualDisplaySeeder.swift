import Foundation

/// 播种协议(测试注入 Mock)。
public protocol VirtualDisplaySeeding: AnyObject {
    /// 对 Sidecar 走一遍"镜像到高档虚拟屏再撤除"的播种流程,让系统把
    /// 高分辨率档写入其持久化模式表。失败时清理干净并抛错。
    func seedHighResolutionModes(on sidecar: DisplayInfo) throws
}

/// 高分辨率播种器。
///
/// 原理(真机验证):WindowServer 在镜像组协商时为 Sidecar 生成高分辨率档,
/// 并**写入用户级持久化显示配置** —— 断开重连后仍然保留(实测)。
/// 本类把这个因果浓缩为一次自动操作:
/// 创建高档虚拟屏 → 镜像 → 切到 ×2 档 → 等系统持久化 → 撤除 → Sidecar 回原生档。
/// 之后 Sidecar 的模式列表里会永久出现高档,直接在菜单里切换即可(已验证稳定)。
///
/// 全程可逆、无确认框;任何失败都解除镜像并销毁虚拟屏,不留残留。
public final class VirtualDisplaySeeder: VirtualDisplaySeeding {

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

    /// 表里是否已存在超过原生档(锚定尺寸)的安全模式。
    /// 已解锁的机器不需要播种入口,菜单直接显示高档。
    public static func hasHighResolutionModes(_ display: DisplayInfo) -> Bool {
        guard let native = display.nativeAnchoredSize, native.width > 0, native.height > 0 else {
            return false
        }
        let nativeArea = native.width * native.height
        return display.modes.contains {
            $0.isSafe && $0.width * $0.height > nativeArea * 2
        }
    }

    public func seedHighResolutionModes(on sidecar: DisplayInfo) throws {
        let base = VirtualDisplayPresets.nativeBase(of: sidecar)
        logger.info(
            "seeding high-resolution modes for \(sidecar.logDescriptor) (base \(base.width)x\(base.height))",
            context: "Seeder"
        )
        // 前置:一律把 Sidecar 切回锚定的原生档(真机实验:Sidecar 处于任何
        // 非原生档时,虚拟屏的模式表发布与镜像协商都会被系统拒绝)。
        // 已知限制(2026-09-28 探针):对 Sidecar 的切档动作本身会让 WindowServer
        // 拒绝随后一段时间的虚拟屏创建(重试无效,Sidecar 重连后解除)——
        // 播种失败时先重连 Sidecar 再试,排查步骤见 TESTING.md。
        mirror.resetToDefaultMode(displayID: sidecar.displayID)
        Thread.sleep(forTimeInterval: 1.0)

        let presets = VirtualDisplayPresets.presets(baseWidth: base.width, baseHeight: base.height)
        guard let preferred = presets.first(where: { $0.isRecommended })?.spec else {
            throw VirtualDisplayError.createFailed("no usable presets for seeding")
        }
        let table = presets.map(\.spec)

        var handle: VirtualDisplayHandle?
        do {
            let created = try factory.create(
                spec: preferred,
                additionalModes: table.filter { $0.key != preferred.key }
            )
            handle = created
            Thread.sleep(forTimeInterval: 1.0)   // 创建后稳定(实验:过早镜像会被拒)

            try mirror.mirror(display: sidecar.displayID, toMaster: created.displayID)
            // 切到 ×2 档,触发系统为镜像组生成并持久化高档
            try factory.activateSpec(created, spec: preferred)
            Thread.sleep(forTimeInterval: 2.0)   // 给系统时间写入持久化配置

            try mirror.unmirror(display: sidecar.displayID)
            factory.destroy(created)
            handle = nil
            Thread.sleep(forTimeInterval: 0.5)

            // 收尾:Sidecar 回原生档,干净离场
            mirror.resetToDefaultMode(displayID: sidecar.displayID)
            Thread.sleep(forTimeInterval: 0.5)
            logger.info(
                "seeded high-resolution modes for \(sidecar.logDescriptor) (base \(base.width)x\(base.height))",
                context: "Seeder"
            )
        } catch {
            if let created = handle {
                try? mirror.unmirror(display: sidecar.displayID)
                factory.destroy(created)
            }
            logger.error("seeding failed for \(sidecar.logDescriptor): \(error)", context: "Seeder")
            throw error
        }
    }
}
