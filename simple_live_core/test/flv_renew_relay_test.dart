import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:simple_live_core/src/model/live_play_url.dart';
import 'package:simple_live_core/src/player/flv_renew_playback.dart';
import 'package:simple_live_core/src/player/flv_renew_relay.dart';
import 'package:test/test.dart';

const int _tagAudio = 8;
const int _tagVideo = 9;

Uint8List _flvHeader() => Uint8List.fromList([
      0x46, 0x4C, 0x56, 0x01, 0x05, 0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00,
      0x00,
    ]);

Uint8List _buildTag(int type, int ts, List<int> payload) {
  final builder = BytesBuilder();
  builder.add([type]);
  builder.add([
    (payload.length >> 16) & 0xFF,
    (payload.length >> 8) & 0xFF,
    payload.length & 0xFF,
  ]);
  builder.add([
    (ts >> 16) & 0xFF,
    (ts >> 8) & 0xFF,
    ts & 0xFF,
    (ts >> 24) & 0x0F,
  ]);
  builder.add([0, 0, 0]);
  builder.add(payload);
  final total = 11 + payload.length;
  builder.add([
    (total >> 24) & 0xFF,
    (total >> 16) & 0xFF,
    (total >> 8) & 0xFF,
    total & 0xFF,
  ]);
  return builder.takeBytes();
}

/// 视频 tag：payload 第 2 字节 0 为 sequence header，1 为普通帧；
/// 帧类型 1 为关键帧。段号写进 payload 尾部，便于断言这枚 tag 来自哪一段。
Uint8List _videoTag(
  int ts, {
  required bool keyframe,
  required int segment,
  bool config = false,
}) {
  return _buildTag(_tagVideo, ts, [
    (keyframe ? 0x10 : 0x20) | 0x07,
    config ? 0x00 : 0x01,
    0x00,
    0x00,
    0x00,
    ...List<int>.filled(24, segment),
  ]);
}

Uint8List _audioTag(int ts, {required int segment, bool config = false}) {
  return _buildTag(_tagAudio, ts, [
    0xAF,
    config ? 0x00 : 0x01,
    ...List<int>.filled(16, segment),
  ]);
}

/// 生成一段直播流：关键帧每 [keyframeEvery] ms 一枚，音频每 100ms 一枚。
Uint8List _segment({
  required int segment,
  required int from,
  required int to,
  int keyframeEvery = 500,
}) {
  final builder = BytesBuilder();
  builder.add(_flvHeader());
  builder.add(_videoTag(0, keyframe: true, segment: segment, config: true));
  builder.add(_audioTag(0, segment: segment, config: true));
  for (var ts = from; ts <= to; ts += 100) {
    builder.add(_videoTag(ts, keyframe: ts % keyframeEvery == 0, segment: segment));
    builder.add(_audioTag(ts, segment: segment));
  }
  return builder.takeBytes();
}

/// 纯音频段（音乐/电台房：没有视频关键帧）。
Uint8List _audioOnlySegment({
  required int segment,
  required int from,
  required int to,
}) {
  final builder = BytesBuilder();
  builder.add(_flvHeader());
  builder.add(_audioTag(0, segment: segment, config: true));
  for (var ts = from; ts <= to; ts += 100) {
    builder.add(_audioTag(ts, segment: segment));
  }
  return builder.takeBytes();
}

/// 假 CDN：/1.flv、/2.flv 各返回一段流后主动断开（模拟掐线）。
class _FakeCdn {
  _FakeCdn(this.segments, {this.holdOpen = const {}});

  final Map<int, Uint8List> segments;

  /// 这些段发完内容后不关闭连接（模拟「不掐线」的线路）。
  final Set<int> holdOpen;

  HttpServer? _server;
  final List<int> requested = [];
  final List<Completer<void>> _streams = [];

  int get port => _server!.port;

