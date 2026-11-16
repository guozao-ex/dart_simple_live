import 'package:canvas_danmaku/danmaku_queue.dart';
import 'package:canvas_danmaku/models/danmaku_content_item.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('按到达顺序 drain，并清空队列', () {
    final queue = DanmakuQueue<String>(capacity: 10);
    queue.push(DanmakuQueueEntry<String>(
      content: DanmakuContentItem<String>('a'),
    ));
    queue.push(DanmakuQueueEntry<String>(
      content: DanmakuContentItem<String>('b'),
    ));

    final drained = queue.drain();
    expect(drained.map((entry) => entry.content.text), ['a', 'b']);
    expect(queue.isEmpty, isTrue);
    expect(queue.drain(), isEmpty);
  });

  test('超出容量时丢弃最旧的消息', () {
    final queue = DanmakuQueue<String>(capacity: 2);
    queue.push(DanmakuQueueEntry<String>(
      content: DanmakuContentItem<String>('old'),
    ));
    queue.push(DanmakuQueueEntry<String>(
      content: DanmakuContentItem<String>('keep1'),
    ));
    queue.push(DanmakuQueueEntry<String>(
      content: DanmakuContentItem<String>('keep2'),
    ));

    expect(queue.length, 2);
    expect(queue.dropped, 1);
    expect(
      queue.drain().map((entry) => entry.content.text),
      ['keep1', 'keep2'],
    );
  });

  test('保留合并组信息', () {
    final queue = DanmakuQueue<String>();
    queue.push(DanmakuQueueEntry<String>(
      content: DanmakuContentItem<String>('same'),
      mergeGroupId: 'g1',
      mergeCount: 3,
    ));
    final entry = queue.drain().single;
    expect(entry.mergeGroupId, 'g1');
    expect(entry.mergeCount, 3);
  });
}
