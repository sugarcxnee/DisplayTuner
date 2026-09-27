import AppKit
import DisplayTunerCore

// DisplayTuner —— 纯菜单栏应用入口。
// 无 WindowGroup/Window/Settings/SwiftUI;LSUIElement=true + .accessory 双保险,无 Dock 图标。

// 命令行模式:--export-config / --import-config,处理完即退出,不进运行循环。
let cliOutcome = CommandLineHandler.handle(
    CommandLine.arguments,
    store: JSONFileConfigStore(logger: DTLogger(sinks: [ConsoleLogSink()]))
)
if case .exit(let code) = cliOutcome {
    exit(code)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
