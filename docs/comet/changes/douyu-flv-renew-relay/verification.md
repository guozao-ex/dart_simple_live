---
generated_from_state_version: 14
---

# 验证

## 当前结果

- 结果: **验收通过，可归档**
- 验证情况: **已完成检查，验证结果已确认**
- 目标周期: 2
- 迭代: 2
- 验证器尝试次数: 1
- 完成时间: 2026-10-18T10:20:22.971Z
- 摘要: 6/6 全部通过：开关在 core 首句早退且由构造计数行为性证明（关闭 0 次 / 开启 1 次）、两端默认 true 并透传、既有 11 条用例零削弱且 12/12 通过、三包 analyze 零问题（13 条 lint 纯机械）、Windows release 产物落在本轮构建窗口、360s 真实浸泡于 295s 续流且最大视频间隔 40ms、零倒退；上一轮 5 条风险全部修好。

## 验收

| 编号 | 结果 | 来源 | 验收项 | 原因 |
| --- | --- | --- | --- | --- |
| A1 | passed | brief.md | 关闭开关时，斗鱼播放不再接入本机中继：FlvRenewPlayback.create(playUrl, enabled: false) 返回 null，且不建立本地监听端口。 | create() 首句 if (!enabled) return null，早于 renewUrl 读取、relay 构造与 relay.start()（create 路径唯一 HttpServer.bind 点）；新增用例注入 debugRelayFactory 计数：enabled:false 时返回 null、续流取址回调 0 次、中继构造 0 次，不传 enabled 时构造 1 次并返回本机中继地址（core-relay-tests 12/12 通过）。 |
| A2 | passed | brief.md | 开关默认开启：两端设置项初始值为 true，core 的 create 默认参数为 true。 | core create(playUrl, {bool enabled = true}) 默认开启；手机端与 TV 端均 douyuRenewRelay = true.obs 且 LocalStorageService 读取缺省 true，两端设置页各暴露「斗鱼自动续流」开关，两处生产调用点均透传该值。 |
| A3 | passed | brief.md | 开启时既有行为不变：core 现有续流用例（含假 CDN 端到端）全部通过。 | 工作树 vs 1981d16 的 core/test 差异：11 条既有用例一条未删、无断言放宽（仅新鲜度等待 1100→1500ms、读流超时显式 6s，断言仍为 200 + 有内容），新增 1 条开关用例；core-relay-tests 日志 +12: All tests passed!，含假 CDN 端到端。 |
| A4 | passed | brief.md | 三个包静态检查零问题：simple_live_core 的 dart analyze、手机端与 TV 端的 flutter analyze。 | core dart analyze、手机端与 TV 端 flutter analyze lib 三项 Runtime 检查均 exit 0，日志均为 No issues found!；13 条 lint 清理逐行核对为机械改动：删 2 个未用导入、HYSDK_UA→hysdkUa（全仓无残留引用）、tars 三文件仅改 readFrom/writeTo/displayAsString 的参数与局部变量名（字段名与 tag 号未动）、多余字符串花括号 ${antiCode}→$antiCode。 |
| A5 | passed | brief.md | 原生可运行产物：Windows 桌面 release 构建成功。 | win-build（flutter build windows --release，cwd simple_live_app）exit 0，日志 √ Built build\windows\x64\runner\Release\simple_live_app.exe；产物 mtime 18:14 落在本候选构建窗口 10:12:31–10:14:01Z（本地 18:12:31–18:14:01）内，Release/data 同步更新。 |
| A6 | passed | brief.md | 真实斗鱼流在开启状态下跨过 300s 租约不中断：浸泡 360s，续流取址至少 1 次、视频帧最大间隔小于 1000ms、时间戳零倒退。 | douyu-soak（DOUYU_SOAK_ROOM=auto DOUYU_SOAK_SECONDS=360，376.7s）exit 0，日志 [soak] 时长=360s tag=24712 时间跨度=8475545ms 最大视频间隔=40ms 倒退=0 续流次数=1（第 295s 触发）：跑满 360s≥355s、maxGap 40ms<1000ms、零倒退、跨 300s 租约续流 ≥1 次四项断言全成立（断言失败会非零退出）。 |

## 检查

| 检查 | 命令 | 工作目录 | 状态 | 退出码 | 耗时 |
| --- | --- | --- | --- | ---: | ---: |
| core 静态检查 | analyze | simple_live_core | passed | 0 | 2691 ms |
| core 续流用例 | test test/flv_renew_relay_test.dart | simple_live_core | passed | 0 | 41521 ms |
| 手机端静态检查 | analyze lib | simple_live_app | passed | 0 | 10862 ms |
| TV 端静态检查 | analyze lib | simple_live_tv_app | passed | 0 | 12004 ms |
| 真实斗鱼流浸泡 360s | -lc DOUYU_SOAK_ROOM=auto DOUYU_SOAK_SECONDS=360 dart test test/flv_renew_relay_live_test.dart | simple_live_core | passed | 0 | 376702 ms |
| Windows release 构建 | build windows --release | simple_live_app | passed | 0 | 90668 ms |

