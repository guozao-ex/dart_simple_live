---
generated_from_state_version: 18
---

# 验证

## 当前结果

- 结果: **验收通过，需要你确认**
- 验证情况: **已在实现会话中完成验收**
- 目标周期: 1
- 迭代: 4
- 验证器尝试次数: 1
- 完成时间: 2026-11-16T10:06:48.982Z
- 摘要: 第四轮独立 Verifier 全项通过：A1-A11 均 passed。A10 的合并组 id 单调/ pending 清理、A11 的 220ms 恢复 Timer 幂等均已闭合；A9 的每帧 image budget 与 2480 帧/0 超时 profile 通过（帧产出约 41fps 为环境限制）。

## 验收

| 编号 | 结果 | 来源 | 验收项 | 原因 |
| --- | --- | --- | --- | --- |
| A1 | passed | brief.md | 到达路径不产生排版或位图：连续入队 1000 条滚动弹幕但不推进帧时，Paragraph 与位图构建计数均为 0；一次帧推进只为取得车道的消息构建。 | `_addDanmaku` 只做 hide 判断与 `_queue.push`，到达路径没有 Paragraph/位图构建；生成只发生在 `_tickFrame`→`_spawn`。队列容量 2000 溢出丢最旧并累计 dropped，widget 测试断言 queued=100/spawned=0/cacheMisses=0。 |
| A2 | passed | brief.md | 每帧批量与丢弃：空闲车道 N 条时，一帧最多生成 `min(N, maxSpawnPerFrame)` 条，其余丢弃并计入统计；默认模式同车道不重叠，`massiveMode` 仍允许叠轨。 | `_spawn` 用 spawnBudget=min(freeLanes, imageBudget)，未取得车道的余量全部计入 `_engineDropped`；预算耗尽分支已计入 dropped；默认 freeAt=now+(width+48)/speed 保证同车道不重叠；密集负载测试逐帧断言 spawned 增量≤maxSpawnPerFrame 且前条尾部≤后条 from+0.5；massiveMode 走 allocateMassive。 |
| A3 | passed | brief.md | 等速与车道复用：长度不同的滚动弹幕 px/s 相同；同车道前一条尾部清出右边缘后立即可复用；分配/复用行为有单测覆盖。 | 所有滚动条目共用 speed=viewWidth/durationMs，xAt 与宽度无关；allocate 在尾部清出右边缘的同一毫秒复用车道；lane allocator 7 个单测覆盖复用/rescale/delay/extend/ensureFreeAt/车道数变化。 |
| A4 | passed | brief.md | 连续性与重排：修改滚动速度时在屏弹幕位置不跳变，车道剩余等待按旧/新速度比例缩放；视口变窄时按丢失宽度延迟车道；暂停/恢复后位置与时间连续。 | 变速时 setLayout rescale 剩余等待、变窄时 delay，并用同一 factor 重写 startTick（位置误差<0.5px）；pause 冻结 Ticker 并保留 _lastTick，resume 续算，位置与时间连续。 |
| A5 | passed | brief.md | 位图缓存与所有权：相同文本+样式第二次生成命中缓存且不重复排版，不同样式不串图；淘汰不释放仍在屏的图；改字号/字重/字体/描边/DPR 清空缓存且无 use-after-dispose；稳态缓存不超过 24 MiB。 | 缓存键覆盖文本/颜色/字号/字重/字体/描边/DPR/selfSend/count/mergeCount/isColorful；refs>0 不淘汰；24MiB/512 条；样式/DPR 变化先清条目再 clear，无 use-after-dispose。 |
| A6 | passed | brief.md | 每帧重绘不重建 widget：连续 60 帧只触发 painter 重绘，不重建 CustomPaint、不新建 painter 实例。 | painter 以 `ValueNotifier<int>` 作为 super(repaint:)，tick 只写 notifier 不 setState；60 帧 same CustomPaint identical 断言通过；位置为帧时间纯函数。 |
| A7 | passed | brief.md | 设置与平台回归：字号、字重、字体、描边、区域、速度、不透明度、上下边距、合并开关、顶部/底部/特效弹幕、清屏、切后台行为与改动前等价；`simple_live_app` 与 `simple_live_tv_app` 分析通过，Windows release 构建成功。 | 独立执行三包 dart analyze 全部 No issues；Release app.so 时间晚于本轮源码；字号/字重/字体/描边/区域/速度/不透明度/边距/合并开关/hideX/safeArea/清屏/切后台均接线；TV 调用点未变可编译。 |
| A8 | passed | brief.md | 应用侧洪峰开销：屏蔽关键词列表不变时，处理单条消息不新建 RegExp；聊天自动滚动每帧最多执行一次；对应计数测试通过。 | ShieldPatternCache 仅在 listEquals 变化时编译；FrameCoalescer 同帧去重；测试断言列表不变 rebuilds 不增、10 次 schedule 只 run 1 次。 |
| A9 | passed | brief.md | 帧预算与观感：合成负载下每帧排版/光栅化次数不超过 `maxSpawnPerFrame`；Windows profile 密集房间 60s 的 FrameTiming 摘要显示 UI p95 ≤ 8ms 且无 >16.7ms 的 UI/Raster 帧。 | image budget=maxSpawnPerFrame 覆盖滚动/静态/特效/refit；单帧合并重建测试以 cacheMisses 增量≤8 验证；profile 2480 帧、UI p95 600µs、Raster p95 1101µs、超 16.7ms 为 0，spawned+dropped+merged 与注入量自洽；帧产出约 41fps 属环境限制（用户已同意合成负载）。 |
| A10 | passed | brief.md | 合并计数：同文本 8 秒内重复只保留一个在屏条目并显示 `×N`；计数增加时位图、宽度与车道占用同步更新且位置不跳变；超过 8 秒后重新从 1 计数；关闭开关恢复逐条显示；已有 `count` 的聚合弹幕不参与合并。 | DanmakuMergeProcessor.reset 保留单调 _sequence，mergeChanged 清 merge/pendingMergeCounts/pendingRefits；新组 id 不会命中旧条目；refit 不动 startTick/from，按 extra-gapBefore 精确右移后继并 extend 车道；同帧同文本经 pending 计数显示 ×N；count 聚合不合并；8 秒窗口过期重计有单测。 |
| A11 | passed | brief.md | 悬停/点击暂停与菜单：桌面悬停或触屏点击条目冻结该条并显示菜单（复制、屏蔽此弹幕、关闭）；移出条目与菜单 220ms 后恢复；屏蔽后同文本在屏条目移除并写入现有屏蔽列表；非条目区域不拦截播放器控件的指针事件；暂停期间车道不会被过早复用。 | _hold 冻结位置；_scheduleResume 在已有 timer 时直接返回，空白区持续移动不会重置 220ms，回到条目/菜单会 cancel；_reserveHeldLane 每帧抬 freeAt，_releaseHeld 用 startTick+=paused 保持连续；Listener(translucent)+MouseRegion(opaque:false) 非条目透传；播放器 Stack 层序已修正；屏蔽先移除再回调。 |

