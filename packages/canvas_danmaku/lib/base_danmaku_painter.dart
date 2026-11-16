import 'dart:ui' as ui;

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

abstract base class BaseDanmakuPainter extends CustomPainter {
  final int length;
  final List<DanmakuItem> danmakuItems;
  final double fontSize;
  final int fontWeight;
  final double strokeWidth;
  final double devicePixelRatio;
  final bool running;
  final int batchThreshold;
  final ValueListenable<int> tickListenable;

  int get tick => tickListenable.value;

  static final Paint _paint = Paint()..filterQuality = FilterQuality.low;

  const BaseDanmakuPainter({
    required this.length,
    required this.danmakuItems,
    required this.fontSize,
    required this.fontWeight,
    required this.strokeWidth,
    required this.devicePixelRatio,
    required this.running,
    required this.tickListenable,
    this.batchThreshold = 10,
  }) : super(repaint: tickListenable);

  static void paintImg(
    Canvas canvas,
    DanmakuItem item,
    double dx,
    double dy,
    double devicePixelRatio,
  ) {
    final img = item.image!;
    final snappedDx = _snap(dx, devicePixelRatio);
    final snappedDy = _snap(dy, devicePixelRatio);
    if (devicePixelRatio == 1.0) {
      canvas.drawImage(img, Offset(snappedDx, snappedDy), _paint);
    } else {
      final src = Rect.fromLTWH(
        0,
        0,
        img.width.toDouble(),
        img.height.toDouble(),
      );
      final dst = Rect.fromLTWH(snappedDx, snappedDy, item.width, item.height);
      canvas.drawImageRect(img, src, dst, _paint);
    }
  }

  /// 把逻辑坐标吸附到设备像素网格，避免逐帧重采样造成文字抖动。
  static double _snap(double value, double devicePixelRatio) {
    if (devicePixelRatio <= 0 || devicePixelRatio == 1.0) return value;
    return (value * devicePixelRatio).roundToDouble() / devicePixelRatio;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final ui.PictureRecorder? pictureRecorder;
    final Canvas pictureCanvas;
    final length = danmakuItems.length;

    if (length > batchThreshold) {
      pictureRecorder = ui.PictureRecorder();
      pictureCanvas = Canvas(pictureRecorder);
    } else {
      pictureRecorder = null;
      pictureCanvas = canvas;
    }

    DanmakuItem? suspend;
    for (var i in danmakuItems) {
      if (i.expired) continue;

      if (i.suspend) {
        suspend = i;
        continue;
      }

      paintDanmaku(pictureCanvas, size, i);
    }

    if (suspend case final suspend?) {
      paintDanmaku(pictureCanvas, size, suspend);
    }

    if (pictureRecorder != null) {
      final ui.Picture picture = pictureRecorder.endRecording();
      canvas.drawPicture(picture);
      picture.dispose();
    }
  }

  void paintDanmaku(Canvas canvas, Size size, DanmakuItem item);

  @override
  bool shouldRepaint(covariant BaseDanmakuPainter oldDelegate) {
    return (running && length != 0) ||
        oldDelegate.length != length ||
        oldDelegate.fontSize != fontSize ||
        oldDelegate.fontWeight != fontWeight ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.devicePixelRatio != devicePixelRatio;
  }
}
