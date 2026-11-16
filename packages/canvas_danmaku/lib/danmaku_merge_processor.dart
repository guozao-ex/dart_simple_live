/// 同文本合并计数的处理结果。
enum DanmakuMergeKind { show, merge }

class DanmakuMergeDecision {
  const DanmakuMergeDecision({
    required this.kind,
    required this.groupId,
    required this.count,
  });

  final DanmakuMergeKind kind;
  final String groupId;
  final int count;
}

class _DanmakuMergeGroup {
  _DanmakuMergeGroup({required this.id, required this.expiresAt});

  final String id;
  int count = 1;
  double expiresAt;
}

/// 同文本弹幕的合并计数。
///
/// 窗口内同文本只保留一个显示条目并递增计数；超过窗口后重新从 1 计数。
/// 带平台聚合计数（[existingCount] 非空）的消息不参与合并。
class DanmakuMergeProcessor {
  DanmakuMergeProcessor({this.windowMilliseconds = 8000, this.capacity = 2000});

  final int windowMilliseconds;
  final int capacity;

  final Map<String, _DanmakuMergeGroup> _groups =
      <String, _DanmakuMergeGroup>{};
  int _sequence = 0;
  double _nextPruneAt = 0;

  int get trackedGroups => _groups.length;

  /// 处理一条滚动弹幕。
  ///
  /// 返回 null 表示不参与合并，调用方按普通消息显示。
  DanmakuMergeDecision? process(String text, int? existingCount, int nowMs) {
    if (existingCount != null) return null;

    if (nowMs >= _nextPruneAt) {
      _prune(nowMs.toDouble());
      _nextPruneAt = nowMs + 500.0;
    }

    final existing = _groups[text];
    if (existing != null && existing.expiresAt > nowMs) {
      existing.count += 1;
      return DanmakuMergeDecision(
        kind: DanmakuMergeKind.merge,
        groupId: existing.id,
        count: existing.count,
      );
    }
    if (existing != null) _groups.remove(text);

    while (capacity > 0 && _groups.length >= capacity) {
      final oldestKey = _groups.keys.first;
      _groups.remove(oldestKey);
    }

    final group = _DanmakuMergeGroup(
      id: 'danmaku-group-${++_sequence}',
      expiresAt: nowMs.toDouble() + windowMilliseconds,
    );
    _groups[text] = group;
    return DanmakuMergeDecision(
      kind: DanmakuMergeKind.show,
      groupId: group.id,
      count: 1,
    );
  }

  void reset() {
    _groups.clear();
    _nextPruneAt = 0;
  }

  /// 当前窗口内仍有效的合并组标识，用于清理 pending 计数。
  Set<String> activeGroupIds(int nowMs) {
    _prune(nowMs.toDouble());
    return _groups.values.map((group) => group.id).toSet();
  }

  void _prune(double nowMs) {
    _groups.removeWhere((_, group) => group.expiresAt <= nowMs);
  }
}
