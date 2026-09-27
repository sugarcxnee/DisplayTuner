import Foundation
import Darwin
import DisplayTunerCore

/// 命令行参数处理结果。
enum CLIOutcome {
    case continueRunning
    case exit(Int32)
}

/// 支持 `--export-config <path>` / `--import-config <path>`(规格 3.5),
/// 处理完直接退出,不启动菜单栏应用。核心逻辑复用 ConfigStore。
enum CommandLineHandler {

    static func handle(_ args: [String], store: ConfigStore) -> CLIOutcome {
        var index = 1
        while index < args.count {
            switch args[index] {
            case "--export-config":
                guard index + 1 < args.count else {
                    fputs("--export-config 需要一个路径参数\n", stderr)
                    return .exit(2)
                }
                let path = args[index + 1]
                do {
                    try store.exportConfig(to: URL(fileURLWithPath: path))
                    print("已导出配置到 \(path)")
                    return .exit(0)
                } catch {
                    fputs("导出失败:\(error)\n", stderr)
                    return .exit(1)
                }

            case "--import-config":
                guard index + 1 < args.count else {
                    fputs("--import-config 需要一个路径参数\n", stderr)
                    return .exit(2)
                }
                let path = args[index + 1]
                do {
                    try store.importConfig(from: URL(fileURLWithPath: path))
                    print("已导入配置:\(path)")
                    return .exit(0)
                } catch {
                    fputs("导入失败:\(error)\n", stderr)
                    return .exit(1)
                }

            default:
                break
            }
            index += 1
        }
        return .continueRunning
    }
}
