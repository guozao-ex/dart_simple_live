import 'dart:math' as math;

/// 滚动弹幕的布局参数。
///
/// [speed] 的单位是「逻辑像素 / 毫秒」，所有滚动弹幕共享同一速度。
class DanmakuLaneLayout {
  const DanmakuLaneLayout({
    required this.laneHeight,
    required this.areaHeight,
    required this.width,
    required this.speed,
  });

  /// 单条车道高度（字号行高 + 间距后的可用高度）。
  final double laneHeight;

  /// 弹幕可占用区域高度。
  final double areaHeight;

  /// 视口宽度。
  final double width;

  /// 横向速度，px/ms。
  final double speed;

  DanmakuLaneLayout copyWith({
    double? laneHeight,
    double? areaHeight,
    double? width,
    double? speed,
  }) {
    return DanmakuLaneLayout(
      laneHeight: laneHeight ?? this.laneHeight,
      areaHeight: areaHeight ?? this.areaHeight,
      width: width ?? this.width,
      speed: speed ?? this.speed,
    );
  }
}

class DanmakuLaneAssignment {
  const DanmakuLaneAssignment({required this.lane, required this.top});

  final int lane;
  final double top;
}

/// 等速滚动弹幕的车道分配器。
///
/// 所有弹幕共用同一速度，因此一条弹幕的尾部清出右边缘后，车道即可复用；
/// 只需记录每条车道的 `freeAt`。没有空车道时返回 null，由调用方丢弃消息。
class DanmakuLaneAllocator {
  DanmakuLaneAllocator(DanmakuLaneLayout layout) : _layout = layout {
    _resizeLanes();
  }

  DanmakuLaneLayout _layout;
  List<double> _freeAt = <double>[];

  DanmakuLaneLayout get layout => _layout;

  int get laneCount => _freeAt.length;

  /// 应用新布局：速度变化时按比例重排剩余等待，视口变窄时把忙碌车道整体后移。
  void setLayout(DanmakuLaneLayout next, double nowMs) {
    final previous = _layout;
    _layout = next;
    _resizeLanes();
    if (previous.speed > 0 && next.speed > 0 && previous.speed != next.speed) {
      rescale(nowMs, previous.speed / next.speed);
    }
    if (next.width < previous.width && next.speed > 0) {
      delay((previous.width - next.width) / next.speed);
    }
  }

  int freeLanes(double nowMs) {
    var count = 0;
    for (final at in _freeAt) {
      if (at <= nowMs) count++;
    }
    return count;
  }

  /// 申请一条空闲车道；没有空闲车道时返回 null。
  DanmakuLaneAssignment? allocate(double nowMs, double messageWidth) {
    final speed = _layout.speed;
    if (_freeAt.isEmpty || speed <= 0) return null;
    final clearAfter = messageWidth / speed;
    for (var lane = 0; lane < _freeAt.length; lane++) {
      if (_freeAt[lane] <= nowMs) {
        _freeAt[lane] = nowMs + clearAfter;
        return DanmakuLaneAssignment(
          lane: lane,
          top: lane * _layout.laneHeight,
        );
      }
    }
    return null;
  }

  /// 海量弹幕模式：允许叠轨，直接占用指定车道。
  DanmakuLaneAssignment allocateMassive(
    double nowMs,
    double messageWidth,
    int lane,
  ) {
    final clamped = lane.clamp(0, math.max(0, _freeAt.length - 1)).toInt();
    final speed = _layout.speed;
    if (speed > 0) {
      _freeAt[clamped] = nowMs + messageWidth / speed;
    }
    return DanmakuLaneAssignment(
      lane: clamped,
      top: clamped * _layout.laneHeight,
    );
  }

  /// 速度变为原来的 `1 / factor` 时，剩余等待按同一比例缩放。
  void rescale(double nowMs, double factor) {
    if (factor <= 0 || !factor.isFinite) return;
    for (var lane = 0; lane < _freeAt.length; lane++) {
      final at = _freeAt[lane];
      if (at > nowMs) _freeAt[lane] = nowMs + (at - nowMs) * factor;
    }
  }

  /// 把所有已占用车道整体后移。
  void delay(double milliseconds) {
    if (milliseconds <= 0) return;
    for (var lane = 0; lane < _freeAt.length; lane++) {
      if (_freeAt[lane] > 0) _freeAt[lane] += milliseconds;
    }
  }

  /// 某条车道上的弹幕变宽后，尾部更晚离开右边缘。
  void extend(int lane, double milliseconds) {
    if (lane < 0 || lane >= _freeAt.length || milliseconds <= 0) return;
    _freeAt[lane] += milliseconds;
  }

  /// 保证车道的占用至少延续到 [atMs]。
  void ensureFreeAt(int lane, double atMs) {
    if (lane < 0 || lane >= _freeAt.length) return;
    if (_freeAt[lane] < atMs) _freeAt[lane] = atMs;
  }

  void reset() {
    for (var lane = 0; lane < _freeAt.length; lane++) {
      _freeAt[lane] = 0;
    }
  }

  void _resizeLanes() {
    final count = _layout.laneHeight > 0 && _layout.areaHeight > 0
        ? math.max(1, (_layout.areaHeight / _layout.laneHeight).floor())
        : 1;
    if (count == _freeAt.length) return;
    final next = List<double>.filled(count, 0);
    final keep = math.min(count, _freeAt.length);
    for (var lane = 0; lane < keep; lane++) {
      next[lane] = _freeAt[lane];
    }
    _freeAt = next;
  }
}
