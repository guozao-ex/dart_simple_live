import 'package:flutter/widgets.dart';

/// 把同一帧内的多次请求合并成一次 post-frame 回调。
class FrameCoalescer {
  bool _scheduled = false;

  /// 实际执行次数，供调试与测试读取。
  int runs = 0;

  void schedule(void Function() action) {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      runs += 1;
      action();
    });
    WidgetsBinding.instance.scheduleFrame();
  }
}
