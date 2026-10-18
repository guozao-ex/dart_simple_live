# 目标

把「斗鱼定时换流兜底」的调度策略从手机端与 TV 端控制器里抽出来，做成 core 中可注入、可单测的单元，并用自动化用例覆盖其行为；两端改为复用它，消除两份重复实现。

背景：上一轮交付（douyu-flv-renew-relay）给两端各加了一个 270s 定时换流兜底，但只有代码、没有任何自动化用例；且手机端与 TV 端各写了一份等价逻辑。这是「下次改斗鱼相关逻辑最容易踩」的地方。

# 范围

- 新建 core 内的调度器：可配置间隔，注入「是否应当换流」判定与换流回调，提供 start/stop/running。
- 新建针对调度器的单测：覆盖到点触发、条件不满足时跳过、停止后不再触发、重复 start 幂等、自定义间隔。
- 手机端与 TV 端的直播间控制器改用该调度器，删除各自的本地方案；跳过条件保持等价（中继已接入时跳过、后台/未直播时跳过）。
- 不改续流中继、开关语义、270s 间隔值与判定条件本身。

## 目录结构

### 新建

- simple_live_core/lib/src/player/douyu_renew_fallback.dart — 斗鱼定时换流兜底调度器（纯 Dart、可注入判定与回调）。
- simple_live_core/test/douyu_renew_fallback_test.dart — 调度器单测（fake_async 驱动虚拟时间）。

### 修改

- simple_live_core/lib/simple_live_core.dart — 导出调度器。
- simple_live_core/pubspec.yaml — dev_dependencies 增加 fake_async（仅测试用）。
- simple_live_app/lib/modules/live_room/live_room_controller.dart — 用调度器替换本地定时实现。
- simple_live_tv_app/lib/modules/live_room/live_room_controller.dart — 同上。

### 删除

无

### 明确不建

- 不新建独立的「定时任务框架」：只有一个兜底定时器，抽象到框架层是过度设计。
- 不把调度器做成单例/全局服务：每个直播间控制器各持一个实例，生命周期跟随页面。

# 非目标

- 不修改续流中继（FlvRenewRelay）的拼接算法、失败回落与超时策略。
- 不改变开关的默认值与语义。
- 不改变 270 秒间隔，也不改变「中继接入时跳过」的判定条件。
- 不给两端控制器补 widget/集成测试（本轮只把调度策略变成可测单元）。

# 关键决定

- 调度器放 core：core 是纯 Dart 且有测试基建，两端都能直接复用。
- 用 fake_async 驱动虚拟时间：真实等待 270s 无法测，虚拟时间是唯一务实做法。
- 判定条件外置（shouldRun 回调）：调度器不关心「为什么跳过」，只按调用方给的判定执行，便于复用与测试。

# 验收示例

- 调度器按配置的间隔触发回调：用 fake_async 推进虚拟时间，触发次数与间隔严格对应。
- 判定条件为假时不触发：shouldRun 返回 false 期间推进时间，回调零调用；恢复为真后按时触发。
- stop 之后不再触发；重复 start 只保留一个定时器（不会重复触发）。
- 自定义间隔生效（非默认 270s 也要正确）。
- 两端控制器都改为复用该调度器，且跳过/启动/停止时机与改动前等价；三个包静态检查零问题。
- core 全部用例通过（含新增调度器用例）；Windows release 构建成功（证明两端改动能编译）。

# 验证期望

- 本轮不需要真实斗鱼流浸泡：改动不触及中继与拉流路径，浸泡无法为本改动提供额外证据。
- Windows 构建作为「两端改动能编译」的证据。
