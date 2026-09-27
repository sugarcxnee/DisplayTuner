import Foundation
import CryptoKit

/// 日志级别,可通过菜单调整。
public enum LogLevel: Int, Codable, CaseIterable, Comparable, Sendable {
    case error = 0
    case info = 1
    case debug = 2

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// 日志行内使用的标签。
    public var label: String {
        switch self {
        case .error: return "ERROR"
        case .info: return "INFO"
        case .debug: return "DEBUG"
        }
    }

    /// 菜单里展示的中文名。
    public var displayName: String {
        switch self {
        case .error: return "错误"
        case .info: return "信息"
        case .debug: return "调试"
        }
    }

    /// 从持久化 JSON 读回时的安全解码:未知值回退 info,不崩溃。
    public static func decodeSafely(_ rawValue: Int) -> LogLevel {
        LogLevel(rawValue: rawValue) ?? .info
    }
}

/// 日志输出目标。
public protocol LogSink: AnyObject {
    func write(_ line: String)
}

/// 控制台输出(stderr)。
public final class ConsoleLogSink: LogSink {
    public init() {}

    public func write(_ line: String) {
        FileHandle.standardError.write(((line + "\n") as NSString).utf8String.map { Data(bytes: $0, count: strlen($0)) } ?? Data())
    }
}

/// 内存输出,测试与诊断面板用。
public final class MemoryLogSink: LogSink {
    public private(set) var lines: [String] = []
    private let lock = NSLock()

    public init() {}

    public func write(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    public var joined: String { lines.joined(separator: "\n") }
}

/// 文件输出,超限轮转:`DisplayTuner.log` → `DisplayTuner.log.1` → …(最多保留 rotatedCount 份旧文件)。
public final class FileLogSink: LogSink {
    private let url: URL
    private let maxBytes: Int
    private let rotatedCount: Int
    private let queue = DispatchQueue(label: "dev.displaytuner.filelogsink")
    private let fm = FileManager.default
    private var currentSize: Int

    public init(url: URL, maxBytes: Int = 512 * 1024, rotatedCount: Int = 2) {
        self.url = url
        self.maxBytes = max(64, maxBytes)
        self.rotatedCount = max(0, rotatedCount)
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        currentSize = (attrs?[.size] as? Int) ?? 0
    }

    public func write(_ line: String) {
        queue.sync {
            guard let data = (line + "\n").data(using: .utf8) else { return }
            if currentSize + data.count > maxBytes {
                rotate()
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            currentSize += data.count
        }
    }

    private func rotate() {
        let oldest = rotatedCount > 0 ? "\(url.path).\(rotatedCount)" : nil
        if let oldest = oldest, fm.fileExists(atPath: oldest) {
            try? fm.removeItem(atPath: oldest)
        }
        guard rotatedCount > 0 else {
            try? fm.removeItem(atPath: url.path)
            fm.createFile(atPath: url.path, contents: nil)
            currentSize = 0
            return
        }
        var index = rotatedCount - 1
        while index >= 1 {
            let from = "\(url.path).\(index)"
            if fm.fileExists(atPath: from) {
                try? fm.moveItem(atPath: from, toPath: "\(url.path).\(index + 1)")
            }
            index -= 1
        }
        if fm.fileExists(atPath: url.path) {
            try? fm.moveItem(atPath: url.path, toPath: "\(url.path).1")
        }
        fm.createFile(atPath: url.path, contents: nil)
        currentSize = 0
    }
}

/// 全局日志器:级别过滤 + 多输出 + 统一格式。所有枚举、切换、回滚都应写日志。
public final class DTLogger: @unchecked Sendable {
    private var sinks: [LogSink]
    private var levelValue: LogLevel
    private let lock = NSLock()
    private let timestampFormatter: DateFormatter

    /// 当前生效级别(线程安全)。
    public var level: LogLevel {
        get {
            lock.lock(); defer { lock.unlock() }
            return levelValue
        }
        set {
            lock.lock(); defer { lock.unlock() }
            levelValue = newValue
        }
    }

    /// 纯控制台(库内默认、测试友好)。
    public init(sinks: [LogSink] = [ConsoleLogSink()], level: LogLevel = .info) {
        self.sinks = sinks
        self.levelValue = level
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        self.timestampFormatter = formatter
    }

    /// 生产默认:控制台 + Application Support 轮转文件。
    public static func makeDefault() -> DTLogger {
        DTLogger(sinks: [ConsoleLogSink(), FileLogSink(url: LogLocations.logFileURL())])
    }

    public func setLevel(_ newLevel: LogLevel) {
        level = newLevel
    }

    public func error(_ message: @autoclosure () -> String, context: String? = nil) {
        log(.error, message(), context: context)
    }

    public func info(_ message: @autoclosure () -> String, context: String? = nil) {
        log(.info, message(), context: context)
    }

    public func debug(_ message: @autoclosure () -> String, context: String? = nil) {
        log(.debug, message(), context: context)
    }

    public func log(_ level: LogLevel, _ message: @autoclosure () -> String, context: String? = nil) {
        guard level <= self.level else { return }
        let stamp = timestampFormatter.string(from: Date())
        let line = context == nil
            ? "\(stamp) [\(level.label)] \(message())"
            : "\(stamp) [\(level.label)] [\(context!)] \(message())"
        lock.lock()
        let targets = sinks
        lock.unlock()
        targets.forEach { $0.write(line) }
    }
}

/// 日志文件位置(可注入基础目录,便于测试)。
public enum LogLocations {
    public static func logFileURL(baseDirectory: URL? = nil) -> URL {
        let base = baseDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DisplayTuner/logs/DisplayTuner.log")
    }
}

/// 日志脱敏:稳定 ID 含序列号、显示器名可能含用户名,写入日志前先散列/截断。
public enum PrivacyRedactor {
    /// 稳定 ID → 8 位十六进制短哈希。
    public static func shortHash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .prefix(4)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// 设备名等自由文本 → 只保留长度与前缀特征,不落原文。
    public static func describeName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "<empty>" }
        return "name(len=\(trimmed.count))"
    }
}
