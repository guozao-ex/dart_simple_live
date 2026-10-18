import 'package:fake_async/fake_async.dart';
import 'package:simple_live_core/src/player/douyu_renew_fallback.dart';
import 'package:test/test.dart';

void main() {
  group('DouyuRenewFallback', () {
    test('按配置间隔触发', () {
      fakeAsync((async) {
        var ticks = 0;
        final fallback = DouyuRenewFallback(
          interval: const Duration(seconds: 10),
          onRenew: () => ticks += 1,
        );
        fallback.start();
        expect(fallback.running, isTrue);

        async.elapse(const Duration(seconds: 9));
        expect(ticks, 0, reason: '未到间隔不应触发');

        async.elapse(const Duration(seconds: 1));
        expect(ticks, 1, reason: '恰好到间隔应触发一次');

        async.elapse(const Duration(seconds: 30));
        expect(ticks, 4, reason: '每 10 秒一次，30 秒应触发 3 次');

        fallback.stop();
        expect(fallback.running, isFalse);
      });
    });

    test('判定为假时跳过，恢复后按时触发', () {
      fakeAsync((async) {
        var ticks = 0;
        var allowed = false;
        final fallback = DouyuRenewFallback(
          interval: const Duration(seconds: 10),
          shouldRun: () => allowed,
          onRenew: () => ticks += 1,
        );
        fallback.start();

        async.elapse(const Duration(seconds: 50));
        expect(ticks, 0, reason: '判定为假时不应有任何触发');

        allowed = true;
        async.elapse(const Duration(seconds: 10));
        expect(ticks, 1);

        fallback.stop();
      });
    });

    test('停止后不再触发；重复启动只有单一触发序列', () {
      fakeAsync((async) {
        var ticks = 0;
        final fallback = DouyuRenewFallback(
          interval: const Duration(seconds: 10),
          onRenew: () => ticks += 1,
        );

        fallback.start();
        fallback.start();
        fallback.start();
        async.elapse(const Duration(seconds: 30));
        expect(ticks, 3, reason: '重复启动不应产生重复触发');

        fallback.stop();
        async.elapse(const Duration(seconds: 100));
        expect(ticks, 3, reason: '停止后不应再触发');
      });
    });

    test('自定义间隔生效', () {
      fakeAsync((async) {
        var ticks = 0;
        final fallback = DouyuRenewFallback(
          interval: const Duration(seconds: 3),
          onRenew: () => ticks += 1,
        );
        fallback.start();
        async.elapse(const Duration(seconds: 12));
        expect(ticks, 4);
        fallback.stop();
      });
    });

    test('默认间隔为 270 秒', () {
      expect(kDouyuRenewFallbackInterval, const Duration(seconds: 270));
      fakeAsync((async) {
        var ticks = 0;
        final fallback = DouyuRenewFallback(onRenew: () => ticks += 1);
        fallback.start();
        async.elapse(const Duration(seconds: 269));
        expect(ticks, 0);
        async.elapse(const Duration(seconds: 1));
        expect(ticks, 1);
        fallback.stop();
      });
    });

    test('换流回调抛错不打断后续触发', () {
      fakeAsync((async) {
        var calls = 0;
        final fallback = DouyuRenewFallback(
          interval: const Duration(seconds: 10),
          onRenew: () {
            calls += 1;
            if (calls == 1) {
              throw StateError('boom');
            }
          },
        );
        fallback.start();
        async.elapse(const Duration(seconds: 20));
        expect(calls, 2, reason: '第一次抛错不应阻止后续触发');
        fallback.stop();
      });
    });
  });
}
