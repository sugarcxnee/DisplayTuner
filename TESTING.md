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
| `DISPLAYTUNER_RUN_DANGEROUS_TESTS=1` | **真实切换**非主屏模式并验证倒计时回滚闭环;**真实创建虚拟屏 + 镜像 Sidecar + 停止**闭环(需有人在场、Sidecar 已连接) |

```bash
# 只读枚举(安全)
DISPLAYTUNER_RUN_LIVE_TESTS=1 swift test --filter LiveDisplayIntegrationTests

# 危险切换(仅连接了可承受黑屏的副屏时!)
DISPLAYTUNER_RUN_DANGEROUS_TESTS=1 swift test --filter testDangerousApplyAndRollbackOnSecondaryDisplay

# 虚拟屏闭环(Sidecar 已连接时)
DISPLAYTUNER_RUN_DANGEROUS_TESTS=1 swift test --filter testDangerousVirtualDisplayRoundtripOnSidecar
```

> **跑危险测试前先退出 DisplayTuner 菜单栏应用。** 应用与测试进程写同一份日志、同时监听屏幕变化:测试把 Sidecar 重置到原生档后,应用侧的自动恢复会立刻把档位拉回去,虚拟屏模式表发布随之被系统拒绝(真机日志证实过此跨进程竞争,极易误判为 WindowServer 异常)。

### 环境状态与"解毒"(2026-09-28 真机探针结论)

虚拟屏创建失败(`not published to CG table` / 私有错误码 1014)**不一定是代码问题**,
用裸创建探针(不碰 Sidecar 的 create→destroy)可以区分:

- 对 Sidecar 做过档位切换(哪怕切回它已在的原生档)之后,虚拟屏创建会被
  WindowServer **持续拒绝**,等待 5 分钟以上也不自愈;
- 历史日志显示 **Sidecar 断开重连**(displayID 变化)后创建恢复;注销重登同理;
- 连续失败的重试本身会加剧该状态——复验失败后不要立刻反复重试,
  先重连 Sidecar 再试。

因此播种/虚拟屏失败时按此顺序排查:① app 是否退出(跨进程自扰) →
② 裸创建探针(能力是否被拒) → ③ 重连 Sidecar 解毒 → ④ 再跑完整流程。

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
5. 虚拟屏(连 iPad):
   - [ ] Sidecar 的"高级 ▸ 虚拟屏(实验)"出现三档预设(基于当前分辨率 ×1.5/×2/×2.5);
   - [ ] 选一档 → 弹确认框 → 保留后 iPad 显示镜像、工作区变大,菜单显示"运行中";
   - [ ] 不确认等 10 秒 → 自动停止恢复;
   - [ ] "停止虚拟屏"或拔掉 iPad → 虚拟屏销毁,菜单不残留;
   - [ ] 虚拟屏自身不出现在显示器列表里。
6. Sidecar 场景(连 iPad):
   - [ ] Sidecar 显示器带徽标,HiDPI 模式排在前面;
   - [ ] 若系统未暴露更高模式,显示"当前随航连接未提供更高分辨率模式";
   - [ ] 打开"实验性 Sidecar 增强" → 菜单显示探测状态(如"未找到私有符号"),
        若揭示出隐藏模式则出现"增强模式(实验)"分组;
7. 全局项:
   - [ ] 自动恢复上次配置开关持久化;
   - [ ] 日志级别切换后,"打开日志文件"能定位到
         `~/Library/Application Support/DisplayTuner/logs/DisplayTuner.log`,
         日志内容无序列号/设备名;
   - [ ] 开机启动:App 在 /Applications 且签名有效时可注册成功(开发期可能失败,如实反映);
8. 命令行:
   - [ ] `DisplayTuner --export-config /tmp/a.json` 退出码 0,文件为 JSON;
   - [ ] `DisplayTuner --import-config /tmp/a.json` 退出码 0,配置生效;
9. 拔掉副屏再重连:
   - [ ] 菜单自动刷新,无崩溃,自动恢复按稳定 ID 生效(模式仍可用时)。

## 已知测试限制

- 单元测试**绝不切换**真实显示器;真实控制器的测试只覆盖必然失败且无副作用的路径;
- Sidecar 相关逻辑用 fixture 模拟,真实 Sidecar 判定依赖现场验收(第 5 项);
- CI runner 无物理副屏,危险集成测试只能在本地人肉环境跑。
