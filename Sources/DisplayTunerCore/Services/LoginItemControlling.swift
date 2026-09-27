import Foundation

/// 开机启动控制协议。core 不绑定 ServiceManagement;App 壳用 `SMAppService` 实现,
/// 测试注入 Mock。SMAppService 要求 App 已正确签名并位于稳定位置,开发期行为见 README。
public protocol LoginItemControlling: AnyObject {
    /// 当前是否已注册为登录项。
    var isEnabled: Bool { get }
    /// 注册/注销;返回是否成功。
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool
}
