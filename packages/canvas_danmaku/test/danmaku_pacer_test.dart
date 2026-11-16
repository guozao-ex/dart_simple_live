import 'package:canvas_danmaku/danmaku_pacer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group("DanmakuPacer", () {
    test("采样不足时返回 0，调用方退回逐帧推进", () {
      final pacer = DanmakuPacer();
      for (var i = 0; i < 11; i++) {
        pacer.add(12);
      }
      expect(pacer.step, 0);
      pacer.add(12);
      expect(pacer.step, greaterThan(0));
    });

    test("取 p75：12/18 混跳时步长落在 18 附近", () {
      final pacer = DanmakuPacer();
      for (var i = 0; i < 60; i++) {
        pacer.add(i % 3 == 0 ? 12 : 18);
      }
      expect(pacer.step, 18);
    });

    test("全部 6ms 的机器不会被拖慢到网格下限以下", () {
      final pacer = DanmakuPacer();
      for (var i = 0; i < 40; i++) {
        pacer.add(6);
      }
      expect(pacer.step, 8);
    });

    test("异常间隔（切后台/长卡顿）不计入并随窗口淘汰", () {
      final pacer = DanmakuPacer();
      for (var i = 0; i < 40; i++) {
        pacer.add(17);
      }
      expect(pacer.step, 17);
      pacer.add(5000);
      pacer.add(0);
      pacer.add(-3);
      expect(pacer.step, 17);
    });

    test("step 受上限约束", () {
      final pacer = DanmakuPacer();
      for (var i = 0; i < 40; i++) {
        pacer.add(60);
      }
      expect(pacer.step, 25);
    });

    test("reset 后重新采样", () {
      final pacer = DanmakuPacer();
      for (var i = 0; i < 20; i++) {
        pacer.add(20);
      }
      expect(pacer.step, 20);
      pacer.reset();
      expect(pacer.step, 0);
    });
  });
}