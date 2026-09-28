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
| HiDPIModeCacheTests | 影子 HiDPI 机制纯逻辑:ShadowModeMerge 注入/去重、注入后的目录收敛与当前档传播、sizeKey 跨倍率匹配 |
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

# 影子 HiDPI 端到端验收(Sidecar 已连接且处于清晰态时:切走→切回自动落 2x)
DISPLAYTUNER_RUN_DANGEROUS_TESTS=1 swift test --filter LiveShadowHiDPIIntegrationTests
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

### "切档变糊"最终定性(修订):2x 对象不进枚举,但对象引用可配置

同一逻辑档(如 1180×820)存在 1x/2x 两种实际渲染倍率:2x(backing 2360×1640)
字体清晰,1x(backing 1180×820 再拉伸)发虚。**2x 模式对象由系统在 framebuffer
重建时(边栏切换、连接建立)内部合成,从不作为模式条目暴露** —— 清晰态下带
`kCGDisplayShowDuplicateLowResolutionModes` 的完整枚举也全部 1x(14 条,实测)。

早期结论"公共 API 全部无法到达"已被**第五条路径**推翻(2026-09-28 晚,
`/tmp/exp_retained2x.swift`):**持有清晰态 `CGDisplayCopyDisplayMode` 返回的
2x 对象引用,在糊态下直接 `CGConfigureDisplayWithDisplayMode` → success,
读回 2x,清晰态经纯程序路径恢复**。对象跨档位切换仍有效;恢复后 WindowServer
持久层记录 `Scale => 2`。四条旧路径(选条目/变体升级/Restore/镜像微操)
失败的原因一致:它们都只能引用"枚举中的条目",而 2x 对象不在其中。

**修复机制(影子 HiDPI 缓存,`HiDPIModeCache`)**:
- 凡读到某显示器当前档为 HiDPI 即捕获对象引用(它必然刚由系统路径设置);
- 快照时把影子条目元数据注入模式表(`ShadowModeMerge`),经既有同尺寸
  HiDPI 收敛后成为菜单条目 —— 勾选正确、直接可点选;
- apply/rollback 的目标查找在枚举未命中时回退影子对象;configure 失败或
  验证未落在 2x 时自动失效该缓存条目(防边栏家族互换后的陈旧对象)。

**残余限制**:影子对象无法持久化,进程退出即失。冷启动若系统未先到过
清晰态,缓存为空、如实降级(菜单不出现 HiDPI 条目)。触发系统路径的
已知事件:边栏切换、Sidecar 断开重连(**重连后系统自动落原生档 2x,实测**)。
程序触发探索结论:`CGConfigureDisplayRotation` 非公开 API;SkyLight /
DisplayServices 无旋转/HiDPI 写入符号(dlsym 全部落空);杀
SidecarDisplayAgent 会断开 Sidecar 会话(agent 自动重启但显示器不自动恢复,
需要 iPad 重新发起);解除镜像恢复的是持久档而非 2x 原生(从顶档实测);
播种流程在已解锁机器走 alreadyUnlocked 跳过,无从作为触发器 —— 均不可用,
连接建立(且上次持久档为 2x 时)与边栏切换是仅有的系统路径入口。
镜像协商档陷阱(实测):挂镜像期间 `CGDisplayCopyDisplayMode` 返回主屏的
2x 协商档,会被影子缓存误捕获 —— 捕获必须排除镜像态
(`CGDisplayIsInMirrorSet == 0`)。

**边栏切换"回清晰"是条件性的 + 持久档毒化(2026-09-28 深夜实测)**:
边栏切换时系统设回原生档,但**倍率取自 WindowServer 配置集
(`com.apple.windowserver.displays.plist`)中该显示器的惯用记录,不是无条件
2x**。程序 configure 1x 档会把惯用记录写成 Scale=1 —— 当天实验序列
(live 测试切顶档、autoRestore 回滚)把 229 个 Sidecar 槽中的 178 个写成
(820p, Scale=1) 后,边栏切换永久落糊,任何切换都救不回;**重启 Mac 恢复**
(系统启动建立 Sidecar 会话时重写默认 2x —— 即日常"连上就清晰"的来源)。
推论:产品对 Sidecar 的 configure 必须经影子升级落 2x(已实现),否则一次
1x 持久化就会毒化用户的边栏切换;系统设置对随航屏没有分辨率 UI
(正是本项目存在的理由),用户侧恢复手段只有重启/注销。
候选防再发策略(未实施):影子缓存不可用且目标为原生档时,选顶档
(1x 点对点,清晰但 UI 小)而非 1x 原生档,至少不把惯用档毒化成"糊 820p"。

**端到端终验(2026-09-28 22:28,重启恢复清晰态后)**:
`DISPLAYTUNER_RUN_DANGEROUS_TESTS=1 swift test --filter LiveShadowHiDPIIntegrationTests`
通过 —— `1180x820@60-hidpi → 2360x1640@60(切走)→ 1180x820@60-hidpi
(切回自动落 2x)`,物理渲染像素与清晰态一致。修复闭环成立。

**Sidecar 虚拟 EDID(2026-09-28 实测)**:连接后 vendor/model 恰为 ASCII
`"aapl"`(0x6161706C)/`"iPad"`(0x69506164),已加入启发式最强信号;
旧观察的"全 0 EDID"形态也保留覆盖。另:CGDirectDisplayID 会随重连漂移
(实测 115 → 118),印证稳定 ID 不得依赖 displayID。

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
