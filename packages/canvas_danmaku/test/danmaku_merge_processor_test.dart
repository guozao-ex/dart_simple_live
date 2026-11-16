import 'package:canvas_danmaku/danmaku_merge_processor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('窗口内同文本合并计数', () {
    final merge = DanmakuMergeProcessor(windowMilliseconds: 8000);
    final first = merge.process('666', null, 0)!;
    expect(first.kind, DanmakuMergeKind.show);
    expect(first.count, 1);

    final second = merge.process('666', null, 100)!;
    expect(second.kind, DanmakuMergeKind.merge);
    expect(second.groupId, first.groupId);
    expect(second.count, 2);

    final third = merge.process('666', null, 7999)!;
    expect(third.kind, DanmakuMergeKind.merge);
    expect(third.count, 3);
  });

  test('窗口到期后重新从 1 计数', () {
    final merge = DanmakuMergeProcessor(windowMilliseconds: 8000);
    merge.process('same', null, 0);
    final after = merge.process('same', null, 8001)!;
    expect(after.kind, DanmakuMergeKind.show);
    expect(after.count, 1);
  });

  test('不同文本独立成组', () {
    final merge = DanmakuMergeProcessor();
    final a = merge.process('a', null, 0)!;
    final b = merge.process('b', null, 0)!;
    expect(a.groupId, isNot(b.groupId));
    expect(merge.trackedGroups, 2);
  });

  test('平台聚合计数不参与合并', () {
    final merge = DanmakuMergeProcessor();
    expect(merge.process('same', 5, 0), isNull);
    expect(merge.trackedGroups, 0);
  });

  test('容量上限淘汰最旧组', () {
    final merge = DanmakuMergeProcessor(windowMilliseconds: 60000, capacity: 2);
    merge.process('a', null, 0);
    merge.process('b', null, 0);
    merge.process('c', null, 0);
    expect(merge.trackedGroups, 2);
    // a 已被淘汰，重新出现时是新的显示项。
    final a = merge.process('a', null, 10)!;
    expect(a.kind, DanmakuMergeKind.show);
    expect(a.count, 1);
  });

  test('reset 清空所有组', () {
    final merge = DanmakuMergeProcessor();
    merge.process('a', null, 0);
    merge.reset();
    expect(merge.trackedGroups, 0);
    expect(merge.process('a', null, 1)!.count, 1);
  });
}
