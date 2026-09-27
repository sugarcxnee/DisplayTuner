import XCTest
@testable import DisplayTunerCore

final class ConfigStoreTests: XCTestCase {

    private var directory: URL!
    private var configFile: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dt-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        configFile = directory.appendingPathComponent("config.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore(file: URL? = nil) -> JSONFileConfigStore {
        JSONFileConfigStore(fileURL: file ?? configFile, logger: DTLogger(sinks: [MemoryLogSink()]))
    }

    // MARK: - 默认值与读写

    func testFreshStoreHasSafeDefaults() {
        let store = makeStore()
        XCTAssertEqual(store.config.version, 1)
        XCTAssertTrue(store.config.autoRestore, "自动恢复默认开启")
        XCTAssertFalse(store.config.experimentalSidecar, "实验性增强默认关闭")
        XCTAssertEqual(store.config.logLevel, .info)
        XCTAssertTrue(store.config.perDisplay.isEmpty)
    }

    func testSavePersistsAndReloadRestores() {
        let store = makeStore()
        var config = store.config
        config.autoRestore = false
        config.experimentalSidecar = true
        config.logLevel = .debug
        config.perDisplay["display-v1-010ae-01234-9abcdef0"] = PerDisplayConfig(
            modeKey: "2560x1440@60-hidpi",
            filters: [.hidpiOnly, .aspect16x10]
        )
        store.save(config)

        // 新实例从磁盘读回
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.config, config)
        XCTAssertEqual(
            reloaded.config.perDisplay["display-v1-010ae-01234-9abcdef0"]?.modeKey,
            "2560x1440@60-hidpi"
        )
        XCTAssertEqual(reloaded.config.perDisplay["display-v1-010ae-01234-9abcdef0"]?.filters,
                       [.hidpiOnly, .aspect16x10])
    }

    func testMissingFileYieldsDefaults() {
        let store = makeStore(file: directory.appendingPathComponent("nonexistent.json"))
        XCTAssertEqual(store.config, DisplayTunerConfig())
    }

    // MARK: - 损坏恢复

    func testCorruptedFileFallsBackToDefaultsAndKeepsBackup() throws {
        try "{ this is not valid json !!!".data(using: .utf8)!.write(to: configFile)

        let store = makeStore()

        XCTAssertEqual(store.config, DisplayTunerConfig(), "损坏配置回退默认,不崩溃")
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("config.corrupt-") }
        XCTAssertEqual(backups.count, 1, "损坏文件应被备份")

        // 损坏文件应已不在原位
        XCTAssertFalse(FileManager.default.fileExists(atPath: configFile.path))

        // 回退后 save 正常工作
        var config = store.config
        config.autoRestore = false
        store.save(config)
        XCTAssertEqual(makeStore().config.autoRestore, false)
    }

    func testPartiallyCorruptedFieldsFallBackIndividually() throws {
        // autoRestore 字段类型错误 → 该字段回退默认 true,其余字段保留
        let json = """
        {"version": 1, "autoRestore": "yes", "experimentalSidecar": true, "logLevel": 2}
        """
        try json.data(using: .utf8)!.write(to: configFile)

        let store = makeStore()

        XCTAssertTrue(store.config.autoRestore)
        XCTAssertTrue(store.config.experimentalSidecar)
        XCTAssertEqual(store.config.logLevel, .debug)
    }

    func testUnknownLogLevelFallsBackToInfo() throws {
        let json = #"{"version": 1, "logLevel": 42}"#
        try json.data(using: .utf8)!.write(to: configFile)

        XCTAssertEqual(makeStore().config.logLevel, .info)
    }

    // MARK: - 导入导出

    func testExportImportRoundtrip() throws {
        let store = makeStore()
        var config = store.config
        config.experimentalSidecar = true
        config.perDisplay["abc"] = PerDisplayConfig(modeKey: "1920x1080@60-hidpi", filters: [.hidpiOnly])
        store.save(config)

        let exportURL = directory.appendingPathComponent("export.json")
        try store.exportConfig(to: exportURL)

        // 另一个目录的新 store 导入
        let otherDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dt-config-other-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: otherDir) }
        let otherStore = JSONFileConfigStore(
            fileURL: otherDir.appendingPathComponent("config.json"),
            logger: DTLogger(sinks: [MemoryLogSink()])
        )
        let imported = try otherStore.importConfig(from: exportURL)

        XCTAssertEqual(imported, config)
        XCTAssertEqual(otherStore.config, config, "导入后立即生效")
        XCTAssertEqual(JSONFileConfigStore(fileURL: otherDir.appendingPathComponent("config.json")).config,
                       config, "导入后已落盘")
    }

    func testImportCorruptedFileThrowsAndKeepsCurrentConfig() throws {
        let store = makeStore()
        var config = store.config
        config.autoRestore = false
        store.save(config)

        let badURL = directory.appendingPathComponent("bad.json")
        try "not json at all".data(using: .utf8)!.write(to: badURL)

        XCTAssertThrowsError(try store.importConfig(from: badURL))
        XCTAssertEqual(store.config, config, "导入失败不影响现有配置")
    }

    func testImportFutureVersionThrows() throws {
        let store = makeStore()
        let futureURL = directory.appendingPathComponent("future.json")
        try #"{"version": 99}"#.data(using: .utf8)!.write(to: futureURL)

        XCTAssertThrowsError(try store.importConfig(from: futureURL)) { error in
            XCTAssertEqual(error as? ConfigImportError, .unsupportedVersion(99))
        }
    }

    func testReloadPicksUpExternalChanges() throws {
        let store = makeStore()
        var config = store.config
        config.logLevel = .debug
        store.save(config)

        // 外部(例如 CLI --import-config)修改了文件
        let external = makeStore()
        var modified = external.config
        modified.experimentalSidecar = true
        external.save(modified)

        store.reload()
        XCTAssertTrue(store.config.experimentalSidecar)
    }
}
