import 'dart:ui' show PointerDeviceKind;

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:canvas_danmaku/danmaku_menu.dart';
import 'package:canvas_danmaku/scroll_danmaku_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _option = DanmakuOption(
  fontSize: 16,
  mergeDuplicates: false,
  maxSpawnPerFrame: 2,
  duration: 10,
);

Future<DanmakuController<String>> pumpScreen(
  WidgetTester tester, {
  DanmakuOption option = _option,
  ValueChanged<String>? onBlock,
}) async {
  DanmakuController<String> controller = DanmakuController<String>(
    addDanmaku: (_) {},
    updateOption: (_) {},
    pause: () {},
    resume: () {},
    clear: () {},
    getOption: () => option,
    isRunning: () => true,
    findDanmaku: (_) => const [],
    findSingleDanmaku: (_) => null,
    getViewWidth: () => 0,
    getViewHeight: () => 0,
    scrollDanmaku: const [],
    staticDanmaku: const [],
    specialDanmaku: const [],
  );

  await tester.pumpWidget(
    MaterialApp(
      // 3.50 起 Material 3 默认用 InkSparkle，测试环境里
      // shaders/ink_sparkle.frag 无法通过引擎校验；这里关掉水波不影响被测行为。
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      home: SizedBox(
        width: 400,
        height: 300,
        child: DanmakuScreen<String>(
          createdController: (value) => controller = value,
          option: option,
          onBlockDanmaku: onBlock,
        ),
      ),
    ),
  );
  await tester.pump();
  return controller;
}

