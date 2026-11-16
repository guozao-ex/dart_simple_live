import 'dart:collection';

import 'package:canvas_danmaku/models/danmaku_content_item.dart';

/// 到达队列中的一条消息。
///
/// [mergeGroupId] 仅在同文本合并开启时存在；[mergeCount] 为入队时的计数。
class DanmakuQueueEntry<T> {
  const DanmakuQueueEntry({
    required this.content,
    this.mergeGroupId,
    this.mergeCount = 1,
  });

  final DanmakuContentItem<T> content;
  final String? mergeGroupId;
  final int mergeCount;
}

/// 帧间到达队列。
///
/// 消息到达时只入队，不排版、不光栅化；超过容量时丢弃最旧的消息。
class DanmakuQueue<T> {
  DanmakuQueue({this.capacity = 2000});

  final int capacity;
  final ListQueue<DanmakuQueueEntry<T>> _entries =
      ListQueue<DanmakuQueueEntry<T>>();

  int dropped = 0;

  int get length => _entries.length;

  bool get isEmpty => _entries.isEmpty;

  bool get isNotEmpty => _entries.isNotEmpty;

  void push(DanmakuQueueEntry<T> entry) {
    while (_entries.length >= capacity) {
      _entries.removeFirst();
      dropped++;
    }
    _entries.addLast(entry);
  }

  List<DanmakuQueueEntry<T>> drain() {
    if (_entries.isEmpty) return const [];
    final drained = _entries.toList(growable: false);
    _entries.clear();
    return drained;
  }

  void clear() {
    _entries.clear();
  }
}
