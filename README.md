# DisplayTuner

macOS 纯菜单栏副屏分辨率调整工具。类似 Display Maestro,但更轻:没有主窗口、设置页面和欢迎页,所有功能都在菜单栏图标的菜单里。

用于列出当前所有显示器(内置屏、iPad Sidecar 随航、外接显示器),给副屏单独选择分辨率、刷新率和 HiDPI 模式。写这个工具最初就是为了解决 iPad 随航做扩展屏时画面发虚的问题。

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

## iPad 没有高分辨率档?点一次"解锁"

iPad 随航出厂的模式表只有保守报价(如 1180×820),硬件本身支持更多。对未解锁的 Sidecar,菜单里有一项"解锁高分辨率模式(一次性)":点击后自动创建一个高分辨率虚拟屏、镜像几秒再撤掉,系统会把完整的模式能力写进 iPad 的持久显示配置。之后 2360×1640 这些高档直接出现在菜单里,断开重连、重启都不会丢,不用再重复这个操作。全程约 5 秒,无需确认,失败自动清理。

## 安全机制:倒计时回滚

修改显示模式可能造成黑屏、花屏或布局错乱,所以每次切换都走同一条安全路径:

1. 应用前保存当前模式;
2. 应用后立即验证实际生效模式与期望一致,不一致自动恢复;
3. 弹出系统确认框,10 秒内不点"保留更改"就自动还原;
4. 应用失败立即回滚并记录日志;
5. 显示器拔出或 Sidecar 断开导致回滚失败时,只记录日志,不会悬挂。

对主显示器的修改会在确认框中给出额外警告。

## 限制

- Sidecar 的高分辨率档不能无中生有:可用模式由 iPad 型号、macOS 版本和连接方式(有线/无线)共同决定。系统不暴露更高模式时,菜单会显示"当前随航连接未提供更高分辨率模式",不会伪造不存在的选项。
- **实验性 Sidecar 增强**默认关闭。公开部分用 `kCGDisplayShowDuplicateLowResolutionModes` 揭示系统隐藏的模式;私有部分只用 dlopen/dlsym 探测 DisplayServices 框架符号,探测不到就报告并退回公共 API,当前版本不调用任何写入型私有函数。
- **App Store**:应用包含私有框架的运行时探测(不直接链接),App Store 审核可能不接受;本工具按自用和开源分发设计。
- **开机启动**使用 `SMAppService`,要求 App 位于稳定位置且签名有效;开发期 ad-hoc 签名注册可能失败,菜单会显示实际状态。
- 回退 ID(无序列号的显示器)在重新插拔后可能变化。自动恢复按"稳定 ID + 模式仍可用"双条件匹配,不会盲切。

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
