# DisplayTuner 测试指南

## 快速命令

```bash
make test        # xcodegen generate + xcodebuild test(与 CI 一致,验收命令)
make test-spm    # swift test(SPM 快速内环)

# 单独跑某组
swift test --filter MenuModelBuilderTests
swift test --filter ModeChangeCoordinatorTests
```

CI(`.github/workflows/ci.yml`)在 macOS runner 上依次执行
`swift test --parallel` 与 `scripts/ci-test.sh`(xcodebuild 路径),两个入口跑同一套测试。

## 测试分层

### 单元测试(Tests/DisplayTunerCoreTests/,121+ 用例)

| 测试文件 | 覆盖点 |
|---|---|
| LoggingTests | 级别过滤、文件轮转、脱敏 |
| StableDisplayIDTests | EDID 三元组、serial 缺失回退、跨重连稳定性 |
| SidecarHeuristicTests | 名称/无 EDID/模式形状信号、内置屏排除、误判防护 |
| DisplayCatalogTests | 0/1/多显示器、分类优先级、模式去重、HiDPI、安全标志、日志脱敏 |
| ModeRankerTests | HiDPI 优先、Sidecar 4:3 加分、刷新率舒适区、隔行惩罚、稳定排序、过滤组合、当前模式保留、无更高模式判定 |
| ModeChangeCoordinatorTests | 成功/确认保留、超时回滚、应用失败、幂等(重复超时/确认后超时)、取代、回滚失败不悬挂 |
| CoreGraphicsDisplayModeControllerTests | 真实控制器的安全失败路径(不在线显示器、不可用模式) |
| ConfigStoreTests | 读写 roundtrip、损坏备份回退、字段级容错、导出导入、版本拒绝 |
| SidecarEnhancerTests | 私有符号探测(库缺失/符号缺失)、隐藏模式 diff、降级公共 API |
| MenuModelBuilderTests | 菜单结构、当前模式 ✓、分组顺序、Sidecar 提示、开关状态、过滤器勾选、增强分组 |
| TunerViewModelTests | 刷新、选择路由、确认才持久化/回滚不持久化、自动恢复三态、全局开关、实验开关联动 |
| CoreGraphicsDisplayServiceTests 等 live | 真实 CG 只读枚举(无副作用,CI 常开) |

**Mock 体系**(`Support/Mocks.swift`):`MockDisplayService` /
`MockDisplayModeController` / `MockConfigStore` / `MockLoginItem` /
`MockCountdownScheduler`(同步触发超时)/ `OutcomeRecorder`,另有
`StubSymbolLookup` / `StubDisplayService` 验证私有 API 降级。

### 集成测试(LiveDisplayIntegrationTests.swift,环境门控)

| 环境变量 | 允许的行为 |
|---|---|
| (未设置) | 集成测试全部 XCTSkip |
| `DISPLAYTUNER_RUN_LIVE_TESTS=1` | 真实 macOS **只读**枚举,打印每台显示器与模式 |
| `DISPLAYTUNER_RUN_DANGEROUS_TESTS=1` | **真实切换**非主屏模式并验证倒计时回滚闭环(需有人在场、副屏可短暂黑屏) |

```bash
# 只读枚举(安全)
DISPLAYTUNER_RUN_LIVE_TESTS=1 swift test --filter LiveDisplayIntegrationTests

# 危险切换(仅连接了可承受黑屏的副屏时!)
DISPLAYTUNER_RUN_DANGEROUS_TESTS=1 swift test --filter testDangerousApplyAndRollbackOnSecondaryDisplay

# 播种验收(Sidecar 已连接时)
DISPLAYTUNER_RUN_DANGEROUS_TESTS=1 swift test --filter LiveSeedingIntegrationTests
```

## 真机行为归档(2026-09-28 全天实验,v1.0 设计依据)

### 边栏几何:模式表是实时阶梯,不是静态清单

iPad 边栏显示/隐藏会让 Sidecar 的整个模式家族原位互换(锚 1180×820 ↔
1116×820,顶档 2360×1640 ↔ 2232×1640;宽度差 = 64pt 边栏 @2x)。持久层
(`/Library/Preferences/com.apple.windowserver.displays.plist`,注意 plutil
输出为 `=>` 格式)两个家族记录俱在 —— 持久的是能力,阶梯由会话几何再生。
**推论**:断言"档数/具体档位"的测试随边栏状态 flake,断言必须用面积相对
关系表达;Sidecar 的 serialNumber 同因边栏状态漂移,v1.0 稳定 ID 对 Sidecar
改用 vendor+model。

