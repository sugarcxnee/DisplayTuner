import Foundation

/// 实验性 Sidecar 增强。
///
/// 两部分能力,分层降级:
/// 1. 公开增强(默认生效路径):以 `kCGDisplayShowDuplicateLowResolutionModes`
///    选项重新枚举,合并系统默认隐藏的模式 —— 这是"副屏很糊"时扩大可选面的主要手段;
/// 2. 私有增强(仅探测):dlopen DisplayServices 并报告符号可用性。
///    当前版本不调用任何写入型私有函数;符号缺失时如实报告并降级。
///
/// 系统若根本不暴露更高分辨率模式,这里无法也无权创造(规格 0/6 的限制说明)。
public protocol SidecarEnhancer: AnyObject {
    /// 返回隐藏枚举中发现、且不在 `display.modes` 里的额外模式(已排序)。
    func extraModes(for display: DisplayInfo) -> [DisplayModeInfo]
    /// 探测私有符号可用性;结果同时缓存供菜单展示。
    @discardableResult
    func probePrivateStatus() -> PrivateSymbolReport
    /// 最近一次探测结果(未探测过为 nil)。
    var lastProbeReport: PrivateSymbolReport? { get }
}

public final class ExperimentalSidecarEnhancer: SidecarEnhancer {

    private let displayService: DisplayService
    private let privateServices: PrivateDisplayServices
    private let logger: DTLogger
    private let lock = NSLock()
    private var cachedReport: PrivateSymbolReport?

    public var lastProbeReport: PrivateSymbolReport? {
        lock.lock(); defer { lock.unlock() }
        return cachedReport
    }

    public init(
        displayService: DisplayService,
        privateServices: PrivateDisplayServices,
        logger: DTLogger = DTLogger()
    ) {
        self.displayService = displayService
        self.privateServices = privateServices
        self.logger = logger
    }

    public func extraModes(for display: DisplayInfo) -> [DisplayModeInfo] {
        let hiddenRaw = displayService.rawModes(for: display.displayID, includeHidden: true)
        guard !hiddenRaw.isEmpty else { return [] }

        let knownKeys = Set(display.modes.map(\.modeKey))
        let currentKey = display.currentMode?.modeKey
        let extras = hiddenRaw
            .map { DisplayCatalog.modeInfo(from: $0, isCurrent: false) }
            .filter { !knownKeys.contains($0.modeKey) && $0.modeKey != currentKey }

        if extras.isEmpty {
            logger.debug("no extra modes revealed for \(display.logDescriptor)", context: "SidecarEnhancer")
        } else {
            logger.info(
                "revealed \(extras.count) extra mode(s) for \(display.logDescriptor)",
                context: "SidecarEnhancer"
            )
        }
        return ModeRanker.sort(extras, isSidecar: display.isSidecar)
    }

    @discardableResult
    public func probePrivateStatus() -> PrivateSymbolReport {
        let report = privateServices.probe()
        lock.lock()
        cachedReport = report
        lock.unlock()
        if !report.isAvailable {
            logger.info(
                "experimental enhancement degraded: \(report.statusDescription), using public API only",
                context: "SidecarEnhancer"
            )
        }
        return report
    }
}
