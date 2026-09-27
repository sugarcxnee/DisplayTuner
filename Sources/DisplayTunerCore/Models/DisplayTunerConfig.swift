import Foundation

/// 每显示器持久化配置。
public struct PerDisplayConfig: Codable, Equatable, Sendable {
    /// 上次为该显示器选择的模式键(如 "1920x1080@60-hidpi"),用于自动恢复。
    public var modeKey: String?
    /// 菜单"过滤"子菜单的当前选择。
    public var filters: Set<ModeFilter>
    /// 上次确认保留的虚拟屏规格宽(仅记录偏好;虚拟屏不做开机自动重建)。
    public var virtualDisplayWidth: Int?
    /// 上次确认保留的虚拟屏规格高。
    public var virtualDisplayHeight: Int?

    public init(
        modeKey: String? = nil,
        filters: Set<ModeFilter> = [],
        virtualDisplayWidth: Int? = nil,
        virtualDisplayHeight: Int? = nil
    ) {
        self.modeKey = modeKey
        self.filters = filters
        self.virtualDisplayWidth = virtualDisplayWidth
        self.virtualDisplayHeight = virtualDisplayHeight
    }
}

/// 应用整体配置。手动实现 Codable:任何字段损坏都回退默认值,绝不因配置文件崩溃。
public struct DisplayTunerConfig: Codable, Equatable, Sendable {

    public static let currentVersion = 1

    public var version: Int
    /// 自动恢复上次配置(默认开)。
    public var autoRestore: Bool
    /// 实验性 Sidecar 增强(默认关)。
    public var experimentalSidecar: Bool
    /// 日志级别原始值,经 `logLevel` 存取以获得未知值容错。
    public var logLevelRaw: Int
    /// 按显示器稳定 ID 索引的每显示器配置。
    public var perDisplay: [String: PerDisplayConfig]

    public init(
        version: Int = DisplayTunerConfig.currentVersion,
        autoRestore: Bool = true,
        experimentalSidecar: Bool = false,
        logLevelRaw: Int = LogLevel.info.rawValue,
        perDisplay: [String: PerDisplayConfig] = [:]
    ) {
        self.version = version
        self.autoRestore = autoRestore
        self.experimentalSidecar = experimentalSidecar
        self.logLevelRaw = logLevelRaw
        self.perDisplay = perDisplay
    }

    public var logLevel: LogLevel {
        get { LogLevel.decodeSafely(logLevelRaw) }
        set { logLevelRaw = newValue.rawValue }
    }

    // MARK: - 手动 Codable(字段级容错)

    private enum CodingKeys: String, CodingKey {
        case version
        case autoRestore
        case experimentalSidecar
        case logLevel
        case perDisplay
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 每个字段独立容错:类型不符只回退该字段,不让整个配置被判损坏
        version = (try? container.decodeIfPresent(Int.self, forKey: .version)) ?? nil
            ?? DisplayTunerConfig.currentVersion
        autoRestore = (try? container.decodeIfPresent(Bool.self, forKey: .autoRestore)) ?? nil ?? true
        experimentalSidecar = (try? container.decodeIfPresent(Bool.self, forKey: .experimentalSidecar)) ?? nil ?? false
        let levelRaw = (try? container.decodeIfPresent(Int.self, forKey: .logLevel)) ?? nil
        logLevelRaw = levelRaw.flatMap { LogLevel(rawValue: $0)?.rawValue } ?? LogLevel.info.rawValue
        perDisplay = (try? container.decodeIfPresent([String: PerDisplayConfig].self, forKey: .perDisplay)) ?? nil ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(autoRestore, forKey: .autoRestore)
        try container.encode(experimentalSidecar, forKey: .experimentalSidecar)
        try container.encode(logLevelRaw, forKey: .logLevel)
        try container.encode(perDisplay, forKey: .perDisplay)
    }
}
