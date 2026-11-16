# 目标

把横向弹幕从「到达即排版/光栅化、每帧在 paint 中累加位置、每帧重建 painter」改为 Fy1Sync 式引擎：到达只入队，每帧批量 drain，按空闲车道数生成，等速 px/s + freeAt 车道复用，溢出丢弃，文本位图 LRU 缓存，painter 通过 repaint listenable 重绘并做设备像素吸附；同时消除应用侧同一 isolate 的每消息开销（屏蔽正则逐条编译、聊天滚动逐条 post-frame），并纳入 Fy1Sync 的两项弹幕交互：同文本 8 秒内合并为 ×N、悬停/点击暂停并在指针旁弹出操作菜单。目标是在弹幕密集的直播间里横向滚动连续、无掉帧，且现有弹幕设置与两端 App 行为不变。

背景（研究结论，Fy1Sync 仅作实现参考）：Fy1Sync 每帧一次 rAF drain → 批量建节点/一次布局测宽 → 按 freeAt 分配等速车道 → WAAPI linear transform 交给合成器；无空车道直接丢弃。合并计数由 `DanmakuProcessor` 在释放时按「房间 + 文本」分组、8 秒窗口完成；暂停菜单由命中条目时暂停单条动画并显示操作条实现。本仓库现状：每条 WebSocket 消息在回调里同步做 1~2 次 Paragraph 排版 + PictureRecorder + toImageSync，且在被丢弃的消息上也先排版；固定 duration 使速度随文本宽度变化；每帧通过 ValueListenableBuilder 重建 3 个 CustomPaint；弹幕层 `IgnorePointer`，无法命中条目。

# 范围

- 重写 `packages/canvas_danmaku` 的横向弹幕调度与绘制：到达队列、每帧批量 spawn、等速车道、溢出丢弃、位图 LRU、repaint listenable、设备像素吸附。
- 合并计数：同文本 8 秒内合并为一个在屏条目并追加 `×N`；计数增加时重新生成位图、更新宽度并延长车道占用；默认开启，设置页提供开关；窗口固定 8 秒，只做合并（combo）模式。
- 悬停/点击暂停与菜单：桌面悬停或触屏点击在屏条目时冻结该条并显示菜单（复制、屏蔽此弹幕、关闭）；移出条目与菜单 220 毫秒后恢复；菜单支持用户名展示（内容携带时）；非条目区域不拦截播放器控件。
- 平台能力映射：Fy1Sync 的收藏、回复、禁言、用户详情、历史依赖斗鱼账号与 UID，本仓库没有对应能力，本次不实现；屏蔽以现有 `shieldList` 的精确文本方式落地。
- 保持公开 API（`DanmakuScreen`、`DanmakuController`、`DanmakuOption`、`DanmakuContentItem`）向后兼容，`simple_live_app` 与 `simple_live_tv_app` 无需改调用点即可编译；TV 端验证编译与行为等价。
- 应用侧：屏蔽关键词正则预编译并按列表版本失效；聊天自动滚动合并为每帧最多一次；新增合并开关的持久化与设置页入口；弹幕内容携带用户名。
- 新增纯 Dart 单测（车道分配器、队列、合并处理器）与 widget 测试（缓存、spawn 上限、逐帧重绘、暂停/恢复、菜单命中）；更新 `PATCHES.md` 记录本地分叉。
- 保留顶部/底部/特效弹幕现有行为；保留 `massiveMode` 叠轨例外。
- 现有弹幕设置项（字号、字重、字体、描边、区域、速度、不透明度、上下边距）全部继续生效。

## 目录结构

### 新建

- packages/canvas_danmaku/lib/danmaku_lane_allocator.dart — 等速车道分配器（freeLanes/allocate/rescale/delay/extend/setLayout），纯 Dart。
- packages/canvas_danmaku/lib/danmaku_queue.dart — 到达队列，容量 2000，溢出丢最旧，统计 queued/dropped。
- packages/canvas_danmaku/lib/danmaku_image_cache.dart — 文本位图 LRU（24 MiB / 512 条），引用计数，命中返回 image + 尺寸。
- packages/canvas_danmaku/lib/danmaku_merge_processor.dart — 同文本合并计数（8 秒窗口、组 TTL、容量上限），纯 Dart。
- packages/canvas_danmaku/lib/danmaku_menu.dart — 悬停/点击菜单（用户名、复制、屏蔽、关闭）与锚点定位。
- packages/canvas_danmaku/lib/danmaku_engine_stats.dart — 引擎统计（queued/spawned/dropped/cacheHits/cacheMisses/visible），仅调试读取。
- packages/canvas_danmaku/test/danmaku_lane_allocator_test.dart — 分配/复用/rescale/delay/extend/resize 单测。
- packages/canvas_danmaku/test/danmaku_queue_test.dart — 容量、溢出、drain 单测。
- packages/canvas_danmaku/test/danmaku_image_cache_test.dart — 命中/淘汰/引用计数/清空测试。
- packages/canvas_danmaku/test/danmaku_merge_processor_test.dart — 窗口内合并、过期重置、容量、关闭开关、已有 count 跳过。
- packages/canvas_danmaku/test/danmaku_screen_test.dart — 到达不排版、每帧 spawn 上限、逐帧重绘、暂停/恢复、菜单命中、设置切换清理的 widget 测试。

