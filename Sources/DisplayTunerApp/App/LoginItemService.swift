import Foundation
import AppKit
import ServiceManagement
import DisplayTunerCore

/// `SMAppService.mainApp`(macOS 13+)实现的开机启动。
/// 注意:要求 App 位于固定位置且已正确签名;开发期 ad-hoc 签名/频繁移动位置时
/// 注册可能失败 —— 失败会被如实记录并反映在菜单状态上,不影响其他功能。
final class SMAppServiceLoginItem: LoginItemControlling {

    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            return false
        }
    }
}

/// 用 NSScreen(公共 API)提供显示器名称,注入 core 的枚举服务。
/// 匹配方式:NSScreen.deviceDescription["NSScreenNumber"] == CGDirectDisplayID。
struct NSScreenNameProvider {
    func name(for displayID: CGDirectDisplayID) -> String? {
        NSScreen.screens.first { screen in
            screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? CGDirectDisplayID == displayID
        }?.localizedName
    }
}