## 检查

| Agent 报告的检查 | 结果 | 执行与证据 |
| --- | --- | --- |
| canvas_danmaku analyze | passed | flutter analyze: No issues found. |
| canvas_danmaku test | passed | flutter test: 39 tests passed, including merge-toggle id reuse and hover-resume timer regressions. |
| simple_live_app analyze lib | passed | flutter analyze lib: No issues found. |
| simple_live_app focused tests | passed | frame_coalescer_test + shield_pattern_cache_test: 3 tests passed. |
| simple_live_tv_app analyze lib | passed | flutter analyze lib: No issues found. |
| simple_live_app build windows --release | passed | Built build/windows/x64/runner/Release/simple_live_app.exe in 82.1s after the fourth-round fixes. |
| synthetic dense-load profile | passed | 60s at ~36 msg/s: 2480 produced frames, UI p95 600us, Raster p95 1101us, 0 UI/Raster frames >16.7ms; spawned 231, dropped 1588, merged 355; report at D:/DEV/_research/danmaku_profile.json. |

### Builder 报告的证据

以下为 Builder 报告，不等同于 Runtime 检查凭据或独立验收结果。

- canvas_danmaku analyze: passed — flutter analyze: No issues found.
- canvas_danmaku test: passed — flutter test: 39 tests passed, including merge-toggle id reuse and hover-resume timer regressions.
- simple_live_app analyze lib: passed — flutter analyze lib: No issues found.
- simple_live_app focused tests: passed — frame_coalescer_test + shield_pattern_cache_test: 3 tests passed.
- simple_live_tv_app analyze lib: passed — flutter analyze lib: No issues found.
- simple_live_app build windows --release: passed — Built build/windows/x64/runner/Release/simple_live_app.exe in 82.1s after the fourth-round fixes.
- synthetic dense-load profile: passed — 60s at ~36 msg/s: 2480 produced frames, UI p95 600us, Raster p95 1101us, 0 UI/Raster frames >16.7ms; spawned 231, dropped 1588, merged 355; report at D:/DEV/_research/danmaku_profile.json.
- 已知限制: Windows release build requires Developer Mode for plugin symlinks and nuget.exe for flutter_inappwebview_windows; both are local environment prerequisites, not repo changes.
- 已知限制: A9 uses the user-approved synthetic dense load (~36 msg/s, 60s) instead of a real live room; the bench app does not exercise simple_live_app message filtering or player overlay composition.
- 已知限制: The profile produced 2480 frames in 60s (~41fps) in this environment; among produced frames 0 exceeded 16.7ms. Frame production is environment-dependent and is not claimed as a 60fps guarantee.
- 已知限制: Menu reachability is verified by the reordered player Stack and focused widget tests; no live desktop hover test on a real stream was performed.

