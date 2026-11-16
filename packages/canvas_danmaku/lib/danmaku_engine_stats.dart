/// 弹幕引擎的运行时统计，仅供调试与验收读取。
class DanmakuEngineStats {
  int queued = 0;
  int spawned = 0;
  int dropped = 0;
  int cacheHits = 0;
  int cacheMisses = 0;
  int merged = 0;
  int visible = 0;

  void reset() {
    queued = 0;
    spawned = 0;
    dropped = 0;
    cacheHits = 0;
    cacheMisses = 0;
    merged = 0;
    visible = 0;
  }

  @override
  String toString() {
    return 'DanmakuEngineStats(queued: $queued, spawned: $spawned, '
        'dropped: $dropped, cacheHits: $cacheHits, '
        'cacheMisses: $cacheMisses, merged: $merged, visible: $visible)';
  }
}
