# Changelog

本项目的所有显著变更都记录在此文件里。格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/),
版本遵循 [Semantic Versioning](https://semver.org/spec/v2.0.0.html)。

## [Unreleased]

## [0.2.2] - 2026-09-27

### Fixed

- **修复"虚拟显示器更改不了分辨率,改了马上被切回"**:
  v0.2.0/0.2.1 创建虚拟屏时只注册了单一模式,表外分辨率对系统是非法模式,
  应用后立刻被拉回。现在创建时把 ×1.5/×2/×2.5 全部档位注册进模式表。
- **运行中原地切档**:同一 Sidecar 上再次选择档位 = 模式表内纯 CG 切换,
  不重建虚拟屏、不打断镜像、失败自动切回旧档;菜单"虚拟屏(实验)"运行中
  直接显示三档(当前档 ✓)。真机验证:切档后 2 秒/2.5 秒读数稳定不回弹。
- **镜像期锁定 Sidecar 模式切换**:虚拟屏镜像中,Sidecar 的模式项在菜单里
  禁用并提示"分辨率由虚拟屏决定";`selectMode` 与自动恢复同样拦截/跳过,
  防止与镜像约束互相打架导致的"闪一下切回来"。
- 档位计算改用会话启动时的基准分辨率(镜像期间 Sidecar 实时模式会漂移)。

## [0.2.1] - 2026-09-27

### Fixed

- **修复"虚拟屏不可用,缺少私有类"误报**(v0.2.0 回归):新版 macOS 上
  CoreDisplay 框架实体不在磁盘、dyld 缓存也不按旧路径注册,dlopen 必败;
  但 `CGVirtualDisplay*` 类本来就通过进程依赖链(Foundation/AppKit)加载。
  可用性判定改为以 `NSClassFromString` 类查找为准,dlopen 降级为类不可见时
  的补救手段(双路径尝试);新增回归测试(dlopen 必败时可用性必须为真);
  App 启动日志输出虚拟屏可用性,便于现场排查。

## [0.2.0] - 2026-09-27

### Added

- **虚拟屏增强(Sidecar 工作区扩大,BetterDisplay 式方案)**:
  - Sidecar 的"高级 ▸ 虚拟屏(实验)"子菜单提供基于当前分辨率的
    ×1.5 / ×2(推荐) / ×2.5 三档预设;
  - `CoreDisplayVirtualDisplayFactory`:dlopen CoreDisplay 私有框架后经
    objc_msgSend 运行时调用 `CGVirtualDisplay*` 类族创建任意分辨率虚拟屏,
    不链接私有框架;激活目标模式用公共 CG API(实验确认 applySettings
    只定义模式表,激活需显式切换);
  - 镜像/解除用公共 `CGConfigureDisplayMirrorOfDisplay`;
  - `VirtualDisplayCoordinator`:与模式切换同一套安全模式 —— 10 秒倒计时
    自动还原、操作幂等、启动失败零残留、Sidecar 断开自动停止、
    解除镜像失败如实上报且虚拟屏仍然销毁;
  - NSAlert 倒计时确认框通用化,虚拟屏会话与模式切换共用安全交互;
  - 枚举自动过滤自家虚拟屏;确认保留后按稳定 ID 记录偏好(不做开机自动重建)。
- **Sidecar 识别增强**:EDID vendor/model 的 ASCII 身份编码
  (实测随航屏 vendor="aapl"、model="iPad")作为强信号,
  名称缺失(无 GUI 上下文)时也能正确识别。
- 危险门控集成测试:`testDangerousVirtualDisplayRoundtripOnSidecar`
  真实走一遍创建 → 镜像 → 确认 → 停止闭环。

### Security / Safety

- 虚拟屏私有 API 全部收敛在单个工厂文件,框架/类缺失时如实降级为
  菜单中的"不可用"提示;所有会话结束路径(超时/手动/断开/取代)都保证
  解除镜像并销毁虚拟屏。

## [0.1.0] - 2026-09-27

首个可用版本:纯菜单栏的副屏分辨率调整工具。

### Added

- **纯菜单栏应用**:NSStatusItem + NSMenu,无主窗口/设置页/Dock 图标
  (LSUIElement + .accessory 双保险);菜单每次打开重新枚举,状态不过期。
- **显示器枚举与识别**:CoreGraphics 公共 API 枚举全部在线显示器;
  稳定 ID(vendor/model/serial,serial 缺失回退 CGDisplayID);
  Sidecar 综合启发式识别(名称 + 无 EDID + 模式形状);主屏/内置/外接分类与徽标。
- **模式列表**:HiDPI 识别、安全标志、推荐分组、排序
  (HiDPI 优先 / Sidecar 接近 4:3 加分 / 刷新率舒适区 / 隔行与拉伸惩罚);
  过滤器(仅 HiDPI / ≥ 当前分辨率 / 16:10)可叠加且不影响当前模式;
  Sidecar 无更高模式时如实提示,不伪造。
- **安全切换**:应用前保存旧模式 → CGBegin/CGConfigure/CGComplete 配置
  (CGDisplaySetDisplayMode 兼容回退)→ 应用后验证;
  NSAlert 10 秒倒计时确认,超时/用户取消自动回滚,失败立即回滚;
  双倒计时线幂等;回滚失败(显示器拔出)如实上报不悬挂;主屏修改额外警告。
- **实验性 Sidecar 增强**(默认关):公开部分以
  kCGDisplayShowDuplicateLowResolutionModes 揭示隐藏模式;
  私有部分仅 dlopen/dlsym 探测 DisplayServices 符号,缺失即降级公共 API 并留日志。
- **配置持久化**:按稳定 ID 保存模式偏好与过滤器;自动恢复(与手动切换同一安全路径);
  JSON 导入导出(菜单/命令行 --export-config/--import-config 共用);
  损坏文件备份后回退默认,字段级容错不崩溃。
- **日志**:控制台 + Application Support 轮转文件;三档级别菜单可调;
  不记录序列号/设备名(脱敏)。
- **开机启动**:SMAppService(签名与位置要求见 README)。
- **测试与 CI**:124 个测试(单元 + 只读 live),XCTest + 全套 Mock;
  `make test`(xcodebuild)与 `make test-spm`(swift test)双入口;
  GitHub Actions macOS runner;危险集成测试环境门控。

### Security / Safety

- 默认强制 10 秒倒计时回滚(区间下限 1 秒,不允许 0 秒倒计时的"永久应用");
- 只有用户确认保留的模式才写入持久化配置;
- 不直接链接私有框架;私有 API 默认关闭;App Store 分发风险已在 README 声明。

[Unreleased]: https://github.com/Sugarcxne/DisplayTuner/compare/v0.2.2...HEAD
[0.2.2]: https://github.com/Sugarcxne/DisplayTuner/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/Sugarcxne/DisplayTuner/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/Sugarcxne/DisplayTuner/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/Sugarcxne/DisplayTuner/releases/tag/v0.1.0
