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