### "切档变糊"最终定性:2x 渲染是系统私有状态

同一逻辑档(如 1180×820)存在 1x/2x 两种实际渲染倍率:2x(backing 2360×1640)
字体清晰,1x(backing 1180×820 再拉伸)发虚。**2x 状态不作为模式条目暴露** ——
含 kCGDisplayShowDuplicateLowResolutionModes 的完整枚举里也不存在 2x 条目,
公共 API 四条路径全部无法到达:选条目(无条目)、configure 前变体升级
(无变体)、CGRestorePermanentDisplayConfiguration(恢复的是调用方写入的
永久档)、镜像微操(不触发重协商)。只有系统自身路径(控制中心切换边栏、
系统设置操作缩放)落在 2x。用户策略:要清晰用 2360×1640 档(与清晰 820p
物理像素完全相同);要"清晰的 820p"切档后在控制中心切一次边栏。同尺寸
HiDPI 收敛(见 31eef6f)保留 —— 对真有 1x/2x 双条目的显示器是正确防御。

### v0.2 线遗留的创建类怪癖(历史,详见 main 分支)

5120 framebuffer 上限(模式物理宽 >5120 整表静默丢弃)、HiDPI 声明语义、
镜像播种持久化机理、v0.2.2 起分辨率折半与 v0.2.5/2.6 创建回归 ——
均已随 v1.0 重写搁置,完整归档在 main 分支 TESTING.md。

## 手动验收清单

1. `make build && make run` —— 应用启动后:
   - [ ] 菜单栏出现显示器图标;
   - [ ] 无 Dock 图标(LSUIElement + .accessory);
   - [ ] 无任何窗口;
2. 点击菜单栏图标:
   - [ ] 显示"当前显示器:…"概览与显示器列表;
   - [ ] 内置/外接/Sidecar(连接 iPad 随航时)正确识别,主屏带"主屏"徽标;
3. 展开副屏子菜单:
   - [ ] 当前模式有 ✓ 且不可再点;
   - [ ] 推荐模式在前、其他模式在后;
   - [ ] 过滤三项可叠加,当前模式不会被过滤掉;
4. 点击一个新模式:
   - [ ] 弹出系统确认框,显示新旧模式与倒计时;
   - [ ] 点"保留更改" → 模式保留,重启应用/重连显示器后自动恢复;
   - [ ] 不操作等 10 秒 → 自动还原,确认框收起;
   - [ ] 点"还原" → 立即还原;
   - [ ] 对主屏操作时确认框有 ⚠️ 额外警告;
5. Sidecar 场景(连 iPad):
   - [ ] Sidecar 显示器带徽标,HiDPI 模式排在前面;
   - [ ] 若系统未暴露更高模式,显示"当前随航连接未提供更高分辨率模式";
   - [ ] 打开"实验性 Sidecar 增强" → 菜单显示探测状态(如"未找到私有符号"),
        若揭示出隐藏模式则出现"增强模式(实验)"分组;
6. 全局项:
   - [ ] 自动恢复上次配置开关持久化;
   - [ ] 日志级别切换后,"打开日志文件"能定位到
         `~/Library/Application Support/DisplayTuner/logs/DisplayTuner.log`,
         日志内容无序列号/设备名;
   - [ ] 开机启动:App 在 /Applications 且签名有效时可注册成功(开发期可能失败,如实反映);
7. 命令行:
   - [ ] `DisplayTuner --export-config /tmp/a.json` 退出码 0,文件为 JSON;
   - [ ] `DisplayTuner --import-config /tmp/a.json` 退出码 0,配置生效;
8. 拔掉副屏再重连:
   - [ ] 菜单自动刷新,无崩溃,自动恢复按稳定 ID 生效(模式仍可用时)。

## 已知测试限制

- 单元测试**绝不切换**真实显示器;真实控制器的测试只覆盖必然失败且无副作用的路径;
- Sidecar 相关逻辑用 fixture 模拟,真实 Sidecar 判定依赖现场验收(第 5 项);
- CI runner 无物理副屏,危险集成测试只能在本地人肉环境跑。
