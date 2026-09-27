# DisplayTuner 架构

## 总览

```
┌─────────────────────────────────────────────────────┐
│ DisplayTunerApp(App 壳,薄 AppKit 层)                │
│  main.swift ─ CLI 处理 → NSApplication(.accessory)   │
│  AppDelegate ─ 依赖装配 + 屏幕变更通知                │
│  MenuBarController ─ NSStatusItem + menuNeedsUpdate  │
│  NSMenuAssembler / ActionRouter ─ 模型 ↔ NSMenu      │
│  SafetyAlertPresenter ─ NSAlert 倒计时确认            │
│  SMAppServiceLoginItem / NSScreenNameProvider        │
└───────────────────────┬─────────────────────────────┘
                        │ 协议注入(依赖倒置)
┌───────────────────────▼─────────────────────────────┐
│ DisplayTunerCore(Swift Package,纯逻辑,可单测)       │
│                                                      │
│  ViewModels: TunerViewModel ── 串联一切              │
│  Menu: MenuModelBuilder ── 纯数据菜单树               │
│  Services:                                            │
│   CoreGraphicsDisplayService ── CG 枚举               │
│   CoreGraphicsDisplayModeController ── CG 应用/回滚   │
│   ModeChangeCoordinator ── 安全倒计时状态机            │
│   ExperimentalSidecarEnhancer ── 增强与降级           │
│   PrivateDisplayServices ── dlopen 私有符号探测        │
│  Stores: JSONFileConfigStore ── 配置持久化            │
│  Models: DisplayInfo / DisplayModeInfo / Config ...   │
└─────────────────────────────────────────────────────┘
```

**分层原则**:AppKit 只出现在 `Sources/DisplayTunerApp`;`DisplayTunerCore` 不
import AppKit(唯一的系统依赖是 CoreGraphics / Foundation / CryptoKit / Darwin),
全部核心逻辑可脱离 GUI 单元测试。

## 关键数据流

### 1. 枚举(每次菜单打开都重跑)

```
menuNeedsUpdate
  → TunerViewModel.refreshDisplays()
  → CoreGraphicsDisplayService.snapshotDisplays()
      CGGetOnlineDisplayList / CGDisplayBounds / CGDisplayRotation /
      CGDisplayIsMain / CGDisplayIsBuiltin / CGDisplayVendorNumber /
      CGDisplayModelNumber / CGDisplaySerialNumber / CGDisplayCopyAllDisplayModes
      (名称由 app 层注入:NSScreen.localizedName)
  → 产出 RawDisplayRecord(纯 DTO,CG 值的直接快照)
  → DisplayCatalog(纯函数):
      StableDisplayID(vendor/model/serial,serial 缺失回退 CGDisplayID)
      SidecarHeuristic(名称 + 无 EDID + 模式形状,加权 ≥3 分判定)
      分类(sidecar > builtin > main > external > unknown)
      模式去重 / HiDPI(像素≥2x)/ 安全标志 / 排序 / 推荐标记
  → [DisplayInfo]
  → MenuModelBuilder.build → MenuModel(纯数据)
  → NSMenuAssembler → NSMenu
```

### 2. 切换与安全回滚

```
点击模式
  → ActionRouter → TunerViewModel.perform(.selectMode)
  → ModeChangeCoordinator.request(mode:on:)
      ├─ 已有 pending?→ 先 revert(superseded)
      ├─ controller.apply:
      │    保存当前模式 → CGBeginDisplayConfiguration
      │    → CGConfigureDisplayWithDisplayMode → CGCompleteDisplayConfiguration
      │    (失败回退 CGDisplaySetDisplayMode)
      │    → 重新读模式验证,不一致自动恢复并抛错
      │    → 返回 AppliedChange(回滚凭据)
      ├─ 成功:启动倒计时(DispatchCountdownScheduler 兜底)
      │    → outcome .applied → SafetyAlertPresenter 弹 NSAlert
      │       (保留更改 / 还原 + 每秒倒计时,common-modes Timer)
      │       → 用户确认:confirmPending(此时才写入持久化配置)
      │       → 用户还原 / 10 秒超时 / 新请求取代:revertPending
      │         → controller.rollback(AppliedChange)
      │         → 回滚失败(显示器已拔)→ 如实上报 rollbackError,状态不悬挂
      └─ 失败:outcome .failed(控制器内部已恢复),不启动倒计时
```

两条倒计时线(UI 的 NSTimer 与协调器的 GCD 兜底)通过 `revertPending` 的
幂等性(guard pending)保证谁先到谁生效、不重复回滚。

### 3. 自动恢复

启动与 `NSApplication.didChangeScreenParametersNotification` 触发:
按稳定 ID 查配置 → 保存的模式仍可用且 ≠ 当前 → 走与手动选择**完全相同**的
带倒计时安全路径,一次只恢复一台。

### 4. 实验性 Sidecar 增强

```
开关(默认关)
  → 开启即 probePrivateStatus()
      PrivateDisplayServices: dlopen(DisplayServices.framework) + dlsym 候选符号
      找到 → 报告符号名;找不到 → "未找到私有符号" + 降级日志
  → refreshExtraModesIfNeeded()
      ExperimentalSidecarEnhancer.extraModes(for: sidecarDisplay)
      公开增强:rawModes(includeHidden: true)
        = CGDisplayCopyAllDisplayModes(id, [kCGDisplayShowDuplicateLowResolutionModes: true])
      与已知列表 diff → 新模式进"增强模式(实验)"分组
```

## 私有 API 隔离(规格 3.4 的硬性要求)

- 私有框架访问**全部**收敛在 `PrivateDisplayServices` 一个类;
- 只用 `dlopen`/`dlsym`(`DylibSymbolLookup`),**不直接链接**任何私有框架,
  构建产物无私有框架的链接依赖;
- `SymbolLookup` 是协议,测试注入 Stub 验证"库缺失/符号缺失"的降级路径;
- 当前版本**只探测不调用**(写入型私有函数的键值语义未经验证,调用有风险),
  探测结果如实显示在菜单与日志中;增强的实际收益来自公开 API 的隐藏模式枚举;
- 默认关闭,App Store 分发风险已在 README 说明。

## 线程模型

- 所有枚举/切换/菜单构建都在主线程(CG 无线程安全保证;菜单天然在主线程);
- 日志与配置文件写入各有一把串行锁;
- 倒计时通过注入的 `CountdownScheduler` 抽象,测试用 Mock 同步触发。

## 为什么 CG 调用被压进两个类

`CoreGraphicsDisplayService`(读)与 `CoreGraphicsDisplayModeController`(写)
是仅有的触碰 CG 的地方,它们输出 `RawDisplayRecord` / `AppliedChange` 这类纯值。
分类、稳定 ID、HiDPI 判定、排序过滤、菜单构建全部是对纯数据的函数,
测试无需 mock 系统框架(真实 CG 的只读 live 测试除外,见 TESTING.md)。

## XcodeGen / SPM 双轨

- `Package.swift` 让 `swift test` 直接可用(快速内环);
- `project.yml` 生成 `DisplayTuner.xcodeproj`:app target(依赖本地 package)
  + 单元测试 bundle 挂在 `DisplayTuner` scheme 上,`make test` / CI 用
  `xcodebuild ... CODE_SIGNING_ALLOWED=NO test`;
- `.xcodeproj` 是生成物,不入库。
