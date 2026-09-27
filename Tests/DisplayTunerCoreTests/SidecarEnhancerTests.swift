import XCTest
@testable import DisplayTunerCore

/// 可编程的符号查找 Stub:dlopen/dlsym 结果全部可控。
final class StubSymbolLookup: SymbolLookup {
    var libraryAvailable = true
    var availableSymbols: Set<String> = []
    private(set) var openedPaths: [String] = []

    func openLibrary(path: String) -> UnsafeMutableRawPointer? {
        openedPaths.append(path)
        return libraryAvailable ? UnsafeMutableRawPointer(bitPattern: 0x1234) : nil
    }

    func symbol(handle: UnsafeMutableRawPointer, name: String) -> UnsafeMutableRawPointer? {
        availableSymbols.contains(name) ? UnsafeMutableRawPointer(bitPattern: 0x5678) : nil
    }
}

/// 可编程的枚举服务 Stub:隐藏模式列表可控。
final class StubDisplayService: DisplayService {
    var displays: [DisplayInfo] = []
    var hiddenRawModes: [UInt32: [RawModeRecord]] = [:]
    private(set) var rawModesCalls: [(displayID: UInt32, includeHidden: Bool)] = []

    func snapshotDisplays() -> [DisplayInfo] { displays }

    func rawModes(for displayID: UInt32, includeHidden: Bool) -> [RawModeRecord] {
        rawModesCalls.append((displayID, includeHidden))
        return includeHidden ? (hiddenRawModes[displayID] ?? []) : []
    }
}

final class PrivateDisplayServicesTests: XCTestCase {

    func testProbeReportsAllMissingWhenLibraryUnavailable() {
        let stub = StubSymbolLookup()
        stub.libraryAvailable = false
        let services = PrivateDisplayServices(
            lookup: stub,
            logger: DTLogger(sinks: [MemoryLogSink()])
        )

        let report = services.probe()

        XCTAssertFalse(report.isAvailable)
        XCTAssertEqual(report.missingSymbols, PrivateDisplayServices.candidateSymbols)
        XCTAssertEqual(report.statusDescription, "未找到私有符号")
        XCTAssertEqual(stub.openedPaths, [PrivateDisplayServices.displayServicesPath])
    }

    func testProbeReportsFoundAndMissingSymbols() {
        let stub = StubSymbolLookup()
        stub.availableSymbols = ["DisplayServicesGetIntegerValue"]
        let services = PrivateDisplayServices(
            lookup: stub,
            logger: DTLogger(sinks: [MemoryLogSink()])
        )

        let report = services.probe()

        XCTAssertTrue(report.isAvailable)
        XCTAssertEqual(report.foundSymbols, ["DisplayServicesGetIntegerValue"])
        XCTAssertEqual(report.missingSymbols.count, PrivateDisplayServices.candidateSymbols.count - 1)
        XCTAssertTrue(report.statusDescription.contains("1 个"))
    }
}

final class SidecarEnhancerTests: XCTestCase {

    private func makeEnhancer(
        displays: [DisplayInfo],
        hidden: [UInt32: [RawModeRecord]],
        symbolStub: StubSymbolLookup = StubSymbolLookup()
    ) -> (ExperimentalSidecarEnhancer, StubDisplayService) {
        let service = StubDisplayService()
        service.displays = displays
        service.hiddenRawModes = hidden
        let enhancer = ExperimentalSidecarEnhancer(
            displayService: service,
            privateServices: PrivateDisplayServices(
                lookup: symbolStub,
                logger: DTLogger(sinks: [MemoryLogSink()])
            ),
            logger: DTLogger(sinks: [MemoryLogSink()])
        )
        return (enhancer, service)
    }

