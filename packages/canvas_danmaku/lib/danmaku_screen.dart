import 'dart:async';
import 'dart:math' as math;

import 'package:canvas_danmaku/danmaku_controller.dart';
import 'package:canvas_danmaku/danmaku_engine_stats.dart';
import 'package:canvas_danmaku/danmaku_image_cache.dart';
import 'package:canvas_danmaku/danmaku_lane_allocator.dart';
import 'package:canvas_danmaku/danmaku_menu.dart';
import 'package:canvas_danmaku/danmaku_merge_processor.dart';
import 'package:canvas_danmaku/danmaku_queue.dart';
import 'package:canvas_danmaku/models/danmaku_content_item.dart';
import 'package:canvas_danmaku/models/danmaku_item.dart';
import 'package:canvas_danmaku/models/danmaku_option.dart';
import 'package:canvas_danmaku/scroll_danmaku_painter.dart';
import 'package:canvas_danmaku/special_danmaku_painter.dart';
import 'package:canvas_danmaku/static_danmaku_painter.dart';
import 'package:canvas_danmaku/utils/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

class DanmakuScreen<T> extends StatefulWidget {
  // 创建Screen后返回控制器
  final ValueChanged<DanmakuController<T>> createdController;
  final DanmakuOption option;

  /// 「屏蔽此弹幕」回调；为空时菜单不显示该按钮。
  final ValueChanged<String>? onBlockDanmaku;

  /// 复制等操作的提示回调。
  final ValueChanged<String>? onNotice;

  const DanmakuScreen({
    required this.createdController,
    required this.option,
    this.onBlockDanmaku,
    this.onNotice,
    super.key,
  });

  @override
  State<DanmakuScreen<T>> createState() => _DanmakuScreenState<T>();
}