  Future<void> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen((request) async {
      final name = request.uri.path.replaceAll('/', '').replaceAll('.flv', '');
      final index = int.tryParse(name) ?? 0;
      requested.add(index);
      final response = request.response;
      response.headers.contentType = ContentType('video', 'x-flv');
      response.bufferOutput = false;
      final data = segments[index];
      if (data == null) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      final done = Completer<void>();
      _streams.add(done);
      unawaited(done.future.whenComplete(() {
        unawaited(response.close().catchError((Object _) {}));
      }));
      const chunkSize = 4096;
      for (var offset = 0; offset < data.length; offset += chunkSize) {
        final end = (offset + chunkSize > data.length)
            ? data.length
            : offset + chunkSize;
        response.add(Uint8List.sublistView(data, offset, end));
        await response.flush();
        if (done.isCompleted) {
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      if (!holdOpen.contains(index) || done.isCompleted) {
        if (!done.isCompleted) {
          done.complete();
        }
        return;
      }
      // 模拟「不掐线」的线路：连接保持并持续推流
      var nextTs = (_parse(data).map((tag) => tag.$2).fold<int>(0, (a, b) => a > b ? a : b)) + 100;
      while (!done.isCompleted) {
        try {
          response.add(_audioTag(nextTs, segment: index));
          await response.flush();
        } catch (_) {
          break;
        }
        nextTs += 20;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
  }

  void releaseAll() {
    for (final completer in _streams) {
      if (!completer.isCompleted) {
        completer.complete();
      }
    }
  }

  Future<void> stop() async {
    releaseAll();
    await _server?.close(force: true);
  }
}

/// 从下游读一段流，最多读 [timeout]。
Future<Uint8List> _readStream(
  String url, {
  Duration timeout = const Duration(seconds: 4),
}) async {
  final result = await _readStreamStatus(url, timeout: timeout);
  return result.$2;
}

/// 从下游读一段流并返回 (状态码, 内容)，最多读 [timeout]。
Future<(int, Uint8List)> _readStreamStatus(
  String url, {
  Duration timeout = const Duration(seconds: 4),
}) async {
  final client = HttpClient();
  final request = await client.getUrl(Uri.parse(url));
  final response = await request.close();
  final builder = BytesBuilder();
  final done = Completer<void>();
  final subscription = response.listen(
    builder.add,
    onDone: () {
      if (!done.isCompleted) done.complete();
    },
    onError: (Object _) {
      if (!done.isCompleted) done.complete();
    },
  );
  await done.future.timeout(timeout, onTimeout: () {});
  await subscription.cancel();
  client.close(force: true);
  return (response.statusCode, builder.takeBytes());
}

/// 把收到的字节拆成 (type, timestamp, segment, 是否编码配置) 序列。
List<(int, int, int, bool)> _parse(Uint8List bytes) {
  final framer = FlvFramer();
  final result = <(int, int, int, bool)>[];
  for (var offset = 0; offset < bytes.length; offset += 1024) {
    final end = (offset + 1024 > bytes.length) ? bytes.length : offset + 1024;
    for (final tag in framer.feed(Uint8List.sublistView(bytes, offset, end))) {
      final data = tag.data;
      final segment = data.length > 6 ? data[data.length - 1] : -1;
      result.add((
        tag.type,
        tag.timestamp,
        segment,
        tag.isVideoSequenceHeader || tag.isAudioSequenceHeader,
      ));
    }
  }
  return result;
}

void main() {
  group('FlvFramer', () {
    test('分片到达也能拆出完整 tag', () {
      final stream = _segment(segment: 1, from: 0, to: 1000);
      final framer = FlvFramer();
      final tags = <FlvTag>[];
      for (var offset = 0; offset < stream.length; offset += 7) {
        final end = (offset + 7 > stream.length) ? stream.length : offset + 7;
        tags.addAll(framer.feed(Uint8List.sublistView(stream, offset, end)));
      }
      expect(framer.header, isNotNull);
      expect(framer.header!.length, 13);
      expect(tags.length, greaterThan(4));
      expect(tags.first.isVideoSequenceHeader, isTrue);
      expect(tags[1].isAudioSequenceHeader, isTrue);
      // 配置 tag 不算关键帧（isKeyframe 已排除 sequence header）
      expect(tags.first.isKeyframe, isFalse);
      expect(tags.where((tag) => tag.isKeyframe).length, greaterThanOrEqualTo(3));
      expect(tags.last.timestamp, 1000);
    });

    test('非 FLV 数据抛错', () {
      final framer = FlvFramer();
      expect(
        () => framer.feed(List<int>.filled(32, 0x11)),
        throwsA(isA<FormatException>()),
      );
    });

    test('改写时间戳不改动原 tag', () {
      final tag = FlvTag(_videoTag(1234, keyframe: true, segment: 1));
      final copy = tag.copyWithTimestamp(99);
      expect(copy.timestamp, 99);
      expect(tag.timestamp, 1234);
      expect(copy.data, tag.data);
    });
  });

  group('FlvRenewRelay', () {
    test('上游断开时自动续接，时间戳保持单调', () async {
      final cdn = _FakeCdn({
        1: _segment(segment: 1, from: 0, to: 2000),
        2: _segment(segment: 2, from: 1500, to: 3000),
      });
      await cdn.start();
      final relay = FlvRenewRelay(
        ttl: const Duration(seconds: 30),
        prefetchLead: const Duration(seconds: 5),
      );
      var renewCount = 0;
      final url = await relay.register(
        key: 'line1',
        url: 'http://127.0.0.1:${cdn.port}/1.flv',
        renew: () async {
          renewCount += 1;
          // 只成功续一次：第二次故意失败，便于断言「一次断开 = 一次续接」
          return renewCount == 1 ? 'http://127.0.0.1:${cdn.port}/2.flv' : null;
        },
      );
      final bytes = await _readStream(url);
      await relay.close();
      await cdn.stop();

      final tags = _parse(bytes);
      expect(renewCount, 2,
          reason: '第一次断开续接成功，第二次取不到地址后结束会话');
      expect(tags, isNotEmpty);
      for (var i = 1; i < tags.length; i++) {
        expect(tags[i].$2, greaterThanOrEqualTo(tags[i - 1].$2),
            reason: '时间戳不允许倒退（第 $i 条）');
      }
      expect(tags.any((tag) => tag.$3 == 1), isTrue, reason: '应包含第一段内容');
      expect(tags.any((tag) => tag.$3 == 2), isTrue, reason: '应包含续接后的内容');
      final content = tags.where((tag) => !tag.$4).toList();
      final firstOfSecond = content.firstWhere((tag) => tag.$3 == 2);
      final lastOfFirst = content.lastWhere((tag) => tag.$3 == 1);
      expect(firstOfSecond.$2, greaterThan(lastOfFirst.$2),
          reason: '续接点必须落在已转发位置之后');
      expect(tags.last.$2, 3000, reason: '续接后应一路跟到新流末尾');
    });

    test('到期即主动换流，不依赖上游掐线', () async {
      final cdn = _FakeCdn(
        {
          1: _segment(segment: 1, from: 0, to: 4000),
          2: _segment(segment: 2, from: 3500, to: 6000),
        },
        holdOpen: {1},
      );
      await cdn.start();
      final relay = FlvRenewRelay(
        ttl: const Duration(milliseconds: 400),
        prefetchLead: const Duration(milliseconds: 200),
      );
      final url = await relay.register(
        key: 'line1',
        url: 'http://127.0.0.1:${cdn.port}/1.flv',
        renew: () async => 'http://127.0.0.1:${cdn.port}/2.flv',
      );
      final bytes = await _readStream(url, timeout: const Duration(seconds: 3));
      await relay.close();
      await cdn.stop();

      final tags = _parse(bytes);
      expect(cdn.requested.contains(2), isTrue, reason: '到期前应预取第二条');
      expect(tags.any((tag) => tag.$3 == 2), isTrue, reason: '应已切到第二条流');
      // 换流后旧连接应被切断：旧线路的持续推流不应再出现
      final tail = tags.skipWhile((tag) => tag.$3 != 2).toList();
      expect(tail.any((tag) => tag.$3 == 1), isFalse, reason: '换流后不应再混入旧线路数据');
      // 换流不能丢内容：相邻媒体 tag 的时间差不应出现 GOP 级空洞
      final media = tags.where((tag) => !tag.$4).toList();
      var maxDelta = 0;
      for (var i = 1; i < media.length; i++) {
        final delta = media[i].$2 - media[i - 1].$2;
        if (delta > maxDelta) {
          maxDelta = delta;
        }
      }
      expect(maxDelta, lessThan(700),
          reason: '换流期间不应丢一个 GOP（最大间隔 ${maxDelta}ms）');
      for (var i = 1; i < tags.length; i++) {
        expect(tags[i].$2, greaterThanOrEqualTo(tags[i - 1].$2));
      }
    });

    test('新流时间轴整体回退时重设基准，避免卡死', () async {
      final cdn = _FakeCdn({
        1: _segment(segment: 1, from: 0, to: 2000),
        2: _segment(segment: 2, from: 0, to: 800),
      });
      await cdn.start();
      final relay = FlvRenewRelay(
        ttl: const Duration(seconds: 30),
        prefetchLead: const Duration(seconds: 5),
      );
      final url = await relay.register(
        key: 'line1',
        url: 'http://127.0.0.1:${cdn.port}/1.flv',
        renew: () async => 'http://127.0.0.1:${cdn.port}/2.flv',
      );
      final bytes = await _readStream(url);
      await relay.close();
      await cdn.stop();

      final tags = _parse(bytes);
      final lastOfFirst = tags.lastWhere((tag) => tag.$3 == 1);
      final secondTags = tags.where((tag) => tag.$3 == 2).toList();
      expect(secondTags, isNotEmpty, reason: '回退时间轴也应接上');
      expect(secondTags.first.$2, greaterThan(lastOfFirst.$2),
          reason: '重设基准后必须落在已转发位置之后');
      for (var i = 1; i < tags.length; i++) {
        expect(tags[i].$2, greaterThanOrEqualTo(tags[i - 1].$2));
      }
    });

    test('取不到新地址时结束会话而不是挂着', () async {
      final cdn = _FakeCdn({1: _segment(segment: 1, from: 0, to: 500)});
      await cdn.start();
      final relay = FlvRenewRelay(
        ttl: const Duration(seconds: 30),
        prefetchLead: const Duration(seconds: 5),
      );
      final url = await relay.register(
        key: 'line1',
        url: 'http://127.0.0.1:${cdn.port}/1.flv',
        renew: () async => null,
      );
      final bytes = await _readStream(url, timeout: const Duration(seconds: 2));
      await relay.close();
      await cdn.stop();
      final tags = _parse(bytes);
      expect(tags, isNotEmpty);
      expect(tags.any((tag) => tag.$3 == 2), isFalse);
    });

    test('开关关闭时不接入中继，且不调用续流取址', () async {
      final cdn = _FakeCdn({1: _segment(segment: 1, from: 0, to: 500)});
      await cdn.start();
      var renewCount = 0;
      // 用注入的构造器记录「有没有真的去构造中继」，以此反证关闭路径不绑定端口
      var relayConstructed = 0;
      FlvRenewPlayback.debugRelayFactory = () {
        relayConstructed += 1;
        return FlvRenewRelay();
      };
      addTearDown(() => FlvRenewPlayback.debugRelayFactory = null);
      final playUrl = LivePlayUrl(
        urls: ['http://127.0.0.1:${cdn.port}/1.flv'],
        renewUrl: (lineIndex) async {
          renewCount += 1;
          return 'http://127.0.0.1:${cdn.port}/1.flv';
        },
      );

      final off = await FlvRenewPlayback.create(playUrl, enabled: false);
      expect(off, isNull, reason: '关闭开关时不应接入中继');
      expect(renewCount, 0, reason: '关闭开关时不应调用续流取址');
      expect(relayConstructed, 0, reason: '关闭开关时不应构造中继（即不会绑定任何本地端口）');

      // 默认开启：不传 enabled 时按接入处理
      final on = await FlvRenewPlayback.create(playUrl);
      expect(on, isNotNull, reason: '默认应为开启');
      expect(relayConstructed, 1, reason: '开启时应构造并启动中继');
      expect(on!.urls.first.startsWith('http://127.0.0.1:'), isTrue);
      expect(FlvRenewRelay.isRelayUrl(on.urls.first), isTrue);
      await on.close();
      await cdn.stop();
    });

    test('未登记的地址返回 404，中继地址可被识别', () async {
      final relay = FlvRenewRelay();
      await relay.start();
      final client = HttpClient();
      final request =
          await client.getUrl(Uri.parse('http://127.0.0.1:${relay.port}/nope.flv'));
      final response = await request.close();
      expect(response.statusCode, HttpStatus.notFound);
      await response.drain<void>();
      client.close(force: true);
      expect(
        FlvRenewRelay.isRelayUrl('http://127.0.0.1:${relay.port}/line0.flv'),
        isTrue,
      );
      expect(FlvRenewRelay.isRelayUrl('https://ws1a.douyucdn.cn/live/1.flv'), isFalse);
      await relay.close();
    });

    test('注册地址过期时先续期再连，且新地址会被后续会话复用（回归跨会话 502）', () async {
      final cdn = _FakeCdn({1: _segment(segment: 1, from: 0, to: 1000)});
      await cdn.start();
      final relay = FlvRenewRelay(
        ttl: const Duration(seconds: 1),
        prefetchLead: const Duration(milliseconds: 200),
        renewRetryInterval: const Duration(milliseconds: 300),
      );
      var renewCount = 0;
      final good = 'http://127.0.0.1:${cdn.port}/1.flv';
      final url = await relay.register(
        key: 'line0',
        // 注册时故意给一个 404 地址：首连若不先续期就会 502
        url: 'http://127.0.0.1:${cdn.port}/9.flv',
        renew: () async {
          renewCount += 1;
          return good;
        },
      );
      // 等过新鲜度窗口（ttl - lead = 800ms），留足余量避免时序抖动
      await Future<void>.delayed(const Duration(milliseconds: 1500));

      final (status, first) =
          await _readStreamStatus(url, timeout: const Duration(seconds: 6));
      expect(status, 200, reason: '过期地址必须先续期再连接');
      expect(_parse(first), isNotEmpty);
      expect(renewCount, greaterThanOrEqualTo(1));

      // 第二个会话：源地址已被续期刷新，应当直接可用
      final second = await _readStream(url, timeout: const Duration(seconds: 2));
      expect(_parse(second), isNotEmpty, reason: '续期后的地址要能被后续会话复用');
      await relay.close();
      await cdn.stop();
    });

    test('上游不是 FLV 时返回 502，不挂空响应（回归挂死）', () async {
      final cdn = _FakeCdn({
        1: Uint8List.fromList(List<int>.generate(4096, (i) => 0x41)),
      });
      await cdn.start();
      final relay = FlvRenewRelay();
      final url = await relay.register(
        key: 'line0',
        url: 'http://127.0.0.1:${cdn.port}/1.flv',
        renew: () async => null,
      );
      final (status, _) = await _readStreamStatus(
        url,
        timeout: const Duration(seconds: 3),
      );
      await relay.close();
      await cdn.stop();
      expect(status, HttpStatus.badGateway);
    });

    test('纯音频流（音乐/电台房）也能续接', () async {
      final cdn = _FakeCdn({
        1: _audioOnlySegment(segment: 1, from: 0, to: 1000),
        2: _audioOnlySegment(segment: 2, from: 800, to: 1600),
      });
      await cdn.start();
      final relay = FlvRenewRelay(
        ttl: const Duration(seconds: 30),
        prefetchLead: const Duration(seconds: 5),
      );
      final url = await relay.register(
        key: 'line0',
        url: 'http://127.0.0.1:${cdn.port}/1.flv',
        renew: () async => 'http://127.0.0.1:${cdn.port}/2.flv',
      );
      final bytes = await _readStream(url);
      await relay.close();
      await cdn.stop();

      final tags = _parse(bytes);
      expect(tags.any((tag) => tag.$3 == 2), isTrue, reason: '没有视频关键帧也要能接上');
      for (var i = 1; i < tags.length; i++) {
        expect(tags[i].$2, greaterThanOrEqualTo(tags[i - 1].$2));
      }
    });
  });
}
