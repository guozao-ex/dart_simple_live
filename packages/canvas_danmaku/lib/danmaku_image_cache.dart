import 'dart:ui' as ui;

/// 一张已栅格化的弹幕位图及其逻辑尺寸。
class DanmakuImageEntry {
  DanmakuImageEntry({
    required this.key,
    required this.image,
    required this.width,
    required this.height,
  });

  final String key;
  final ui.Image image;
  final double width;
  final double height;

  int refs = 0;
  int lastUsed = 0;

  int get bytes => image.width * image.height * 4;
}

/// 文本位图缓存。
///
/// 缓存独占 [ui.Image] 的释放权，在屏条目只持有引用；引用计数大于 0 的条目
/// 不会被淘汰。缓存按字节预算与条数上限做 LRU。
class DanmakuImageCache {
  DanmakuImageCache({this.maxBytes = 24 * 1024 * 1024, this.maxEntries = 512});

  final int maxBytes;
  final int maxEntries;

  final Map<String, DanmakuImageEntry> _entries = <String, DanmakuImageEntry>{};

  int _bytes = 0;
  int hits = 0;
  int misses = 0;

  int get length => _entries.length;

  int get bytes => _bytes;

  /// 取用一张位图：命中时复用并增加引用，未命中时调用 [build]。
  DanmakuImageEntry acquire(
    String key,
    DanmakuImageEntry Function() build, {
    required int tick,
  }) {
    final existing = _entries.remove(key);
    if (existing != null) {
      existing
        ..lastUsed = tick
        ..refs += 1;
      _entries[key] = existing;
      hits++;
      return existing;
    }

    misses++;
    final entry = build()
      ..lastUsed = tick
      ..refs = 1;
    _entries[entry.key] = entry;
    _bytes += entry.bytes;
    _evictIfNeeded();
    return entry;
  }

  void release(DanmakuImageEntry entry) {
    if (entry.refs > 0) entry.refs -= 1;
  }

  /// 清空缓存。调用方必须先移除所有在屏条目，确保没有未释放的引用。
  void clear() {
    for (final entry in _entries.values) {
      entry.image.dispose();
    }
    _entries.clear();
    _bytes = 0;
  }

  void _evictIfNeeded() {
    while (_entries.length > maxEntries || _bytes > maxBytes) {
      DanmakuImageEntry? victimKeyEntry;
      String? victimKey;
      var oldest = 1 << 62;
      for (final entry in _entries.entries) {
        if (entry.value.refs > 0) continue;
        if (entry.value.lastUsed < oldest) {
          oldest = entry.value.lastUsed;
          victimKey = entry.key;
          victimKeyEntry = entry.value;
        }
      }
      if (victimKey == null || victimKeyEntry == null) return;
      _entries.remove(victimKey);
      _bytes -= victimKeyEntry.bytes;
      victimKeyEntry.image.dispose();
    }
  }
}