class _DanmakuScreenState<T> extends State<DanmakuScreen<T>>
    with SingleTickerProviderStateMixin {
  static const int _leaveDelayMilliseconds = 220;
  static const double _mergeBadgeReserve = 48;

  /// 视图宽度
  double _viewWidth = 0;
  double _viewHeight = 0;
  double devicePixelRatio = 1;

  /// 弹幕配置
  late final ValueNotifier<DanmakuOption> _optionNotifier;
  DanmakuOption get _option => _optionNotifier.value;

  /// 滚动弹幕
  final _scrollDanmakuItems = <DanmakuItem<T>>[];

  /// 静态弹幕
  final _staticDanmakuItems = ListValueNotifier(<DanmakuItem<T>>[]);

  /// 高级弹幕
  final _specialDanmakuItems = <DanmakuItem<T>>[];

  /// 帧间到达队列
  final _queue = DanmakuQueue<T>();

  /// 文本位图缓存
  late final DanmakuImageCache _cache;

  /// 车道分配器
  late final DanmakuLaneAllocator _lanes;

  /// 合并计数
  late final DanmakuMergeProcessor _merge;

  final _stats = DanmakuEngineStats();
  int _engineDropped = 0;

  /// 弹幕高度
  late double _danmakuHeight;

  /// 静态弹幕轨道位置
  late List<double> _trackYPositions;

  late final _random = math.Random();

  late final Ticker _ticker;
  late final ValueNotifier<int> _frameNotifier;
  late final ValueNotifier<double> _opacityNotifier;
  late int _lastTick = 0;
  int _tick = 0;

  /// 运行状态
  bool _running = true;

  /// 当前暂停/菜单条目
  DanmakuItem<T>? _heldItem;
  DanmakuItem<T>? _menuItem;
  Timer? _resumeTimer;
  bool _menuHovering = false;
  bool _menuPointerDown = false;
  final _pendingMergeCounts = <String, int>{};
  final _pendingRefits = <String, int>{};
  int _nextPendingPruneAt = 0;

  @override
  void initState() {
    super.initState();
    _optionNotifier = ValueNotifier(widget.option);
    DmUtils.updateSelfSendPaint(_option.strokeWidth);

    _danmakuHeight = _textPainter.height;
    _cache = DanmakuImageCache();
    _merge = DanmakuMergeProcessor();
    _lanes = DanmakuLaneAllocator(
      DanmakuLaneLayout(
        laneHeight: _danmakuHeight,
        areaHeight: _danmakuHeight,
        width: 0,
        speed: 0,
      ),
    );
    _trackYPositions = <double>[0];

    _ticker = createTicker(_tickFrame);
    _frameNotifier = ValueNotifier<int>(0);
    _opacityNotifier = ValueNotifier<double>(_option.opacity);
    _optionNotifier.addListener(_syncOpacity);

    widget.createdController(
      DanmakuController<T>(
        addDanmaku: _addDanmaku,
        updateOption: _updateOption,
        pause: _pause,
        resume: _resume,
        clear: _clear,
        getOption: () => _option,
        isRunning: () => _running,
        findDanmaku: findDanmaku,
        findSingleDanmaku: findSingleDanmaku,
        getViewWidth: () => _viewWidth,
        getViewHeight: () => _viewHeight,
        scrollDanmaku: _scrollDanmakuItems,
        staticDanmaku: _staticDanmakuItems.value,
        specialDanmaku: _specialDanmakuItems,
        getStats: _statsSnapshot,
      ),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextRatio = MediaQuery.devicePixelRatioOf(context);
    if (nextRatio == devicePixelRatio) return;
    devicePixelRatio = nextRatio;
    _cancelResume();
    _heldItem = null;
    _menuItem = null;
    _clearDanmakus();
    _cache.clear();
    _lanes.reset();
    _merge.reset();
    _pendingMergeCounts.clear();
    _updateLayout();
    _frameNotifier.refresh();
  }

  TextPainter get _textPainter => TextPainter(
        text: TextSpan(
          text: '弹幕',
          style: TextStyle(
            fontSize: _option.fontSize,
            height: _option.lineHeight,
            fontFamily: _option.fontFamily,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

  bool get _hasWork =>
      _queue.isNotEmpty ||
      _scrollDanmakuItems.isNotEmpty ||
      _staticDanmakuItems.value.isNotEmpty ||
      _specialDanmakuItems.isNotEmpty;

  void _tickFrame(Duration elapsed) {
    final now = _lastTick + elapsed.inMilliseconds;
    _tick = now;
    _reserveHeldLane(now);
    _spawn(now, imageBudget: math.max(1, _option.maxSpawnPerFrame));
    _sweep(now);
    _frameNotifier.value = now;
    if (!_hasWork && _ticker.isActive) {
      _lastTick = now;
      _ticker.stop();
    }
  }

  void _reserveHeldLane(int now) {
    final held = _heldItem;
    if (held == null) return;
    final remaining = held.remainingMilliseconds(now);
    if (remaining > 0) {
      _lanes.ensureFreeAt(held.lane, now + remaining + 1);
    }
  }

  void _spawn(int now, {required int imageBudget}) {
    if (now >= _nextPendingPruneAt) {
      final active = _merge.activeGroupIds(now);
      _pendingMergeCounts.removeWhere((id, _) => !active.contains(id));
      _pendingRefits.removeWhere((id, _) => !active.contains(id));
      _nextPendingPruneAt = now + 1000;
    }
    if (_viewWidth <= 0 || _lanes.layout.speed <= 0) {
      return;
    }
    var budget = imageBudget;
    final entries = _queue.drain();
    if (entries.isEmpty) {
      _applyPendingRefits(now, budget);
      return;
    }

    final scrolling = <DanmakuQueueEntry<T>>[];
    for (final entry in entries) {
      final content = entry.content;
      switch (content.type) {
        case DanmakuItemType.scroll:
          if (_option.hideScroll) continue;
          scrolling.add(entry);
        case DanmakuItemType.top:
          if (_option.hideTop) continue;
          if (budget > 0 && _spawnStatic(content, now)) {
            budget--;
          } else {
            _engineDropped++;
          }
        case DanmakuItemType.bottom:
          if (_option.hideBottom) continue;
          if (budget > 0 && _spawnStatic(content, now)) {
            budget--;
          } else {
            _engineDropped++;
          }
        case DanmakuItemType.special:
          if (_option.hideSpecial) continue;
          if (budget > 0 && _spawnSpecial(content, now)) {
            budget--;
          } else {
            _engineDropped++;
          }
      }
    }

    if (scrolling.isNotEmpty) {
      final ready = <DanmakuQueueEntry<T>>[];
      for (final entry in scrolling) {
        if (!_option.mergeDuplicates) {
          ready.add(entry);
          continue;
        }
        final decision = _merge.process(
          entry.content.text,
          entry.content.count,
          now,
        );
        if (decision == null) {
          ready.add(entry);
          continue;
        }
        if (decision.kind == DanmakuMergeKind.merge) {
          _stats.merged++;
          if (_findMergeTarget(decision.groupId) != null) {
            final previous = _pendingRefits[decision.groupId] ?? 1;
            if (decision.count > previous) {
              _pendingRefits[decision.groupId] = decision.count;
            }
          } else {
            final previous = _pendingMergeCounts[decision.groupId] ?? 1;
            if (decision.count > previous) {
              _pendingMergeCounts[decision.groupId] = decision.count;
            }
          }
          continue;
        }
        ready.add(
          DanmakuQueueEntry<T>(
            content: entry.content,
            mergeGroupId: decision.groupId,
            mergeCount: decision.count,
          ),
        );
      }

      if (ready.isNotEmpty) {
        final free = _lanes.freeLanes(now.toDouble());
        final massive = free <= 0 && _option.massiveMode;
        var spawnBudget = math.min(free, budget);
        if (spawnBudget <= 0) {
          if (budget <= 0) {
            _engineDropped += ready.length;
          } else if (massive) {
            spawnBudget = 1;
          } else {
            final selfIndex =
                ready.indexWhere((entry) => entry.content.selfSend);
            if (selfIndex >= 0) {
              _spawnScroll(
                ready[selfIndex],
                now,
                massive: true,
                forceLane: 0,
              );
              budget--;
              _engineDropped += ready.length - 1;
              spawnBudget = 0;
            } else {
              _engineDropped += ready.length;
            }
          }
        }
        if (spawnBudget > 0) {
          final take = math.min(spawnBudget, ready.length);
          for (var i = 0; i < take; i++) {
            _spawnScroll(ready[i], now, massive: massive);
          }
          budget -= take;
          if (ready.length > take) {
            _engineDropped += ready.length - take;
          }
        }
      }
    }

    _applyPendingRefits(now, budget);
  }

  DanmakuImageEntry _acquireImage(
    DanmakuContentItem<T> content,
    int mergeCount,
    int now,
  ) {
    final key = DmUtils.imageKey(
      content: content,
      fontSize: _option.fontSize,
      fontWeight: _option.fontWeight,
      mergeCount: mergeCount,
      strokeWidth: _option.strokeWidth,
      devicePixelRatio: devicePixelRatio,
      fontFamily: _option.fontFamily,
    );
    return _cache.acquire(key, () {
      final paragraph = DmUtils.generateParagraph(
        content: content,
        fontSize: _option.fontSize,
        fontWeight: _option.fontWeight,
        fontFamily: _option.fontFamily,
        mergeCount: mergeCount,
      );
      final bitmap = DmUtils.buildDanmakuImage(
        contentParagraph: paragraph,
        content: content,
        fontSize: _option.fontSize,
        fontWeight: _option.fontWeight,
        strokeWidth: _option.strokeWidth,
        devicePixelRatio: devicePixelRatio,
        fontFamily: _option.fontFamily,
        mergeCount: mergeCount,
      );
      paragraph.dispose();
      return DanmakuImageEntry(
        key: key,
        image: bitmap.image,
        width: bitmap.width,
        height: bitmap.height,
      );
    }, tick: now);
  }

  void _spawnScroll(
    DanmakuQueueEntry<T> entry,
    int now, {
    required bool massive,
    int? forceLane,
  }) {
    var mergeCount = math.max(1, entry.mergeCount);
    final groupId = entry.mergeGroupId;
    if (groupId != null) {
      final pending = _pendingMergeCounts.remove(groupId);
      if (pending != null && pending > mergeCount) mergeCount = pending;
    }
    final image = _acquireImage(entry.content, mergeCount, now);
    final reserve = _option.mergeDuplicates && entry.content.count == null
        ? _mergeBadgeReserve
        : 0.0;
    final allocationWidth = image.width + reserve;
    final assignment = massive
        ? _lanes.allocateMassive(
            now.toDouble(),
            allocationWidth,
            forceLane ?? _random.nextInt(math.max(1, _lanes.laneCount)),
          )
        : _lanes.allocate(now.toDouble(), allocationWidth);
    if (assignment == null) {
      _cache.release(image);
      _engineDropped++;
      return;
    }
    final item = DanmakuItem<T>(
      content: entry.content,
      width: image.width,
      height: image.height,
      xPosition: _viewWidth,
      yPosition: assignment.top,
      image: image.image,
      imageEntry: image,
      ownsImage: false,
      startTick: now,
      from: _viewWidth,
      speed: _lanes.layout.speed,
      lane: assignment.lane,
      top: assignment.top,
      mergeGroupId: groupId,
      mergeCount: mergeCount,
      drawTick: now,
    );
    _scrollDanmakuItems.add(item);
    _stats.spawned++;
  }

  DanmakuItem<T>? _findMergeTarget(String groupId) {
    for (final item in _scrollDanmakuItems) {
      if (item.mergeGroupId == groupId) return item;
    }
    return null;
  }

  void _applyPendingRefits(int now, int budget) {
    if (budget <= 0 || _pendingRefits.isEmpty) return;
    var remaining = budget;
    for (final id in _pendingRefits.keys.toList(growable: false)) {
      if (remaining <= 0) break;
      final count = _pendingRefits.remove(id);
      if (count == null) continue;
      if (_refitMerge(id, count, now)) remaining--;
    }
  }

  bool _refitMerge(String groupId, int count, int now) {
    final target = _findMergeTarget(groupId);
    if (target == null || count <= target.mergeCount) return false;

    final gapBefore = _gapToNext(target, now);
    final image = _acquireImage(target.content, count, now);
    final oldEntry = target.imageEntry;
    final oldWidth = target.width;
    target
      ..mergeCount = count
      ..image = image.image
      ..imageEntry = image
      ..width = image.width
      ..height = image.height;
    if (oldEntry != null) _cache.release(oldEntry);
    final extra = image.width - oldWidth;
    if (extra > 0 && _lanes.layout.speed > 0) {
      final overflow = math.max(0.0, extra - gapBefore);
      if (overflow > 0) {
        for (final other in _scrollDanmakuItems) {
          if (other.lane == target.lane && other.startTick > target.startTick) {
            other.from += overflow;
          }
        }
      }
      _lanes.extend(
        target.lane,
        (extra + overflow) / _lanes.layout.speed,
      );
    }
    return true;
  }

  /// 同车道中紧邻后一条弹幕与 [target] 尾部的当前/稳态间距。
  double _gapToNext(DanmakuItem<T> target, int now) {
    DanmakuItem<T>? next;
    for (final other in _scrollDanmakuItems) {
      if (other.lane != target.lane || other.startTick <= target.startTick) {
        continue;
      }
      if (next == null || other.startTick < next.startTick) next = other;
    }
    if (next == null) return double.infinity;
    final currentGap = next.xAt(now) - (target.xAt(now) + target.width);
    final speed = target.speed;
    if (speed <= 0) return currentGap;
    final steadyGap = next.from -
        target.from -
        target.width +
        (next.startTick - target.startTick) * speed;
    return math.min(currentGap, steadyGap);
  }

  bool _spawnStatic(DanmakuContentItem<T> content, int now) {
    if (_trackYPositions.isEmpty) return false;
    for (final y in _trackYPositions) {
      if (content.type == DanmakuItemType.bottom &&
          _option.safeArea &&
          y <= _danmakuHeight) {
        continue;
      }
      var occupied = false;
      for (final item in _staticDanmakuItems.value) {
        if (item.content.type == content.type && item.yPosition == y) {
          occupied = true;
          break;
        }
      }
      if (occupied) continue;

      final mergeCount = math.max(1, content.mergeCount);
      final image = _acquireImage(content, mergeCount, now);
      final item = DanmakuItem<T>(
        content: content,
        width: image.width,
        height: image.height,
        yPosition: y,
        image: image.image,
        imageEntry: image,
        ownsImage: false,
        startTick: now,
        mergeCount: mergeCount,
        drawTick: now,
      );
      _staticDanmakuItems.add(item);
      _stats.spawned++;
      return true;
    }
    return false;
  }

  bool _spawnSpecial(DanmakuContentItem<T> content, int now) {
    if (content is! SpecialDanmakuContentItem<T>) return false;
    final image = DmUtils.recordSpecialDanmakuImg(
      content: content,
      fontWeight: _option.fontWeight,
      strokeWidth: _option.strokeWidth,
      devicePixelRatio: devicePixelRatio,
      fontFamily: _option.fontFamily,
    );
    final item = DanmakuItem<T>(
      content: content,
      width: content.rect.width,
      height: content.rect.height,
      image: image,
      ownsImage: true,
      startTick: now,
      drawTick: now,
    );
    _specialDanmakuItems.add(item);
    _stats.spawned++;
    return true;
  }

  void _sweep(int now) {
    _scrollDanmakuItems.removeWhere((item) {
      if (item.held) return false;
      if (item.xAt(now) + item.width >= 0) return false;
      _releaseItem(item);
      return true;
    });
    _staticDanmakuItems.removeWhere((item) {
      if (now - item.startTick < _option.staticDurationInMilliseconds) {
        return false;
      }
      _releaseItem(item);
      return true;
    });
    _specialDanmakuItems.removeWhere((item) {
      if (!item.expired) return false;
      _releaseItem(item);
      return true;
    });
  }

  void _releaseItem(DanmakuItem<T> item) {
    final entry = item.imageEntry;
    if (entry != null) _cache.release(entry);
    item.dispose();
  }

  void _addDanmaku(DanmakuContentItem<T> content) {
    if (!mounted) return;
    switch (content.type) {
      case DanmakuItemType.scroll:
        if (_option.hideScroll) return;
      case DanmakuItemType.top:
        if (_option.hideTop) return;
      case DanmakuItemType.bottom:
        if (_option.hideBottom) return;
      case DanmakuItemType.special:
        if (_option.hideSpecial) return;
    }
    _queue.push(DanmakuQueueEntry<T>(content: content));
    if (_running && !_ticker.isActive) _ticker.start();
  }

  void _pause() {
    if (!mounted) return;
    _running = false;
    if (_ticker.isActive) {
      _lastTick = _tick;
      _ticker.stop();
    }
  }

  void _resume() {
    if (!mounted) return;
    _running = true;
    if (!_ticker.isActive && _hasWork) _ticker.start();
    _frameNotifier.refresh();
    _staticDanmakuItems.refresh();
  }

  void _clear() {
    if (!mounted) return;
    _cancelResume();
    _heldItem = null;
    if (_menuItem != null) {
      setState(() => _menuItem = null);
    }
    _clearDanmakus();
    _queue.clear();
    _merge.reset();
    _pendingMergeCounts.clear();
    _lanes.reset();
    _frameNotifier.refresh();
  }

  void _updateOption(DanmakuOption option) {
    if (_menuItem != null || _heldItem != null) _closeMenu();
    final old = _option;
    final styleChanged = option.fontSize != old.fontSize ||
        option.fontWeight != old.fontWeight ||
        option.fontFamily != old.fontFamily ||
        option.strokeWidth != old.strokeWidth ||
        option.lineHeight != old.lineHeight;
    final durationChanged = option.duration != old.duration;
    final clearScroll = option.hideScroll && !old.hideScroll;
    final clearTop = option.hideTop && !old.hideTop;
    final clearBottom = option.hideBottom && !old.hideBottom;
    final clearSpecial = option.hideSpecial && !old.hideSpecial;
    final mergeChanged = option.mergeDuplicates != old.mergeDuplicates;
    final oldSpeed = _lanes.layout.speed;

    _optionNotifier.value = option;

    if (styleChanged) {
      DmUtils.updateSelfSendPaint(_option.strokeWidth);
      _clearDanmakus();
      _cache.clear();
      _lanes.reset();
      _merge.reset();
      _pendingMergeCounts.clear();
    } else {
      if (clearScroll) {
        for (final item in _scrollDanmakuItems) {
          _releaseItem(item);
        }
        _scrollDanmakuItems.clear();
      }
      if (clearTop || clearBottom) {
        _staticDanmakuItems.removeWhere((item) {
          final remove =
              (clearTop && item.content.type == DanmakuItemType.top) ||
                  (clearBottom && item.content.type == DanmakuItemType.bottom);
          if (remove) _releaseItem(item);
          return remove;
        });
      }
      if (clearSpecial) {
        for (final item in _specialDanmakuItems) {
          _releaseItem(item);
        }
        _specialDanmakuItems.clear();
      }
    }
    if (mergeChanged) {
      _merge.reset();
      _pendingMergeCounts.clear();
      _pendingRefits.clear();
    }

    if (styleChanged) _danmakuHeight = _textPainter.height;
    _updateLayout();

    if (durationChanged &&
        oldSpeed > 0 &&
        _lanes.layout.speed > 0 &&
        _scrollDanmakuItems.isNotEmpty) {
      final factor = oldSpeed / _lanes.layout.speed;
      final speed = _lanes.layout.speed;
      for (final item in _scrollDanmakuItems) {
        item.speed = speed;
        item.startTick = _tick - ((_tick - item.startTick) * factor).round();
      }
    }

    if (_running && _hasWork && !_ticker.isActive) _ticker.start();
    _frameNotifier.refresh();
    _staticDanmakuItems.refresh();
  }

  void _updateLayout() {
    var laneHeight = _textPainter.height;
    if (laneHeight <= 0) laneHeight = _option.fontSize * _option.lineHeight;
    var areaHeight = _viewHeight * _option.area;
    if (_option.safeArea && _option.area >= 1.0) {
      areaHeight = areaHeight - laneHeight;
    }
    if (areaHeight < laneHeight) areaHeight = laneHeight;
    final speed = _viewWidth > 0 && _option.durationInMilliseconds > 0
        ? _viewWidth / _option.durationInMilliseconds
        : 0.0;
    _danmakuHeight = laneHeight;
    _lanes.setLayout(
      DanmakuLaneLayout(
        laneHeight: laneHeight,
        areaHeight: areaHeight,
        width: _viewWidth,
        speed: speed,
      ),
      _tick.toDouble(),
    );
    _trackYPositions = List<double>.generate(
      _lanes.laneCount,
      (index) => index * laneHeight,
      growable: false,
    );
  }

  void _syncOpacity() {
    final opacity = _option.opacity;
    if (opacity != _opacityNotifier.value) {
      _opacityNotifier.value = opacity;
    }
  }

  void _clearDanmakus() {
    for (final item in _scrollDanmakuItems) {
      _releaseItem(item);
    }
    _scrollDanmakuItems.clear();
    for (final item in _staticDanmakuItems.value) {
      _releaseItem(item);
    }
    _staticDanmakuItems.clear();
    for (final item in _specialDanmakuItems) {
      _releaseItem(item);
    }
    _specialDanmakuItems.clear();
    _pendingRefits.clear();
    _nextPendingPruneAt = 0;
  }

  DanmakuEngineStats _statsSnapshot() {
    _stats
      ..queued = _queue.length
      ..dropped = _engineDropped + _queue.dropped
      ..cacheHits = _cache.hits
      ..cacheMisses = _cache.misses
      ..visible = _scrollDanmakuItems.length +
          _staticDanmakuItems.value.length +
          _specialDanmakuItems.length;
    return _stats;
  }

  void _hold(DanmakuItem<T> item) {
    if (_heldItem == item) return;
    _releaseHeld();
    final x = item.xAt(_tick);
    item.held = true;
    item.heldAt = _tick;
    item.heldX = x;
    _heldItem = item;
    _lanes.ensureFreeAt(item.lane, _tick + item.remainingMilliseconds(_tick));
    _cancelResume();
  }

  void _releaseHeld() {
    final item = _heldItem;
    if (item == null) return;
    final paused = _tick - (item.heldAt ?? _tick);
    item.startTick += paused;
    item.held = false;
    item.heldAt = null;
    _heldItem = null;
    _lanes.ensureFreeAt(item.lane, _tick + item.remainingMilliseconds(_tick));
  }

  void _cancelResume() {
    _resumeTimer?.cancel();
    _resumeTimer = null;
  }

  void _scheduleResume() {
    if (_resumeTimer != null) return;
    _resumeTimer = Timer(
      const Duration(milliseconds: _leaveDelayMilliseconds),
      _closeMenu,
    );
  }

  void _closeMenu() {
    _cancelResume();
    _releaseHeld();
    _menuHovering = false;
    _menuPointerDown = false;
    if (_menuItem != null) {
      setState(() => _menuItem = null);
    }
  }

  DanmakuItem<T>? _hit(Offset position) {
    for (var index = _scrollDanmakuItems.length - 1; index >= 0; index--) {
      final item = _scrollDanmakuItems[index];
      final x = item.xAt(_tick);
      if (position.dy < item.top || position.dy > item.top + item.height) {
        continue;
      }
      if (position.dx >= x && position.dx <= x + item.width) return item;
    }
    return null;
  }

  void _onHover(PointerHoverEvent event) {
    if (_menuHovering) return;
    final item = _hit(event.localPosition);
    if (item == null) {
      if (!_menuHovering) _scheduleResume();
      return;
    }
    if (item == _heldItem) {
      _cancelResume();
      return;
    }
    _hold(item);
    if (_menuItem != item) {
      setState(() => _menuItem = item);
    }
  }

  void _onPointerDown(PointerDownEvent event) {
    if (_menuPointerDown) {
      _menuPointerDown = false;
      return;
    }
    final item = _hit(event.localPosition);
    if (item != null) {
      _hold(item);
      if (_menuItem != item) {
        setState(() => _menuItem = item);
      }
      return;
    }
    if (_menuItem != null) _closeMenu();
  }

  void _removeByText(String text) {
    _scrollDanmakuItems.removeWhere((item) {
      if (item.content.text != text) return false;
      _releaseItem(item);
      return true;
    });
    _staticDanmakuItems.removeWhere((item) {
      if (item.content.text != text) return false;
      _releaseItem(item);
      return true;
    });
  }

  Widget _buildMenu() {
    final item = _menuItem!;
    return CustomSingleChildLayout(
      delegate: DanmakuMenuLayoutDelegate(
        anchorX: item.xAt(_tick),
        itemTop: item.top,
        itemHeight: item.height,
        viewportWidth: _viewWidth,
        viewportHeight: _viewHeight,
      ),
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) => _menuPointerDown = true,
        child: DanmakuMenu(
          text: item.content.text,
          userName: item.content.userName,
          onCopy: () {
            Clipboard.setData(ClipboardData(text: item.content.text));
            widget.onNotice?.call('弹幕已复制');
            _closeMenu();
          },
          onBlock: widget.onBlockDanmaku == null
              ? null
              : () {
                  final text = item.content.text;
                  _closeMenu();
                  _removeByText(text);
                  widget.onBlockDanmaku!(text);
                },
          onClose: _closeMenu,
          onPointerEnter: () {
            _menuHovering = true;
            _cancelResume();
          },
          onPointerLeave: () {
            _menuHovering = false;
            _scheduleResume();
          },
        ),
      ),
    );
  }

  @override
  void dispose() {
    _running = false;
    _cancelResume();
    _heldItem = null;
    _menuItem = null;
    _clearDanmakus();
    _cache.clear();
    _ticker.dispose();
    _frameNotifier.dispose();
    _optionNotifier.removeListener(_syncOpacity);
    _opacityNotifier.dispose();
    _optionNotifier.dispose();
    _staticDanmakuItems.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final sizeChanged = _viewWidth != constraints.maxWidth ||
            _viewHeight != constraints.maxHeight;
        _viewWidth = constraints.maxWidth;
        _viewHeight = constraints.maxHeight;
        if (sizeChanged) _updateLayout();

        return ClipRect(
          child: ValueListenableBuilder<double>(
            valueListenable: _opacityNotifier,
            builder: (context, opacity, child) {
              return Opacity(opacity: opacity, child: child);
            },
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: _onPointerDown,
              child: MouseRegion(
                opaque: false,
                onHover: _onHover,
                onExit: (_) => _scheduleResume(),
                child: Stack(
                  children: [
                    RepaintBoundary.wrap(
                      CustomPaint(
                        willChange: _running,
                        painter: ScrollDanmakuPainter(
                          length: _scrollDanmakuItems.length,
                          danmakuItems: _scrollDanmakuItems,
                          fontSize: _option.fontSize,
                          fontWeight: _option.fontWeight,
                          strokeWidth: _option.strokeWidth,
                          devicePixelRatio: devicePixelRatio,
                          running: _running,
                          tickListenable: _frameNotifier,
                        ),
                        size: Size.infinite,
                      ),
                      0,
                    ),
                    RepaintBoundary.wrap(
                      CustomPaint(
                        painter: StaticDanmakuPainter(
                          length: _staticDanmakuItems.value.length,
                          danmakuItems: _staticDanmakuItems.value,
                          staticDurationInMilliseconds:
                              _option.staticDurationInMilliseconds,
                          fontSize: _option.fontSize,
                          fontWeight: _option.fontWeight,
                          strokeWidth: _option.strokeWidth,
                          devicePixelRatio: devicePixelRatio,
                          tickListenable: _frameNotifier,
                        ),
                        size: Size.infinite,
                      ),
                      1,
                    ),
                    RepaintBoundary.wrap(
                      CustomPaint(
                        willChange: _running,
                        painter: SpecialDanmakuPainter(
                          length: _specialDanmakuItems.length,
                          danmakuItems: _specialDanmakuItems,
                          fontSize: _option.fontSize,
                          fontWeight: _option.fontWeight,
                          strokeWidth: _option.strokeWidth,
                          devicePixelRatio: devicePixelRatio,
                          running: _running,
                          tickListenable: _frameNotifier,
                        ),
                        size: Size.infinite,
                      ),
                      2,
                    ),
                    if (_menuItem != null) Positioned.fill(child: _buildMenu()),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Iterable<DanmakuItem<T>> hitDanmaku(
    List<DanmakuItem<T>> danmakuItems,
    Offset position,
  ) sync* {
    for (final item in danmakuItems.reversed) {
      if (_hitItem(item, position)) yield item;
    }
  }

  bool _hitItem(DanmakuItem<T> item, Offset position) {
    final dy = position.dy;
    final double y0;
    final double y1;
    if (item.content.type == DanmakuItemType.bottom) {
      y1 = _viewHeight - item.yPosition;
      y0 = y1 - item.height;
    } else {
      y0 = item.content.type == DanmakuItemType.scroll
          ? item.top
          : item.yPosition;
      y1 = y0 + item.height;
    }
    if (dy < y0 || dy > y1) return false;
    final x = item.content.type == DanmakuItemType.scroll
        ? item.xAt(_tick)
        : item.xPosition;
    return position.dx >= x && position.dx <= x + item.width;
  }

  DanmakuItem<T>? hitSingleDanmaku(
    List<DanmakuItem<T>> danmakuItems,
    Offset position,
  ) {
    for (final item in danmakuItems.reversed) {
      if (_hitItem(item, position)) return item;
    }
    return null;
  }

  Iterable<DanmakuItem<T>> findDanmaku(Offset pos) => hitDanmaku(
        _staticDanmakuItems.value,
        pos,
      ).followedBy(hitDanmaku(_scrollDanmakuItems, pos));

  DanmakuItem<T>? findSingleDanmaku(Offset pos) =>
      hitSingleDanmaku(_staticDanmakuItems.value, pos) ??
      hitSingleDanmaku(_scrollDanmakuItems, pos);
}

class ListValueNotifier<T> extends ValueNotifier<List<T>> {
  ListValueNotifier(super.value);

  void add(T item) {
    value.add(item);
    notifyListeners();
  }

  void clear() {
    if (value.isNotEmpty) {
      value.clear();
      notifyListeners();
    }
  }

  void removeWhere(bool Function(T element) test) {
    if (value.removeWhereUnsafe(test)) {
      notifyListeners();
    }
  }
}

extension ValueNotifierExt<T> on ValueNotifier<T> {
  @pragma("vm:prefer-inline")
  void refresh() {
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    notifyListeners();
  }
}

extension<E> on List<E> {
  bool removeWhereUnsafe(bool Function(E) test) {
    int write = 0;
    final length = this.length;
    for (int read = 0; read < length; read++) {
      final element = this[read];
      if (!test(element)) {
        if (write < read) this[write] = element;
        write++;
      }
    }
    if (length != write) {
      this.length = write;
      return true;
    }
    return false;
  }
}
