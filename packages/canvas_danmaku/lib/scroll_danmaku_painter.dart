import 'dart:ui' as ui;

import 'package:canvas_danmaku/base_danmaku_painter.dart';
import 'package:canvas_danmaku/models/danmaku_item.dart';
import 'package:flutter/material.dart';

final class ScrollDanmakuPainter extends BaseDanmakuPainter {
  late final Paint selfSendPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = strokeWidth
    ..color = Colors.green;

  ScrollDanmakuPainter({
    required super.length,
    required super.danmakuItems,
    required super.fontSize,
    required super.fontWeight,
    required super.strokeWidth,
    required super.devicePixelRatio,
    required super.running,
    required super.tickListenable,
    super.batchThreshold,
  });

  @override
  void paintDanmaku(ui.Canvas canvas, ui.Size size, DanmakuItem item) {
    item.drawParagraphIfNeeded(
      fontSize,
      fontWeight,
      strokeWidth,
      devicePixelRatio,
    );
    final x = item.xAt(tick);
    if (!item.held && x + item.width < 0) {
      item.expired = true;
      return;
    }

    BaseDanmakuPainter.paintImg(canvas, item, x, item.top, devicePixelRatio);
  }
}
