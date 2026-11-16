import 'dart:ui' as ui;

import 'package:canvas_danmaku/danmaku_image_cache.dart';
import 'package:canvas_danmaku/models/danmaku_content_item.dart';
import 'package:canvas_danmaku/utils/utils.dart';

class DanmakuItem<T> {
  /// 弹幕内容
  final DanmakuContentItem<T> content;

  /// 弹幕宽度
  double width;

  /// 弹幕高度
  double height;

  /// 弹幕水平方向位置（静态弹幕与命中测试沿用；滚动弹幕以 [xAt] 为准）
  double xPosition;

  /// 弹幕竖直方向位置
  double yPosition;

  /// 上次绘制时间
  int? drawTick;

  /// 位图。滚动弹幕的位图由 [DanmakuImageCache] 持有，本对象不负责释放。
  ui.Image? image;

  /// 滚动弹幕使用的缓存条目
  DanmakuImageEntry? imageEntry;

  /// 是否由本对象释放 [image]（静态/特效弹幕为 true，缓存共享位图为 false）
  bool ownsImage;

  bool expired = false;

  bool suspend = false;

  /// 生成时的帧时间
  int startTick;

  /// 生成时的视口宽度
  double from;

  /// 横向速度，px/ms
  double speed;

  /// 车道索引
  int lane;

  /// 车道上边缘
  double top;

  /// 合并组标识
  String? mergeGroupId;

  /// 合并计数
  int mergeCount;

  /// 是否被悬停/点击暂停
  bool held = false;

  /// 暂停发生的帧时间
  int? heldAt;

  /// 暂停时冻结的横坐标
  double heldX = 0;

  DanmakuItem({
    required this.content,
    required this.height,
    required this.width,
    this.xPosition = 0,
    this.yPosition = 0,
    this.image,
    this.imageEntry,
    this.ownsImage = true,
    this.startTick = 0,
    this.from = 0,
    this.speed = 0,
    this.lane = 0,
    this.top = 0,
    this.mergeGroupId,
    this.mergeCount = 1,
    this.drawTick,
  });

  /// 当前帧的横坐标；暂停时冻结在 [heldX]。
  double xAt(int tick) {
    if (held) return heldX;
    if (speed <= 0) return from;
    return from - (tick - startTick) * speed;
  }

  /// 从当前帧到尾部离开左边缘还剩多少毫秒。
  double remainingMilliseconds(int tick) {
    if (speed <= 0) return 0;
    return (xAt(tick) + width) / speed;
  }

  @pragma("vm:prefer-inline")
  bool needRemove(bool needRemove) {
    if (needRemove) {
      dispose();
    }
    return needRemove;
  }

  void dispose() {
    if (ownsImage) image?.dispose();
    image = null;
    imageEntry = null;
  }

  void drawParagraphIfNeeded(
    double fontSize,
    int fontWeight,
    double strokeWidth,
    double devicePixelRatio,
  ) {
    if (image != null) return;
    final paragraph = DmUtils.generateParagraph(
      content: content,
      fontSize: fontSize,
      fontWeight: fontWeight,
      mergeCount: mergeCount,
    );
    final bitmap = DmUtils.buildDanmakuImage(
      contentParagraph: paragraph,
      content: content,
      fontSize: fontSize,
      fontWeight: fontWeight,
      strokeWidth: strokeWidth,
      devicePixelRatio: devicePixelRatio,
      mergeCount: mergeCount,
    );
    image = bitmap.image;
    width = bitmap.width;
    height = bitmap.height;
    ownsImage = true;
    paragraph.dispose();
  }

  @override
  String toString() {
    return 'DanmakuItem(content=$content, xPos=$xPosition, yPos=$yPosition, size=${ui.Size(width, height)}, drawTick=$drawTick)';
  }
}
