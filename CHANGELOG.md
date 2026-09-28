# 更新日志

## 1.0.0 (2026-09-28)

基于 v0.1.0 干净核心的重写,虚拟屏常驻功能移除,播种为唯一解锁路径。

### 新增
- **解锁高分辨率模式(一次性)**:对未解锁的 Sidecar,菜单提供播种入口。
  引擎自动完成"创建高档虚拟屏 → 镜像 → 等系统写入持久模式表 → 撤除",
  之后高档直接出现在菜单,断开重连/重启均保留。
- 播种引擎的流程纪律全部来自 2026-09-28 的真机对照实验(详见 TESTING.md):
  单模式表 + 逻辑尺寸声明(实证配置)、非原生档先回原生、失败路径残影守卫、
  可注入时钟(单测毫秒级)。

### 移植(v0.2 线验证过的核心修复)
- 自动恢复让位于确认窗口内的用户切换;
- 自动恢复冷却/放弃阈值 + 回滚清除偏好(消除弹窗循环);
- 屏幕参数变化防抖 1.5 秒。

### 修复(2026-09-28 边栏几何发现)
- 播种目标档精确 ×2(旧 rounded10 在边栏显示态会算出 2230,偏离真实边界
  2232 达 2px,目标永不命中);
- 「已解锁」判定维持面积相对语义(边栏两态结论一致),不变量已写入文档;
- Sidecar 稳定 ID 改用 vendor+model(其 serialNumber 随边栏状态漂移,曾致
  同一台 iPad 出现两个身份、autoRestore 偏好分裂);
- 验收文档(VM 方案/TESTING)改用面积相对判据,消除边栏态 flake。

### 移除
- 常驻虚拟屏会话(高级 ▸ 虚拟屏):其价值已被播种完全取代,且 v0.2.2 起
  积累了分辨率折半、残影堆积、创建回归等多层问题。机理与教训归档于
  main 分支的 TESTING.md。

---

# Changelog

本项目的所有显著变更都记录在此文件里。格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/),
版本遵循 [Semantic Versioning](https://semver.org/spec/v2.0.0.html)。

## [Unreleased]

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

[Unreleased]: https://github.com/Sugarcxne/DisplayTuner/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Sugarcxne/DisplayTuner/releases/tag/v0.1.0
