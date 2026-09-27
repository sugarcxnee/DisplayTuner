import XCTest
@testable import DisplayTunerCore

final class LoggingTests: XCTestCase {

    func testLevelFiltering_InfoLevelDropsDebug() {
        let sink = MemoryLogSink()
        let logger = DTLogger(sinks: [sink], level: .info)

        logger.error("e")
        logger.info("i")
        logger.debug("d")

        XCTAssertEqual(sink.lines.count, 2)
        XCTAssertTrue(sink.lines[0].contains("ERROR") && sink.lines[0].contains("e"))
        XCTAssertTrue(sink.lines[1].contains("INFO") && sink.lines[1].contains("i"))
    }

    func testLevelFiltering_DebugLevelKeepsAll() {
        let sink = MemoryLogSink()
        let logger = DTLogger(sinks: [sink], level: .debug)

        logger.error("e")
        logger.info("i")
        logger.debug("d")

        XCTAssertEqual(sink.lines.count, 3)
    }

    func testContextAppearsInLine() {
        let sink = MemoryLogSink()
        let logger = DTLogger(sinks: [sink], level: .debug)

        logger.info("switching", context: "Coordinator")

        XCTAssertTrue(sink.joined.contains("[Coordinator] switching"))
    }

    func testSetLevelTakesEffectImmediately() {
        let sink = MemoryLogSink()
        let logger = DTLogger(sinks: [sink], level: .debug)

        logger.debug("before")
        logger.setLevel(.error)
        logger.debug("after")

        XCTAssertEqual(sink.lines.count, 1)
        XCTAssertTrue(sink.joined.contains("before"))
    }

    func testFileSinkWritesAndRotates() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dt-logs-\(UUID().uuidString)", isDirectory: true)
        let logURL = dir.appendingPathComponent("DisplayTuner.log")
        defer { try? FileManager.default.removeItem(at: dir) }

        let sink = FileLogSink(url: logURL, maxBytes: 128, rotatedCount: 2)
        let logger = DTLogger(sinks: [sink], level: .debug)

        // 每行 ~50 字节,写 20 行必然触发轮转
        for index in 0..<20 {
            logger.info("rotation probe line \(index)")
        }

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: logURL.path), "当前日志文件应存在")
        XCTAssertTrue(fm.fileExists(atPath: logURL.path + ".1"), "轮转文件 .1 应存在")

        let content = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertFalse(content.isEmpty, "当前文件应有内容")

        // 轮转不应无限累积
        XCTAssertFalse(fm.fileExists(atPath: logURL.path + ".3"))
    }

    func testLogLevelDecodeSafelyFallsBack() {
        XCTAssertEqual(LogLevel.decodeSafely(99), .info)
        XCTAssertEqual(LogLevel.decodeSafely(0), .error)
        XCTAssertEqual(LogLevel.decodeSafely(2), .debug)
    }

    func testPrivacyRedactor() {
        XCTAssertEqual(PrivacyRedactor.shortHash("abc"), PrivacyRedactor.shortHash("abc"))
        XCTAssertNotEqual(PrivacyRedactor.shortHash("abc"), PrivacyRedactor.shortHash("abd"))
        XCTAssertEqual(PrivacyRedactor.describeName(""), "<empty>")
        XCTAssertEqual(PrivacyRedactor.describeName("张三的 iPad"), "name(len=8)")
    }
}
