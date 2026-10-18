import 'dart:async';

/// 默认兜底间隔：斗鱼直链租约约 300 秒，留出 30 秒余量。
const Duration kDouyuRenewFallbackInterval = Duration(seconds: 270);

/// 斗鱼定时换流兜底。
///
/// 续流中继不可用（例如用户关闭了自动续流）时，斗鱼直链会在约 300 秒后
/// 失效；这里按固定间隔触发重新取址，避免播放中断。
///
/// 调度器本身不关心业务原因：是否应当换流由调用方通过 [shouldRun] 判定，
/// 被跳过时也不产生副作用。这样它既能被两端复用，也能用虚拟时间单独测试。
class DouyuRenewFallback {
  DouyuRenewFallback({
    required this.onRenew,
    this.shouldRun,
    this.interval = kDouyuRenewFallbackInterval,
  });

  /// 换流动作：通常是重新取地址并重开播放。
  final void Function() onRenew;

  /// 本次是否应当换流；返回 false 时跳过本次触发。为空表示每次都执行。
  final bool Function()? shouldRun;

  /// 触发间隔，默认 [kDouyuRenewFallbackInterval]。
  final Duration interval;

  Timer? _timer;

  /// 是否正在运行。
  bool get running => _timer != null;

  /// 启动；幂等——已在运行时不会产生第二个定时器。
  void start() {
    if (_timer != null) {
      return;
    }
    _timer = Timer.periodic(interval, (_) => _tick());
  }

  /// 停止；未运行时调用无副作用。
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _tick() {
    final guard = shouldRun;
    if (guard != null && !guard()) {
      return;
    }
    try {
      onRenew();
    } catch (_) {
      // 换流是尽力而为：单次异常不应打断后续兜底
    }
  }
}
