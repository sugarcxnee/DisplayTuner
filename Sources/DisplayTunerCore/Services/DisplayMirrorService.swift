import Foundation
import CoreGraphics

/// 镜像控制(全部为 CoreGraphics 公共 API)。
public protocol DisplayMirrorControlling: AnyObject {
    /// 把 `display` 配置为 `master` 的镜像。
    func mirror(display: UInt32, toMaster master: UInt32) throws
    /// 解除 `display` 的镜像(master 传 kCGNullDirectDisplay)。
    func unmirror(display: UInt32) throws
    /// display 是否处于镜像组(公共 API CGDisplayIsInMirrorSet)。
    func isInMirrorSet(_ display: UInt32) -> Bool
    /// 把显示器切回原生/默认档(播种前置:Sidecar 处于非原生档时,
    /// 虚拟屏的模式表发布与镜像协商都会被系统拒绝)。
    func resetToDefaultMode(displayID: UInt32)
}

public enum MirrorError: Error, Equatable, CustomStringConvertible {
    case failed(String)

    public var description: String {
        switch self {
        case .failed(let detail): return "mirror operation failed: \(detail)"
        }
    }
}

public final class CoreGraphicsMirrorService: DisplayMirrorControlling {

    private let logger: DTLogger

    public init(logger: DTLogger = DTLogger()) {
        self.logger = logger
    }

    public func mirror(display: UInt32, toMaster master: UInt32) throws {
        try configure { config in
            CGConfigureDisplayMirrorOfDisplay(config, display, master)
        }
        logger.info("mirrored display \(display) → master \(master)", context: "Mirror")
    }

    public func unmirror(display: UInt32) throws {
        try configure { config in
            CGConfigureDisplayMirrorOfDisplay(config, display, kCGNullDirectDisplay)
        }
        logger.info("unmirrored display \(display)", context: "Mirror")
    }

    public func isInMirrorSet(_ display: UInt32) -> Bool {
        CGDisplayIsInMirrorSet(display) != 0
    }

    /// 把显示器切回原生/默认档。判据与 `SeedEngine.nativeBase` 一致:
    /// 同逻辑尺寸出现多个变体的档是系统锚定的原生档(真机探测结论)。
    public func resetToDefaultMode(displayID: UInt32) {
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode] else { return }
        let bySize = Dictionary(grouping: modes, by: { Int($0.width) * 10_000 + Int($0.height) })
        let anchoredCandidates: [CGDisplayMode] = bySize.values
            .filter { $0.count >= 2 }
            .compactMap { $0.first }
            .filter { $0.ioFlags & DisplayModeIOFlags.safe != 0 }
        let target: CGDisplayMode? = anchoredCandidates
            .max { $0.width * $0.height < $1.width * $1.height }
            ?? modes.first { $0.ioFlags & DisplayModeIOFlags.defaultFlag != 0 }
            ?? modes
                .filter { $0.width <= 1400 }
                .max { $0.width * $0.height < $1.width * $1.height }
        guard let target = target else { return }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        guard CGConfigureDisplayWithDisplayMode(config, displayID, target, nil) == .success else {
            CGCancelDisplayConfiguration(config)
            return
        }
        _ = CGCompleteDisplayConfiguration(config, .permanently)
        logger.info("reset display \(displayID) to \(Int(target.width))x\(Int(target.height)) for mirroring", context: "Mirror")
    }

    private func configure(_ body: (CGDisplayConfigRef?) -> CGError) throws {
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success else {
            throw MirrorError.failed("begin: \(begin.rawValue)")
        }
        let result = body(config)
        guard result == .success else {
            CGCancelDisplayConfiguration(config)
            throw MirrorError.failed("configure: \(result.rawValue)")
        }
        let complete = CGCompleteDisplayConfiguration(config, .permanently)
        guard complete == .success else {
            throw MirrorError.failed("complete: \(complete.rawValue)")
        }
    }
}