## 阻塞项

- **user**: Verification passed; user acceptance is required before Archive. — next: `await-user`

## 风险与跳过的工作

- A9 的合成 profile 帧产出约 41fps，属于运行环境限制；验收只对已产生帧判断 >16.7ms，用户已确认用合成密集负载替代真实直播间。
- TV 端未接 onBlockDanmaku，菜单隐藏“屏蔽此弹幕”按钮；电视端只要求编译与行为等价。
- Windows release 构建依赖本机 Developer Mode 与 nuget.exe，属于环境前置条件，不是仓库改动。

## 之前的迭代

| 目标周期 | 迭代 | 尝试 | 结果 | 未解决项 | 摘要 | 完成时间 |
| ---: | ---: | ---: | --- | --- | --- | --- |
| 1 | 1 | 1 | fail | A7, A10, A11 | Verifier 判定 fail：A7 缺少 bottom safeArea 过滤；A10 合并加宽会与同车道后继条目重叠、同帧多条同文本只显示 ×1；A11 菜单被播放器全屏手势层遮挡、暂停车道会被过早复用。其余 A1-A6/A8/A9 通过。 | 2026-11-16T05:54:51.445Z |
| 1 | 2 | 1 | fail | A9, A10 | 第二轮 Verifier 判定 fail：A9 的合并路径单帧重建可超过 maxSpawnPerFrame，且 60s 只产生 2465 帧，无法证明连续无掉帧；A10 的 _gapToNext 稳态间距符号错误导致后继条目右移过度，pending 计数在组过期后残留。A7/A11 已通过，其余 A1-A6/A8 通过。 | 2026-11-16T09:21:51.789Z |
| 1 | 3 | 1 | fail | A10, A11 | 第三轮 Verifier 判定 fail：A9 已通过（每帧预算 + profile 2538 帧/0 超时）；A10 仍有合并组 id 复用问题，A11 仍有 hover 计时被持续重置问题。其余 A1-A9 通过。 | 2026-11-16T09:49:57.478Z |
| 1 | 4 | 1 | pass | — | 第四轮独立 Verifier 全项通过：A1-A11 均 passed。A10 的合并组 id 单调/ pending 清理、A11 的 220ms 恢复 Timer 幂等均已闭合；A9 的每帧 image budget 与 2480 帧/0 超时 profile 通过（帧产出约 41fps 为环境限制）。 | 2026-11-16T10:06:48.982Z |



## 结论

第四轮独立 Verifier 全项通过：A1-A11 均 passed。A10 的合并组 id 单调/ pending 清理、A11 的 220ms 恢复 Timer 幂等均已闭合；A9 的每帧 image budget 与 2480 帧/0 超时 profile 通过（帧产出约 41fps 为环境限制）。