### Builder 报告的证据

以下为 Builder 报告，不等同于 Runtime 检查凭据或独立验收结果。

- core dart analyze（lib+test）: passed — No issues found
- core 单测（续流用例）: passed — 12/12 通过，含开关用例的行为性断言
- 手机端 flutter analyze: passed — No issues found
- TV 端 flutter analyze: passed — No issues found（含新增的 270s 兜底定时器）
- Windows release 构建 / 真实流浸泡: passed — 上一候选通过；本候选由 Runtime 计划重新执行
- 已知限制: 未做真机/图形界面的人工长时间观看（已确认为非目标）；本轮只交付可运行的原生构建产物。
- 已知限制: 浸泡依赖本机 node 与斗鱼线上在播房间（auto 选房）；平台接口异常时该检查会失败而非静默跳过，且新增的时长断言可挡住房间中途下播。
- 已知限制: core 既有 13 条 lint 的清理涉及 brief 目录结构未列出的 huya 模块（为满足 A4 字面要求），已在 note 中说明。
- 已知限制: TV 端的 270s 定时换流兜底为本轮新增，其行为与手机端一致，但两端都没有自动化用例覆盖定时器本身（只能靠代码核对）。

## 阻塞项

_无。_

## 风险与跳过的工作

- FlvRenewPlayback.debugRelayFactory 是为测试注入的可变公共静态字段，随库进入生产代码（当前仅测试用例使用，生产调用点不设置）；若日后有生产代码误设会改变中继构造，建议后续加 @visibleForTesting 或改走构造注入。
- 本候选只存在于工作树（HEAD=1981d16 为基线提交，改动未提交），没有提交哈希钉住被验收版本；证据靠文件 mtime（全部 ≤18:03）早于检查窗口（18:05:06–18:14:01Z）与 Runtime 指纹绑定。归档提交必须原样落入当前工作树，检查后任何改动都会使本轮证据失效。
- 两端 270s 定时换流兜底都没有自动化用例覆盖（只能靠代码核对）；TV 端与手机端一致地采用「定时回调内判 _renewPlayback != null 即跳过」而非取消定时器，语义等价于 spec 的「启用中继时停用」，但非字面 cancel。
- maxGap 阈值收紧到 <1000ms 后，浸泡测试对真实 CDN 的瞬时抖动更敏感（本次实测 40ms，余量充足）；真实卡顿 >1s 时测试会失败而非静默通过——符合 A6 口径，但会带来偶发红灯。
- 仓库根多出未跟踪的 handoff2.json / handoff2_result.json / handoff2_result.err（Builder/Runner 产物，不在 brief 的文件清单内）；归档提交时不应带入。
- 三处 flutter 生成的 generated_plugin_registrant.* / generated_plugins.cmake 在 git status 显示已修改，但规范化后与基线内容一致（疑似工具重写导致的 EOL 抖动），无需评审，会给归档提交带来噪声。

## 之前的迭代

| 目标周期 | 迭代 | 尝试 | 结果 | 未解决项 | 摘要 | 完成时间 |
| ---: | ---: | ---: | --- | --- | --- | --- |
| 1 | 0 | 0 | recovery | — | Native confirmed acceptance criteria changed | 2026-10-18T09:02:36.995Z |
| 2 | 1 | 1 | pass | — | A1-A6 全部通过：开关在 core 早退、两端默认 true 且透传，既有 11 个续流用例未被削弱并随新增开关用例 12/12 通过，三包静态检查 exit 0（13 条 huya/tars lint 经核对属机械改名）、Windows release 产物为构建窗口内新生成，真实斗鱼流 360s 浸泡在 295s 触发续流、时间跨度 331s、零倒退、最大视频间隔 40ms。 | 2026-10-18T09:56:58.917Z |
| 2 | 1 | 1 | recovery | — | Verifier 判定 6/6 通过，但用户要求先全量修复其报出的 5 条风险（测试阈值/测试瑕疵/TV 端缺 270s 兜底/浸泡未断言跑满/端口绑定仅静态推得）再归档，故保留已确认需求、返回 Build 修改实现 | 2026-10-18T10:00:02.261Z |
| 2 | 2 | 1 | pass | — | 6/6 全部通过：开关在 core 首句早退且由构造计数行为性证明（关闭 0 次 / 开启 1 次）、两端默认 true 并透传、既有 11 条用例零削弱且 12/12 通过、三包 analyze 零问题（13 条 lint 纯机械）、Windows release 产物落在本轮构建窗口、360s 真实浸泡于 295s 续流且最大视频间隔 40ms、零倒退；上一轮 5 条风险全部修好。 | 2026-10-18T10:20:22.971Z |



## 结论

6/6 全部通过：开关在 core 首句早退且由构造计数行为性证明（关闭 0 次 / 开启 1 次）、两端默认 true 并透传、既有 11 条用例零削弱且 12/12 通过、三包 analyze 零问题（13 条 lint 纯机械）、Windows release 产物落在本轮构建窗口、360s 真实浸泡于 295s 续流且最大视频间隔 40ms、零倒退；上一轮 5 条风险全部修好。