### 修改

- packages/canvas_danmaku/lib/danmaku_screen.dart — `addDanmaku` 只入队；`_tick` 执行 drain → 分配 → 批量生成 → sweep；合并计数更新与 refit；命中/暂停/恢复；菜单显示；帧时间用 repaint listenable 驱动。
- packages/canvas_danmaku/lib/scroll_danmaku_painter.dart — 位置改为 `from - (tick - startTick) * speed` 纯函数，不再在 paint 中累加；暂停条目按 heldAt 冻结。
- packages/canvas_danmaku/lib/base_danmaku_painter.dart — 接受 `repaint` Listenable；`paintImg` 做设备像素吸附。
- packages/canvas_danmaku/lib/models/danmaku_item.dart — 增加 lane/top/from/speed/startTick/imageEntry/held/heldAt/mergeGroupId 字段；移除 item 对共享 `ui.Image` 的 dispose。
- packages/canvas_danmaku/lib/models/danmaku_content_item.dart — 新增可选 `userName` 与 `mergeCount`；现有 `count` 语义不变。
- packages/canvas_danmaku/lib/models/danmaku_option.dart — 新增 `mergeDuplicates`（默认 true）。
- packages/canvas_danmaku/lib/utils/utils.dart — 位图生成返回 image + 宽高，接入缓存；`mergeCount` 以 `×N` 后缀渲染；保留字重可变字体补丁。
- packages/canvas_danmaku/pubspec.yaml — 增加 `flutter_test` 开发依赖（包内测试需要时）。
- packages/canvas_danmaku/PATCHES.md — 记录引擎重写、合并计数与菜单与上游合并注意事项。
- simple_live_app/lib/modules/live_room/live_room_controller.dart — 构造弹幕内容时带 `userName`；屏蔽正则按列表版本预编译；聊天自动滚动每帧最多一次。
- simple_live_app/lib/modules/live_room/player/player_controls.dart — 创建 `DanmakuScreen` 时传入「屏蔽此弹幕」回调与合并开关。
- simple_live_app/lib/app/controller/app_settings_controller.dart — 新增 `danmuMerge` 开关并持久化；`toDanmakuOption` 传入合并开关。
- simple_live_app/lib/services/local_storage_service.dart — 新增合并开关的存储键。
- simple_live_app/lib/modules/settings/danmu_settings_page.dart — 新增「合并相同弹幕」开关。

### 删除

无

### 明确不建

- 逐节点合成器层（Flow + 每项 RepaintBoundary）— 本次用 canvas 预栅格位图等价实现；只有 profile 证明逐帧 draw 成为瓶颈时才另开 change。
- 媒体时间轴 / LiveEdgeClock — 直播没有媒体时间语义，本次只保留到达队列与帧节拍。
- 收藏、回复、禁言、用户详情、历史 — 依赖账号与 UID，本仓库没有对应能力；菜单只保留复制、屏蔽此弹幕、关闭。
- 合并窗口与合并模式的用户选项 — 固定 8 秒 combo，避免设置膨胀。
- 全局单例弹幕引擎或新状态管理框架 — 保持每个 `DanmakuScreen` 一个实例。

# 非目标

- 不改直播弹幕协议、平台客户端、消息解析与屏蔽规则语义。
- 不改播放器/视频渲染/窗口与 PiP 行为。
- 不实现发送弹幕、登录、账号类操作、收藏/禁言/用户详情/历史。
- 不改弹幕设置的默认值（新增合并开关除外）与既有 UI 结构。
- 不升级 canvas_danmaku 上游版本。
- 不改变顶部/底部/特效弹幕的时序语义。

# 关键决定