    func testExtraModesReturnsOnlyNewModes() {
        let sidecar = DisplayCatalog.display(from: Fixtures.sidecarDisplay(modes: [
            Fixtures.mode(1920, 1080),
        ]))
        let hidden: [UInt32: [RawModeRecord]] = [
            sidecar.displayID: [
                Fixtures.mode(1920, 1080),          // 已知,应排除
                Fixtures.mode(1024, 768, hidpi: false),  // 新模式
                Fixtures.mode(2048, 1536),               // 新 HiDPI 模式
            ]
        ]
        let (enhancer, service) = makeEnhancer(displays: [sidecar], hidden: hidden)

        let extras = enhancer.extraModes(for: sidecar)

        XCTAssertEqual(extras.map(\.modeKey), ["2048x1536@60-hidpi", "1024x768@60"])
        XCTAssertEqual(service.rawModesCalls.count, 1)
        XCTAssertTrue(service.rawModesCalls[0].includeHidden, "必须以隐藏模式选项枚举")
    }

    func testExtraModesEmptyWhenNothingNew() {
        let external = DisplayCatalog.display(from: Fixtures.externalDisplay())
        let hidden: [UInt32: [RawModeRecord]] = [
            external.displayID: external.modes.map { raw in
                RawModeRecord(
                    width: raw.width, height: raw.height,
                    pixelWidth: raw.pixelWidth, pixelHeight: raw.pixelHeight,
                    refreshRate: raw.refreshRate, ioFlags: raw.ioFlags
                )
            }
        ]
        let (enhancer, _) = makeEnhancer(displays: [external], hidden: hidden)

        XCTAssertEqual(enhancer.extraModes(for: external), [])
    }

    func testExtraModesEmptyWhenSystemExposesNothing() {
        let sidecar = DisplayCatalog.display(from: Fixtures.sidecarDisplay())
        let (enhancer, _) = makeEnhancer(displays: [sidecar], hidden: [:])

        XCTAssertEqual(enhancer.extraModes(for: sidecar), [], "系统不暴露就如实返回空,不伪造")
    }

    func testProbeDegradesGracefullyWhenPrivateSymbolsMissing() {
        let sink = MemoryLogSink()
        let stub = StubSymbolLookup()
        stub.libraryAvailable = false
        let service = StubDisplayService()
        let enhancer = ExperimentalSidecarEnhancer(
            displayService: service,
            privateServices: PrivateDisplayServices(
                lookup: stub,
                logger: DTLogger(sinks: [sink], level: .debug)
            ),
            logger: DTLogger(sinks: [sink], level: .debug)
        )

        let report = enhancer.probePrivateStatus()

        XCTAssertFalse(report.isAvailable)
        XCTAssertEqual(enhancer.lastProbeReport, report)
        XCTAssertTrue(sink.joined.contains("degraded"), "降级必须留日志")
        XCTAssertTrue(sink.joined.contains("public API"), "明确降级到公共 API")
    }

    func testExtraModesStillWorkWhenPrivatePartUnavailable() {
        // 私有符号不可用时,公开增强(隐藏模式枚举)必须照常工作
        let stub = StubSymbolLookup()
        stub.libraryAvailable = false
        let sidecar = DisplayCatalog.display(from: Fixtures.sidecarDisplay(modes: [
            Fixtures.mode(1920, 1080),
        ]))
        let service = StubDisplayService()
        service.displays = [sidecar]
        service.hiddenRawModes = [sidecar.displayID: [Fixtures.mode(1280, 720, hidpi: false)]]
        let enhancer = ExperimentalSidecarEnhancer(
            displayService: service,
            privateServices: PrivateDisplayServices(lookup: stub, logger: DTLogger(sinks: [MemoryLogSink()])),
            logger: DTLogger(sinks: [MemoryLogSink()])
        )
        enhancer.probePrivateStatus()

        XCTAssertEqual(enhancer.extraModes(for: sidecar).map(\.modeKey), ["1280x720@60"])
    }
}

/// 真实 CG 只读验证:隐藏模式枚举在真实显示器上不崩溃。
final class SidecarEnhancerLiveTests: XCTestCase {

    func testLiveHiddenModeEnumerationDoesNotCrash() {
        let service = CoreGraphicsDisplayService(logger: DTLogger(sinks: [MemoryLogSink()]))
        let mainID = CGMainDisplayID()
        let hidden = service.rawModes(for: mainID, includeHidden: true)
        let normal = service.rawModes(for: mainID, includeHidden: false)
        XCTAssertGreaterThanOrEqual(hidden.count, normal.count,
                                     "隐藏枚举至少包含默认列表(通常更多)")
    }
}
