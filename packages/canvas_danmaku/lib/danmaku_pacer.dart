import 'dart:collection';

/// 把弹幕位置更新量化到固定时间网格。
///
/// 在部分机器上（例如 Windows 高刷新率屏幕 + 拷贝式合成），Flutter 的帧间隔会在
/// 2~3 个 vsync 之间抖动（实测 12.12ms / 18.18ms 混跳）。若逐帧推进位置，
/// 位移会忽大忽小，观感就是“一顿一顿”。
///
/// 这里用实测帧间隔的分位数当网格步长：位置只在网格边界前进，步长等距，
/// 代价是有效刷新率降到网格频率（视觉上类似 55~60fps 的电影感）。
/// 网格取自 p75，保证大多数帧都能落在网格上，避免整步被跳过。
class DanmakuPacer {
  DanmakuPacer({int window = 90, int minStep = 8, int maxStep = 25})
      : _window = window,
        _minStep = minStep,
        _maxStep = maxStep;

  final int _window;
  final int _minStep;
  final int _maxStep;
  final Queue<int> _deltas = Queue<int>();

  /// 采样不足时返回 0，调用方应退回逐帧推进
  int get step {
    if (_deltas.length < 12) {
      return 0;
    }
    final sorted = _deltas.toList()..sort();
    final p75 = sorted[((sorted.length - 1) * 0.75).round()];
    return p75.clamp(_minStep, _maxStep);
  }

  /// 记录一次帧间隔（毫秒）；异常大的间隔（切后台、卡顿）不计入
  void add(int deltaMilliseconds) {
    if (deltaMilliseconds <= 0 || deltaMilliseconds > 120) {
      return;
    }
    _deltas.addLast(deltaMilliseconds);
    while (_deltas.length > _window) {
      _deltas.removeFirst();
    }
  }

  void reset() => _deltas.clear();
}