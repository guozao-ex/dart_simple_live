import 'dart:async';
import 'dart:io';

import 'package:simple_live_core/src/player/flv_renew_relay.dart';
import 'package:test/test.dart';

/// 真实斗鱼拉流浸泡测试：拉满 DOUYU_SOAK_SECONDS（默认 360s），验证跨过
/// 300s 租约时中继能自动续接、时间戳不倒退、视频帧不出现长空洞。
///
/// 默认跳过，需要显式开启（会真实耗流量）：
///   cd simple_live_core
///   DOUYU_SOAK_ROOM=auto dart test test/flv_renew_relay_live_test.dart
///   （房间号可写死；传 auto 时由 test/tool/douyu_url.cjs 从推荐列表挑一个在播房间）
///
/// 依赖本机有 node：用 test/tool/douyu_url.cjs 重新签名取址，模拟 App 的续流取址。
void main() {
  final roomId = Platform.environment['DOUYU_SOAK_ROOM'];
  final seconds =
      int.tryParse(Platform.environment['DOUYU_SOAK_SECONDS'] ?? '') ?? 360;
  final cdn = Platform.environment['DOUYU_SOAK_CDN'] ?? 'hw-h5';

  test(
    '真实斗鱼流跨过 300s 租约不中断',
    () async {
      final tool = File('test/tool/douyu_url.cjs').absolute.path;
      var renewCount = 0;
      var host = '';
      var expire = '';
      final start = DateTime.now();

      Future<String?> resolveUrl() async {
        final result = await Process.run('node', [tool, roomId!, cdn]);
        final url = (result.stdout as String).trim();
        if (result.exitCode != 0 || url.isEmpty) {
          stdout.writeln('[soak] 取址失败: ${result.stderr}');
          return null;
        }
        final parsed = Uri.parse(url);
        host = parsed.host;
        expire = parsed.queryParameters['expire'] ?? 'none';
        return url;
      }

      final firstUrl = await resolveUrl();
      expect(firstUrl, isNotNull, reason: '首次取址失败');
      // 只打印主机与租约参数，不打印带 token 的完整地址
      stdout.writeln('[soak] host=$host expire=$expire');

      var lastVideoTs = -1;
      var maxGap = 0;
      var backwards = 0;
      var tagCount = 0;
      var firstTs = -1;
      var lastTs = -1;

      final relay = FlvRenewRelay();
      final relayUrl = await relay.register(
        key: 'line0',
        url: firstUrl!,
        renew: () async {
          renewCount += 1;
          final at = DateTime.now().difference(start).inSeconds;
          stdout.writeln('[soak] 第 $renewCount 次续流取址（第 ${at}s）');
          return resolveUrl();
        },
      );

      final client = HttpClient();
      final request = await client.getUrl(Uri.parse(relayUrl));
      final response = await request.close();
      expect(response.statusCode, 200);

      final framer = FlvFramer();
      final done = Completer<void>();
      final subscription = response.listen(
        (data) {
          for (final tag in framer.feed(data)) {
            // 只统计媒体 tag：脚本/编码配置 tag 在斗鱼流里会带占位时间戳（0），
            // 把它们算进来会得到「6 小时间隔」这种假指标。
            if (tag.isScript || tag.isVideoSequenceHeader || tag.isAudioSequenceHeader) {
              continue;
            }
            tagCount += 1;
            final ts = tag.timestamp;
            if (firstTs < 0) {
              firstTs = ts;
            }
            if (ts < lastTs) {
              backwards += 1;
            }
            if (tag.isVideo) {
              if (lastVideoTs >= 0) {
                final gap = ts - lastVideoTs;
                if (gap > maxGap) {
                  maxGap = gap;
                }
              }
              lastVideoTs = ts;
            }
            lastTs = ts;
          }
          if (DateTime.now().difference(start).inSeconds >= seconds) {
            if (!done.isCompleted) done.complete();
          }
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        onError: (Object _) {
          if (!done.isCompleted) done.complete();
        },
      );

      await done.future.timeout(Duration(seconds: seconds + 20), onTimeout: () {});
      final elapsed = DateTime.now().difference(start);
      await subscription.cancel();
      client.close(force: true);

      final span = lastTs - firstTs;
      stdout.writeln(
        '[soak] 时长=${elapsed.inSeconds}s tag=$tagCount 时间跨度=${span}ms '
        '最大视频间隔=${maxGap}ms 倒退=$backwards 续流次数=$renewCount',
      );

      expect(tagCount, greaterThan(100), reason: '应收到足量 tag');
      expect(backwards, 0, reason: '时间戳不允许倒退');
      expect(span, greaterThanOrEqualTo((seconds - 15) * 1000),
          reason: '时间轴应跟着真实时间推进，说明全程没有长时间断流');
      expect(maxGap, lessThan(1000),
          reason: '视频帧间隔应与需求 A6 一致：小于 1000ms');
      expect(elapsed.inSeconds, greaterThanOrEqualTo(seconds - 5),
          reason: '应跑满设定时长；提前结束说明上游提前 onDone（例如房间下播）');
      expect(renewCount, greaterThanOrEqualTo(1), reason: '跨过 300s 应至少续流一次');

      await relay.close();
    },
    timeout: Timeout(Duration(seconds: seconds + 180)),
    skip: roomId == null ? '未设置 DOUYU_SOAK_ROOM，跳过真实流浸泡测试' : null,
  );
}
