import Foundation

/// 配置存储:内存态 + JSON 落盘 + 导入导出。
public protocol ConfigStore: AnyObject {
    /// 当前生效配置。
    var config: DisplayTunerConfig { get }
    /// 保存(内存 + 磁盘)。
    func save(_ config: DisplayTunerConfig)
    /// 从磁盘重读;损坏文件自动备份并回退默认值。
    @discardableResult
    func reload() -> DisplayTunerConfig
    /// 导出当前配置到 JSON 文件(菜单/NSSavePanel 与命令行共用)。
    func exportConfig(to url: URL) throws
    /// 从 JSON 文件导入并生效(菜单/NSOpenPanel 与命令行共用)。
    /// 文件损坏或格式不支持时抛错,当前配置保持不变。
    @discardableResult
    func importConfig(from url: URL) throws -> DisplayTunerConfig
}

/// Application Support 下的 JSON 文件实现。
public final class JSONFileConfigStore: ConfigStore {

    public let fileURL: URL
    private let logger: DTLogger
    private let lock = NSLock()
    private var current: DisplayTunerConfig

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    public var config: DisplayTunerConfig {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public init(fileURL: URL? = nil, logger: DTLogger = DTLogger()) {
        self.fileURL = fileURL ?? JSONFileConfigStore.defaultFileURL()
        self.logger = logger
        let loaded = Self.load(from: self.fileURL, logger: logger)
        self.current = loaded
    }

    public static func defaultFileURL(baseDirectory: URL? = nil) -> URL {
        let base = baseDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DisplayTuner/config.json")
    }

    // MARK: - ConfigStore

    public func save(_ config: DisplayTunerConfig) {
        lock.lock()
        current = config
        lock.unlock()
        writeAtomically(config)
    }

    @discardableResult
    public func reload() -> DisplayTunerConfig {
        let loaded = Self.load(from: fileURL, logger: logger)
        lock.lock()
        current = loaded
        lock.unlock()
        return loaded
    }

    public func exportConfig(to url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        let data = try encoder.encode(current)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        logger.info("exported config to \(url.lastPathComponent)", context: "ConfigStore")
    }

    @discardableResult
    public func importConfig(from url: URL) throws -> DisplayTunerConfig {
        let data = try Data(contentsOf: url)
        let imported = try JSONDecoder().decode(DisplayTunerConfig.self, from: data)
        // 版本太新(来自未来版本 App)时拒绝,避免静默丢配置
        guard imported.version <= DisplayTunerConfig.currentVersion else {
            throw ConfigImportError.unsupportedVersion(imported.version)
        }
        save(imported)
        logger.info("imported config from \(url.lastPathComponent)", context: "ConfigStore")
        return imported
    }

    // MARK: - 内部

    private func writeAtomically(_ config: DisplayTunerConfig) {
        do {
            let data = try encoder.encode(config)
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        } catch {
            // 落盘失败:内存配置仍生效,记日志即可,绝不崩溃
            logger.error("failed to persist config: \(error)", context: "ConfigStore")
        }
    }

    /// 读取 + 损坏恢复:损坏文件重命名为 config.corrupt-<时间戳>.json 后返回默认配置。
    private static func load(from url: URL, logger: DTLogger) -> DisplayTunerConfig {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            return DisplayTunerConfig()
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(DisplayTunerConfig.self, from: data)
            return decoded
        } catch {
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let backupURL = url.deletingLastPathComponent()
                .appendingPathComponent("config.corrupt-\(stamp).json")
            try? fm.moveItem(at: url, to: backupURL)
            logger.error(
                "config corrupted (\(error)); backed up to \(backupURL.lastPathComponent), falling back to defaults",
                context: "ConfigStore"
            )
            return DisplayTunerConfig()
        }
    }
}

/// 配置导入错误。
public enum ConfigImportError: Error, Equatable, CustomStringConvertible {
    case unsupportedVersion(Int)

    public var description: String {
        switch self {
        case .unsupportedVersion(let version):
            return "config version \(version) is newer than supported \(DisplayTunerConfig.currentVersion)"
        }
    }
}