void main() {
  testWidgets('到达只入队，一帧按上限批量生成，其余丢弃', (tester) async {
    final controller = await pumpScreen(tester);
    expect(controller.stats, isNotNull);

    for (var i = 0; i < 100; i++) {
      controller.addDanmaku(DanmakuContentItem<String>('message-$i'));
    }

    expect(controller.stats!.queued, 100);
    expect(controller.stats!.spawned, 0);
    expect(controller.stats!.cacheMisses, 0);

    await tester.pump(const Duration(milliseconds: 16));

    expect(controller.stats!.spawned, 2);
    expect(controller.stats!.dropped, 98);
    expect(controller.scrollDanmaku.length, 2);
  });

  testWidgets('逐帧只重绘，不重建 CustomPaint', (tester) async {
    final controller = await pumpScreen(tester);
    controller.addDanmaku(DanmakuContentItem<String>('one'));
    await tester.pump(const Duration(milliseconds: 16));

    final finder = find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint && widget.painter is ScrollDanmakuPainter,
    );
    final before = tester.widget<CustomPaint>(finder);

    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    final after = tester.widget<CustomPaint>(finder);
    expect(identical(before, after), isTrue);
  });

  testWidgets('相同文本命中位图缓存', (tester) async {
    final controller = await pumpScreen(tester);
    controller.addDanmaku(DanmakuContentItem<String>('same'));
    await tester.pump(const Duration(milliseconds: 16));
    controller.addDanmaku(DanmakuContentItem<String>('same'));
    await tester.pump(const Duration(milliseconds: 16));

    expect(controller.stats!.cacheMisses, 1);
    expect(controller.stats!.cacheHits, 1);
    expect(controller.scrollDanmaku.length, 2);
  });

  testWidgets('同文本合并为 ×N 并保持一个在屏条目', (tester) async {
    final controller = await pumpScreen(
      tester,
      option: const DanmakuOption(
        fontSize: 16,
        mergeDuplicates: true,
        maxSpawnPerFrame: 8,
        duration: 10,
      ),
    );
    controller.addDanmaku(DanmakuContentItem<String>('same'));
    await tester.pump(const Duration(milliseconds: 16));
    expect(controller.scrollDanmaku.length, 1);

    final item = controller.scrollDanmaku.single;
    final widthBefore = item.width;

    controller.addDanmaku(DanmakuContentItem<String>('same'));
    await tester.pump(const Duration(milliseconds: 16));

    expect(controller.scrollDanmaku.length, 1);
    expect(item.mergeCount, 2);
    expect(item.width, greaterThan(widthBefore));
    expect(controller.stats!.merged, 1);
  });

  testWidgets('悬停/点击暂停并显示菜单，空白点击恢复', (tester) async {
    final controller = await pumpScreen(tester);
    controller.addDanmaku(DanmakuContentItem<String>(
      'clickable',
      userName: 'tester',
    ));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 1000));

    final item = controller.scrollDanmaku.single;
    final x = item.xAt(item.startTick + 1000);
    final point = Offset(x + 4, item.top + 4);

    await tester.tapAt(point);
    await tester.pump();

    expect(item.held, isTrue);
    expect(find.byType(DanmakuMenu), findsOneWidget);
    expect(find.text('复制'), findsOneWidget);
    expect(find.text('关闭'), findsOneWidget);

    await tester.tapAt(const Offset(4, 4));
    await tester.pump();

    expect(item.held, isFalse);
    expect(find.byType(DanmakuMenu), findsNothing);
  });

  testWidgets('修改字号会清空缓存与在屏条目', (tester) async {
    final controller = await pumpScreen(tester);
    controller.addDanmaku(DanmakuContentItem<String>('style'));
    await tester.pump(const Duration(milliseconds: 16));
    expect(controller.scrollDanmaku.length, 1);

    controller.updateOption(
      _option.copyWith(fontSize: 22),
    );
    await tester.pump(const Duration(milliseconds: 16));

    expect(controller.scrollDanmaku, isEmpty);
    controller.addDanmaku(DanmakuContentItem<String>('style'));
    await tester.pump(const Duration(milliseconds: 16));
    expect(controller.stats!.cacheMisses, 2);
  });

  testWidgets('菜单屏蔽回调移除同文本在屏条目', (tester) async {
    String? blocked;
    final controller = await pumpScreen(
      tester,
      onBlock: (text) => blocked = text,
    );
    controller.addDanmaku(DanmakuContentItem<String>('blocked-text'));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 1000));

    final item = controller.scrollDanmaku.single;
    await tester.tapAt(
      Offset(item.xAt(item.startTick + 1000) + 4, item.top + 4),
    );
    await tester.pump();
    expect(find.text('屏蔽此弹幕'), findsOneWidget);

    await tester.tap(find.text('屏蔽此弹幕'));
    await tester.pump();

    expect(blocked, 'blocked-text');
    expect(controller.scrollDanmaku, isEmpty);
    expect(find.byType(DanmakuMenu), findsNothing);
  });

  testWidgets('非条目区域不拦截下层点击', (tester) async {
    var backgroundTaps = 0;
    DanmakuController<String>? controller;
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => backgroundTaps++,
                child: const ColoredBox(color: Colors.black),
              ),
            ),
            Positioned.fill(
              child: DanmakuScreen<String>(
                createdController: (value) => controller = value,
                option: _option,
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(controller, isNotNull);

    await tester.tapAt(const Offset(10, 10));
    await tester.pump();
    expect(backgroundTaps, 1);
  });

  testWidgets('顶部弹幕按静态时长移除', (tester) async {
    final controller = await pumpScreen(
      tester,
      option: const DanmakuOption(
        fontSize: 16,
        staticDuration: 1,
        mergeDuplicates: false,
      ),
    );
    controller.addDanmaku(DanmakuContentItem<String>(
      'top',
      type: DanmakuItemType.top,
    ));
    await tester.pump(const Duration(milliseconds: 16));
    expect(controller.staticDanmaku.length, 1);

    await tester.pump(const Duration(milliseconds: 1100));
    expect(controller.staticDanmaku, isEmpty);
  });

  testWidgets('隐藏滚动弹幕时清空在屏条目', (tester) async {
    final controller = await pumpScreen(tester);
    controller.addDanmaku(DanmakuContentItem<String>('scroll'));
    await tester.pump(const Duration(milliseconds: 16));
    expect(controller.scrollDanmaku.length, 1);

    controller.updateOption(_option.copyWith(hideScroll: true));
    await tester.pump(const Duration(milliseconds: 16));
    expect(controller.scrollDanmaku, isEmpty);
  });

  testWidgets('关闭合并开关后同文本重新独立显示', (tester) async {
    final controller = await pumpScreen(
      tester,
      option: const DanmakuOption(
        fontSize: 16,
        mergeDuplicates: true,
        maxSpawnPerFrame: 8,
      ),
    );
    controller.addDanmaku(DanmakuContentItem<String>('same'));
    await tester.pump(const Duration(milliseconds: 16));
    controller.addDanmaku(DanmakuContentItem<String>('same'));
    await tester.pump(const Duration(milliseconds: 16));
    expect(controller.scrollDanmaku.length, 1);

    controller.updateOption(
      const DanmakuOption(
        fontSize: 16,
        mergeDuplicates: false,
        maxSpawnPerFrame: 8,
      ),
    );
    controller.addDanmaku(DanmakuContentItem<String>('same'));
    await tester.pump(const Duration(milliseconds: 16));
    expect(controller.scrollDanmaku.length, 2);
  });

  testWidgets('合成密集负载：每帧受 spawn 上限约束且同车道不重叠', (tester) async {
    final controller = await pumpScreen(
      tester,
      option: const DanmakuOption(
        fontSize: 16,
        mergeDuplicates: false,
        maxSpawnPerFrame: 4,
      ),
    );

    for (var frame = 0; frame < 600; frame++) {
      final spawnedBefore = controller.stats!.spawned;
      controller.addDanmaku(DanmakuContentItem<String>('load-a-$frame'));
      controller.addDanmaku(DanmakuContentItem<String>('load-b-$frame'));
      await tester.pump(const Duration(milliseconds: 16));
      final spawned = controller.stats!.spawned - spawnedBefore;
      expect(spawned, lessThanOrEqualTo(4));

      final items = controller.scrollDanmaku;
      for (final later in items) {
        for (final earlier in items) {
          if (earlier.lane != later.lane ||
              earlier.startTick >= later.startTick) {
            continue;
          }
          expect(
            earlier.xAt(later.startTick) + earlier.width,
            lessThanOrEqualTo(later.from + 0.5),
          );
        }
      }
    }

    expect(controller.stats!.dropped, greaterThan(0));
  });

  testWidgets('变速后位置连续，暂停不改写起点', (tester) async {
    final controller = await pumpScreen(tester);
    controller.addDanmaku(DanmakuContentItem<String>('speed'));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 500));

    final item = controller.scrollDanmaku.single;
    final oldStart = item.startTick;
    final oldSpeed = item.speed;
    final probeTick = oldStart + 500;
    final before = item.from - (probeTick - oldStart) * oldSpeed;

    controller.updateOption(_option.copyWith(duration: 5));
    await tester.pump(const Duration(milliseconds: 16));

    final newSpeed = item.speed;
    final newStart = item.startTick;
    final after = item.from - (probeTick - newStart) * newSpeed;
    expect(after, closeTo(before, 0.5));

    final startBeforePause = item.startTick;
    controller.pause();
    await tester.pump(const Duration(milliseconds: 1000));
    controller.resume();
    await tester.pump(const Duration(milliseconds: 16));
    expect(item.startTick, startBeforePause);
  });

  testWidgets('同帧多条同文本合并为 ×N', (tester) async {
    final controller = await pumpScreen(
      tester,
      option: const DanmakuOption(
        fontSize: 16,
        mergeDuplicates: true,
        maxSpawnPerFrame: 8,
      ),
    );
    for (var i = 0; i < 3; i++) {
      controller.addDanmaku(DanmakuContentItem<String>('same-frame'));
    }
    await tester.pump(const Duration(milliseconds: 16));

    expect(controller.scrollDanmaku.length, 1);
    expect(controller.scrollDanmaku.single.mergeCount, 3);
  });

  testWidgets('合并加宽不会与同车道后继条目重叠', (tester) async {
    final controller = await pumpScreen(
      tester,
      option: const DanmakuOption(
        fontSize: 16,
        mergeDuplicates: true,
        maxSpawnPerFrame: 8,
      ),
    );
    controller.addDanmaku(DanmakuContentItem<String>('same'));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 1500));

    controller.addDanmaku(DanmakuContentItem<String>('next'));
    await tester.pump(const Duration(milliseconds: 16));
    controller.addDanmaku(DanmakuContentItem<String>('same'));
    await tester.pump(const Duration(milliseconds: 16));

    final items = controller.scrollDanmaku;
    final original = items.firstWhere((item) => item.content.text == 'same');
    final next = items.firstWhere((item) => item.content.text == 'next');
    expect(original.lane, next.lane);
    final gap = next.from - (original.xAt(next.startTick) + original.width);
    expect(gap, greaterThanOrEqualTo(-0.5));
    expect(gap, lessThanOrEqualTo(96.0));
  });

  testWidgets('暂停条目所在车道不会被新弹幕复用', (tester) async {
    final controller = await pumpScreen(tester);
    controller.addDanmaku(DanmakuContentItem<String>('held'));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 1000));

    final held = controller.scrollDanmaku.single;
    await tester.tapAt(
      Offset(held.xAt(held.startTick + 1000) + 4, held.top + 4),
    );
    await tester.pump();
    expect(held.held, isTrue);

    await tester.pump(const Duration(seconds: 6));
    controller.addDanmaku(DanmakuContentItem<String>('new-arrival'));
    await tester.pump(const Duration(milliseconds: 16));

    final arrived = controller.scrollDanmaku
        .firstWhere((item) => item.content.text == 'new-arrival');
    expect(arrived.lane, isNot(held.lane));
  });

  testWidgets('safeArea 为底部弹幕保留最底两条轨道', (tester) async {
    final controller = await pumpScreen(
      tester,
      option: const DanmakuOption(
        fontSize: 16,
        safeArea: true,
        mergeDuplicates: false,
      ),
    );
    controller.addDanmaku(DanmakuContentItem<String>(
      'bottom',
      type: DanmakuItemType.bottom,
    ));
    await tester.pump(const Duration(milliseconds: 16));

    final item = controller.staticDanmaku.single;
    expect(item.yPosition, greaterThan(25.0));
  });

  testWidgets('单帧合并重建受 maxSpawnPerFrame 约束', (tester) async {
    final controller = await pumpScreen(
      tester,
      option: const DanmakuOption(
        fontSize: 16,
        mergeDuplicates: true,
        maxSpawnPerFrame: 8,
      ),
    );
    for (var round = 0; round < 3; round++) {
      for (var index = 0; index < 6; index++) {
        controller.addDanmaku(DanmakuContentItem<String>(
          'group-${round * 6 + index}',
        ));
      }
      await tester.pump(const Duration(milliseconds: 16));
    }

    final texts =
        controller.scrollDanmaku.map((item) => item.content.text).toList();
    final missesBefore = controller.stats!.cacheMisses;
    for (final text in texts) {
      controller.addDanmaku(DanmakuContentItem<String>(text));
    }
    await tester.pump(const Duration(milliseconds: 16));

    final built = controller.stats!.cacheMisses - missesBefore;
    expect(built, lessThanOrEqualTo(8));
  });

  testWidgets('关闭再开启合并不复用旧组标识', (tester) async {
    final controller = await pumpScreen(
      tester,
      option: const DanmakuOption(
        fontSize: 16,
        mergeDuplicates: true,
        maxSpawnPerFrame: 8,
      ),
    );
    controller.addDanmaku(DanmakuContentItem<String>('old'));
    await tester.pump(const Duration(milliseconds: 16));
    final oldItem = controller.scrollDanmaku.single;
    final oldGroup = oldItem.mergeGroupId;

    controller.updateOption(
      const DanmakuOption(
        fontSize: 16,
        mergeDuplicates: false,
        maxSpawnPerFrame: 8,
      ),
    );
    await tester.pump(const Duration(milliseconds: 16));
    controller.updateOption(
      const DanmakuOption(
        fontSize: 16,
        mergeDuplicates: true,
        maxSpawnPerFrame: 8,
      ),
    );
    await tester.pump(const Duration(milliseconds: 16));

    controller.addDanmaku(DanmakuContentItem<String>('new'));
    await tester.pump(const Duration(milliseconds: 16));
    final newItem = controller.scrollDanmaku
        .firstWhere((item) => item.content.text == 'new');
    expect(newItem.mergeGroupId, isNot(oldGroup));

    controller.addDanmaku(DanmakuContentItem<String>('new'));
    await tester.pump(const Duration(milliseconds: 16));
    expect(newItem.mergeCount, 2);
    expect(oldItem.mergeCount, 1);
  });

  testWidgets('指针在空白处持续移动仍会在 220ms 后恢复', (tester) async {
    final controller = await pumpScreen(tester);
    controller.addDanmaku(DanmakuContentItem<String>('hover'));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 1000));

    final item = controller.scrollDanmaku.single;
    await tester.tapAt(
      Offset(item.xAt(item.startTick + 1000) + 4, item.top + 4),
    );
    await tester.pump();
    expect(item.held, isTrue);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(2, 2));
    await tester.pump();
    for (var i = 0; i < 20; i++) {
      await mouse.moveTo(Offset(3.0 + i, 3));
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(item.held, isFalse);
    expect(find.byType(DanmakuMenu), findsNothing);
    await mouse.removePointer();
  });
}