- 渲染形态选 canvas + 预栅格位图 + 纯位置函数：Flutter 下几十次 `drawImageRect`/帧成本极低；Fy1Sync 的 WAAPI 是为浏览器主线程逐帧写样式服务的，本仓库真正的瓶颈在到达路径。
- 速度语义统一为 `speed = viewWidth / durationMs`：保留「滚动速度 = 持续时间（秒）」的设置含义，同时让所有弹幕等速。
- 默认丢弃溢出，`massiveMode` 保留叠轨；`maxSpawnPerFrame` 默认 8，防止单帧补喷尖峰。
- 位图缓存所有权归缓存，item 只持引用；引用计数为 0 才能淘汰，避免 use-after-dispose。
- 字号/字重/字体/描边/DPR 变化清空在屏条目与缓存；纯宽度变化保留条目并延迟车道。
- 合并默认开启、窗口 8 秒、仅 combo；同文本忽略颜色；已有 `count` 的聚合弹幕不参与合并；计数增加时保持位置不变并延长车道占用。
- 菜单动作只映射仓库已有能力：复制到剪贴板、屏蔽此弹幕（写入现有 `shieldList` 并移除同文本在屏条目）、关闭；没有用户级 UID 时不做用户屏蔽。
- 暂停条目在恢复前占用车道：暂停时延长 `freeAt`，恢复后按剩余行程重算，默认模式不重叠。
- Fy1Sync 仓库仅作实现参考，不是本 change 的需求来源。

# 约束与不变式

- 公开 API 向后兼容；`simple_live_tv_app` 不新增调用点。
- 默认模式不允许同车道重叠；在屏数量由车道数与 `maxSpawnPerFrame` 共同限制。
- 绘制位置必须由帧时间纯函数得到，同一 tick 多次绘制结果一致。
- 任一被缓存或在屏的 `ui.Image` 在仍被引用时不得释放。
- 单帧生成的位图数与排版次数不超过 `maxSpawnPerFrame`。
- 非条目区域的指针事件必须继续传给播放器控件；菜单只作用于被命中的条目。
- 现有测试与静态检查保持通过。

# 验证期望

- 包内 `flutter test` 全绿；`flutter analyze` 对 `packages/canvas_danmaku`、`simple_live_app`、`simple_live_tv_app` 零新增问题。
- Windows release 构建成功，作为两端编译证据。
- Windows profile 下密集房间 60s 采集 FrameTiming：UI p95 ≤ 8ms，无 >16.7ms 的 UI/Raster 帧；采集摘要随验收提交。
- 用户实际观看确认横向滚动平滑、合并计数与暂停菜单可用，且字号/字重/描边/区域/速度等设置仍生效。

# 验收示例

- 到达路径不产生排版或位图：连续入队 1000 条滚动弹幕但不推进帧时，Paragraph 与位图构建计数均为 0；一次帧推进只为取得车道的消息构建。
- 每帧批量与丢弃：空闲车道 N 条时，一帧最多生成 `min(N, maxSpawnPerFrame)` 条，其余丢弃并计入统计；默认模式同车道不重叠，`massiveMode` 仍允许叠轨。
- 等速与车道复用：长度不同的滚动弹幕 px/s 相同；同车道前一条尾部清出右边缘后立即可复用；分配/复用行为有单测覆盖。
- 连续性与重排：修改滚动速度时在屏弹幕位置不跳变，车道剩余等待按旧/新速度比例缩放；视口变窄时按丢失宽度延迟车道；暂停/恢复后位置与时间连续。
- 位图缓存与所有权：相同文本+样式第二次生成命中缓存且不重复排版，不同样式不串图；淘汰不释放仍在屏的图；改字号/字重/字体/描边/DPR 清空缓存且无 use-after-dispose；稳态缓存不超过 24 MiB。
- 每帧重绘不重建 widget：连续 60 帧只触发 painter 重绘，不重建 CustomPaint、不新建 painter 实例。
- 设置与平台回归：字号、字重、字体、描边、区域、速度、不透明度、上下边距、合并开关、顶部/底部/特效弹幕、清屏、切后台行为与改动前等价；`simple_live_app` 与 `simple_live_tv_app` 分析通过，Windows release 构建成功。
- 应用侧洪峰开销：屏蔽关键词列表不变时，处理单条消息不新建 RegExp；聊天自动滚动每帧最多执行一次；对应计数测试通过。
- 帧预算与观感：合成负载下每帧排版/光栅化次数不超过 `maxSpawnPerFrame`；Windows profile 密集房间 60s 的 FrameTiming 摘要显示 UI p95 ≤ 8ms 且无 >16.7ms 的 UI/Raster 帧。
- 合并计数：同文本 8 秒内重复只保留一个在屏条目并显示 `×N`；计数增加时位图、宽度与车道占用同步更新且位置不跳变；超过 8 秒后重新从 1 计数；关闭开关恢复逐条显示；已有 `count` 的聚合弹幕不参与合并。
- 悬停/点击暂停与菜单：桌面悬停或触屏点击条目冻结该条并显示菜单（复制、屏蔽此弹幕、关闭）；移出条目与菜单 220ms 后恢复；屏蔽后同文本在屏条目移除并写入现有屏蔽列表；非条目区域不拦截播放器控件的指针事件；暂停期间车道不会被过早复用。
