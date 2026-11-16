# 本地补丁说明

本目录是 pub.dev 上 [`canvas_danmaku`](https://pub.dev/packages/canvas_danmaku)
0.3.3 源码的本地副本，被 `simple_live_app` 以 path 依赖方式使用，用于修复弹幕字重问题。

## 与上游 0.3.3 的差异

仅修改 `lib/utils/utils.dart`：

1. 新增 `DmUtils.fontWeightOf(int)`：把字重索引统一做 `clamp(0, 8)`。
   - 上游直接使用 `FontWeight.values[fontWeight]`，当传入 9 档索引（9）时越界抛
     `RangeError`，是弹幕「极粗」设置崩溃/失效的直接原因。
2. 新增 `DmUtils.fontVariationsOf(int)`：把字重索引映射为可变字体的 `wght` 轴取值。
3. 在 `generateParagraph`、`recordDanmakuImage`、`recordSpecialDanmakuImg` 生成的
   `ui.TextStyle` 中传入 `fontVariations`。
   - Flutter/SkParagraph 只有在显式提供 `fontVariations` 时才会克隆可变字体实例；
     仅设置 `fontWeight` 对可变字体无效（会一直使用默认实例）。
   - 内置的 Noto Sans SC 可变字体默认实例是 Thin(w100)，所以这一步是必需的。

## 升级注意

从上游更新本包时，请保留以上改动，或改回「多静态字重字体」方案并同步调整
`simple_live_app` 的字体声明。上游仓库：<https://github.com/Predidit/canvas_danmaku>

## 2026-11-16 横向弹幕引擎重写

在上述字重补丁之外，本目录的滚动弹幕改为 Fy1Sync 式调度：

- 到达只入队；每帧批量生成 `min(空闲车道, maxSpawnPerFrame)` 条，未被分配车道的消息直接丢弃、不排队。
- 所有滚动弹幕等速（`viewWidth / durationMs`），车道用 `freeAt` 复用；`massiveMode` 保留叠轨。
- 文本位图 LRU 缓存（默认 24 MiB / 512 条，引用计数），样式或设备像素比变化时清空。
- `CustomPainter` 通过 `repaint` Listenable 重绘；位置由帧时间纯函数给出，绘制横坐标吸附设备像素。
- 同文本 8 秒内合并为 `×N`；悬停/点击暂停单条并显示复制、屏蔽此弹幕、关闭菜单。

上游升级时需保留这些差异，或按本文件重新移植。新增文件：
`danmaku_lane_allocator.dart`、`danmaku_queue.dart`、`danmaku_image_cache.dart`、
`danmaku_merge_processor.dart`、`danmaku_menu.dart`、`danmaku_engine_stats.dart`。
