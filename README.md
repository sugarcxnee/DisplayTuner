# DisplayTuner

macOS 纯菜单栏副屏分辨率调整工具。类似 Display Maestro,但更轻:没有主窗口、没有设置页面、没有欢迎页 —— 所有功能都在点击菜单栏图标弹出的系统菜单里。

核心用途:列出 Mac 当前所有显示器(内置屏 / iPad Sidecar 随航 / 外接显示器),为**副屏**单独选择分辨率、刷新率和 HiDPI 模式,改善 iPad 随航作为扩展屏时"很糊"的问题。

```
菜单栏图标 ▾
├── 当前显示器:内置屏 / Sidecar / 外接屏
├── 刷新显示器
├── ─────────────────────
├── iPad Sidecar(主屏/Sidecar 徽标)— 当前模式摘要
│   ├── 当前模式:1920×1080 HiDPI @ 60Hz
│   ├── 推荐模式 / 其他模式(当前模式带 ✓)
│   ├── 当前随航连接未提供更高分辨率模式(仅当系统确实没给)
│   ├── 增强模式(实验)(开启实验增强且系统揭示了隐藏模式时)
│   ├── 过滤:仅 HiDPI / ≥ 当前分辨率 / 16:10(可叠加)
│   ├── 恢复默认模式
│   └── 高级 ▸ 实验性 Sidecar 增强
├── ─────────────────────
├── ✓ 自动恢复上次配置
├── 实验性 Sidecar 增强(附私有符号探测状态)
├── 开机启动
├── 日志级别:错误 / 信息 / 调试
├── 打开日志文件
├── 关于 DisplayTuner
└── 退出
```

## 系统要求

- macOS 13 Ventura 或更高
- Apple Silicon / Intel 均可
- 无第三方运行时依赖

## 构建与运行

```bash
# 一次性环境准备(需要 Xcode + XcodeGen)
bash scripts/bootstrap.sh

# 生成工程并构建 Release App(ad-hoc 签名,可直接运行)
make build

# 启动(菜单栏应用:无 Dock 图标、无主窗口)
make run
```

构建产物在 `build/Build/Products/Release/DisplayTuner.app`,可拖入 `/Applications` 使用。

### 运行测试

```bash
# 推荐:Xcode 工程测试(与 CI 完全一致)
make test

# 或直接用 Swift Package Manager(快速内环)
make test-spm
```

### 命令行导入导出配置

```bash
DisplayTuner.app/Contents/MacOS/DisplayTuner --export-config ~/backup.json
DisplayTuner.app/Contents/MacOS/DisplayTuner --import-config ~/backup.json
```

## 🎯 iPad 没有高分辨率档?点一次"解锁"

iPad 随航的出厂模式表只含保守报价(如 1180×820),不是硬件不能,是系统没列。
对未解锁的 Sidecar,菜单会显示 **"解锁高分辨率模式(一次性)"**:点击后自动
完成一次"创建高档虚拟屏 → 镜像数秒 → 撤除",系统会把完整模式能力写入
iPad 的持久显示配置 —— 之后 2360×1640 等高档直接出现在菜单,断开重连、
重启都不丢,永远不需要再碰虚拟屏。全程约 5 秒,无确认框,失败自动清理。

## ⚠️ 安全设计:倒计时回滚

**修改显示模式可能造成黑屏、花屏或布局错乱。** DisplayTuner 的每次切换都走同一条安全路径:

1. 应用前保存当前模式;
2. 应用后立即验证实际生效模式与期望一致,不一致自动恢复;
3. 弹出系统确认框,**10 秒内不点"保留更改"就自动还原**;
4. 应用失败立即回滚并记录日志;
5. 显示器拔出 / Sidecar 断开导致回滚失败时,如实记录,不会悬挂状态。

对主显示器的修改会在确认框中给出额外警告。

## 限制说明(请务必阅读)

- **Sidecar 更高分辨率不是无中生有**:可用模式由 iPad 型号、macOS 版本、连接方式(有线/无线)共同决定。系统不暴露更高模式时,菜单会如实显示"当前随航连接未提供更高分辨率模式",DisplayTuner 不会伪造不存在的模式。
- **实验性 Sidecar 增强**默认关闭。其公开部分用 `kCGDisplayShowDuplicateLowResolutionModes` 揭示系统隐藏模式;私有部分仅以 dlopen/dlsym 探测 DisplayServices 框架符号,**探测不到就如实报告并降级到公共 API,当前版本不调用任何写入型私有函数**。
- **App Store**:应用包含私有框架的运行时探测(不直接链接),App Store 审核可能不接受;本工具按自用/开源分发设计。
- **开机启动**使用 `SMAppService`,要求 App 位于稳定位置且签名有效;开发期 ad-hoc 签名注册可能失败,菜单会如实反映状态。
- 回退 ID(无序列号的显示器)在重新插拔后可能变化,自动恢复按"稳定 ID + 模式仍可用"双条件匹配,不会盲切。

## 日志与隐私

- 日志输出到控制台和 `~/Library/Application Support/DisplayTuner/logs/DisplayTuner.log`(自动轮转);
- 菜单"打开日志文件"可直接定位;
- 日志不记录序列号、设备名等隐私信息,显示器仅以"类别 + 短哈希"标识。

## 项目结构

```
DisplayTuner/
  project.yml          # XcodeGen 工程定义(make setup 生成 .xcodeproj)
  Package.swift        # DisplayTunerCore Swift Package(swift test 可用)
  Sources/DisplayTunerCore/   # 全部核心逻辑(Models/Services/Stores/Menu/ViewModels)
  Sources/DisplayTunerApp/    # App 壳(App/MenuBar,仅薄薄一层 AppKit)
  Tests/DisplayTunerCoreTests/
  .github/workflows/ci.yml    # macOS runner 上跑 SPM + xcodebuild 测试
```

详细设计见 [ARCHITECTURE.md](ARCHITECTURE.md),测试与验收见 [TESTING.md](TESTING.md),版本历史见 [CHANGELOG.md](CHANGELOG.md)。许可证:MIT(见 [LICENSE](LICENSE))。
