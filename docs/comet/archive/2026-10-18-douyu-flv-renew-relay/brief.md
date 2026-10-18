# 目标

为已经交付的「斗鱼 FLV 续流中继」补一个用户可见的开关（默认开启），让用户能自行决定斗鱼播放是否经过本机中继；并按 Comet Native 流程完成本轮实现、独立验收与归档。

背景：斗鱼自 2026-09 起对第三方拉流按固定寿命掐线（实测 300.1~300.4s），已交付的中继在到期前 5s 预取新地址、在 FLV tag 边界无缝续接。中继对"本来就没有断流问题"的房间也一视同仁地接管，缺少用户侧退路；本轮补上开关与相应验收。

# 范围

- 开关只作用于斗鱼 FLV 线路：其他平台没有续流取址回调，行为不变。
- 开关默认开启，可在手机端与 TV 端设置页关闭；关闭后不再接入中继，继续走既有播放路径。
- 开关语义下沉到 core 的可测参数（FlvRenewPlayback.create 增加 enabled），使"关闭即不接入"由单元测试覆盖，而不是只靠 UI。
- 不改动续流算法、拼接口径与中继协议本身（属已交付范围）。
- 不改动虎牙、哔哩哔哩、抖音等平台的取流与播放逻辑。

## 目录结构

### 新建

- docs/comet/changes/douyu-flv-renew-relay/specs/douyu-flv-renew/spec.md — 本 capability 的完整目标规格。

### 修改

- simple_live_core/lib/src/player/flv_renew_playback.dart — create 增加 enabled 参数，关闭时直接返回 null（不绑定端口、不建中继）。
- simple_live_core/test/flv_renew_relay_test.dart — 补开关用例（关闭不接入、默认开启）。
- simple_live_app/lib/app/controller/app_settings_controller.dart — 新增开关项与本地持久化，默认 true。
- simple_live_app/lib/modules/live_room/live_room_controller.dart — 接入中继时传入开关值。
- simple_live_app/lib/modules/settings/play_settings_page.dart — 设置页暴露开关。
- simple_live_tv_app/lib/app/controller/app_settings_controller.dart — 同手机端的开关与持久化。
- simple_live_tv_app/lib/modules/live_room/live_room_controller.dart — 接入中继时传入开关值。
- simple_live_tv_app/lib/modules/settings/ — TV 设置页暴露开关。

### 删除

无

### 明确不建

- 不新增独立的配置中心或存储服务：沿用两端既有的 LocalStorageService 与设置控制器。
- 不为其他平台预留开关：除斗鱼外没有平台提供续流取址回调，加了也是死配置。
- 不新增中继层的按线路开关：对用户不可理解，且当前无证据支持。

# 非目标

- 不修改续流拼接算法、时间戳处理与失败回落策略。
- 不改变其他直播平台的任何行为。
- 不做真机长时间人工观看的自动验收：该环节留给归档后由用户执行，本轮只提供可运行的原生构建产物。

# 关键决定

- 开关默认值：默认开启（用户确认 Q1=A；理由：中继修的是真实断流问题，默认关闭等于让多数用户继续踩坑）。
- 关闭后的行为：回落到既有的 270s 定时换流兜底，而不是完全直连不动（用户确认 Q2=A；该兜底是上一版已交付能力，关闭中继不等于放弃续流）。
- 开关语义放在 core：便于独立验收，避免"只改了 UI 没改行为"。

# 验收示例

- 关闭开关时，斗鱼播放不再接入本机中继：FlvRenewPlayback.create(playUrl, enabled: false) 返回 null，且不建立本地监听端口。
- 开关默认开启：两端设置项初始值为 true，core 的 create 默认参数为 true。
- 开启时既有行为不变：core 现有续流用例（含假 CDN 端到端）全部通过。
- 三个包静态检查零问题：simple_live_core 的 dart analyze、手机端与 TV 端的 flutter analyze。
- 原生可运行产物：Windows 桌面 release 构建成功。
- 真实斗鱼流在开启状态下跨过 300s 租约不中断：浸泡 360s，续流取址至少 1 次、视频帧最大间隔小于 1000ms、时间戳零倒退。

# 验证期望

- 除静态检查与单元测试外，必须执行一次真实斗鱼流浸泡（需要 node 与真实房间号，脚本已随仓库提供）。
- Windows 桌面构建作为"原生可运行"的证据，构建产物路径记录在验收报告里。
- 人工长时间观看不作为自动验收项。