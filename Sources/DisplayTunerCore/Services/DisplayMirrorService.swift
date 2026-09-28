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
    /// 把显示器切回默认/原生档(镜像会话遗留的高档会阻碍模式发布与镜像协商)。
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
        do {
            try configure { config in
                CGConfigureDisplayMirrorOfDisplay(config, display, master)
            }
            logger.info("mirrored display \(display) → master \(master)", context: "Mirror")
            return
        } catch {
            // 实验验证的两个失败条件:虚拟屏激活后过早镜像(时序)、
            // Sidecar 停留在镜像不接受的档位(镜像会话遗留的高分辨率档)。
            // Fallback:把成员显示器切回默认/原生档,稳定后重试。
            logger.info(
                "mirror failed (\(error)); resetting display \(display) to default mode and retrying",
                context: "Mirror"
            )
        }
        resetToDefaultMode(displayID: display)
        Thread.sleep(forTimeInterval: 1.0)
        try configure { config in
            CGConfigureDisplayMirrorOfDisplay(config, display, master)
        }
        logger.info("mirrored display \(display) → master \(master) after fallback", context: "Mirror")
    }

    /// 把显示器切回原生/默认档。判据与 `VirtualDisplayPresets.nativeBase` 一致:
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

    public func unmirror(display: UInt32) throws {
        try configure { config in
            CGConfigureDisplayMirrorOfDisplay(config, display, kCGNullDirectDisplay)
        }
        logger.info("unmirrored display \(display)", context: "Mirror")
    }

    public func isInMirrorSet(_ display: UInt32) -> Bool {
        CGDisplayIsInMirrorSet(display) != 0
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
