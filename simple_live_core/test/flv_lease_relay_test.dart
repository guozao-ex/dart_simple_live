import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

// ---------- 合成 FLV 工具 ----------

Uint8List flvHeaderBytes() =>
    Uint8List.fromList([0x46, 0x4C, 0x56, 1, 5, 0, 0, 0, 9]);

void _add24(BytesBuilder b, int v) {
  b.add([(v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF]);
}

Uint8List buildTag(int type, int ts, List<int> payload) {
  final b = BytesBuilder();
  b.add([type & 0x1F]);
  _add24(b, payload.length);
  _add24(b, ts & 0xFFFFFF);
  b.add([(ts >> 24) & 0xFF]);
  b.add([0, 0, 0]);
  b.add(payload);
  _add24(b, 11 + payload.length);
  b.add([0]);
  return b.toBytes();
}

/// 解码器配置 tag：真实场景下同一房间各线路的配置字节一致（sourceId 不参与）。
Uint8List videoConfigTag(int ts, int sourceId) => buildTag(
      9,
      ts,
      [0x17, 0x00, 0, 0, 0, 0x01, 0xAA, 0xBB, 0xCC],
    );

Uint8List videoTag(int ts, int sourceId, int seq, {required bool keyframe}) =>
    buildTag(
      9,
      ts,
      [
        keyframe ? 0x17 : 0x27,
        0x01,
        0, 0, 0,
        sourceId,
        seq & 0xFF,
        (seq >> 8) & 0xFF,
      ],
    );

Uint8List audioTag(int ts, int sourceId, int seq) => buildTag(
      8,
      ts,
      [0xAF, 0x01, sourceId, seq & 0xFF],
    );

int videoSourceId(Uint8List tag) => tag[16];

/// 建立一个上游 FLV 服务：每次请求用 [build] 现造一条流。
Future<Uri> serveStream(
  Stream<List<int>> Function() build, {
  int expire = 8,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    try {
      request.response
        ..headers.set('content-type', 'video/x-flv')
        ..bufferOutput = false;
      await request.response.addStream(build());
    } catch (_) {}
    await request.response.close();
  });
  return Uri.parse(
    'http://127.0.0.1:${server.port}/live.flv?expire=$expire&wsAuth=test&token=x',
  );
}

Stream<List<int>> paced(List<List<int>> messages, Duration pace) async* {
  for (final message in messages) {
    yield message;
    await Future.delayed(pace);
  }
}

/// 读取本地 relay 的输出，收满 [maxTags] 条 tag 后主动断开（模拟播放器
/// 离开直播间），再按 137 字节分片喂入分帧器验证增量解析。
Future<(Uint8List? header, List<Uint8List> tags)> readRelay(
  String url, {
  int maxTags = 100000,
}) async {
  final client = HttpClient();
  final request = await client.getUrl(Uri.parse(url));
  final response = await request.close();
  expect(response.statusCode, HttpStatus.ok);

  final framer = FlvFramer();
  final tags = <Uint8List>[];
  try {
    await for (final chunk in response) {
      tags.addAll(framer.feed(chunk));
      if (tags.length >= maxTags) break;
    }
  } catch (_) {
    // 主动断开时连接会抛错，属预期。
  }
  client.close(force: true);
  return (framer.header, tags);
}

/// 无限直播流：从 [startTs] 起按 30ms 步进推进，用于模拟不会结束的 CDN 流。
Stream<List<int>> endlessStream(int startTs, int sourceId, Duration pace,
    {int gopMs = 1000}) async* {
  yield flvHeaderBytes();
  yield Uint8List(4);
  yield videoConfigTag(startTs, sourceId);
  var seq = 0;
  var ts = startTs;
  while (true) {
    yield videoTag(ts, sourceId, seq, keyframe: ts % gopMs == 0);
    yield audioTag(ts, sourceId, seq);
    seq += 1;
    ts += 30;
    await Future.delayed(pace);
  }
}

void expectMonotonic(List<Uint8List> tags) {
  var last = -1;
  for (final tag in tags) {
    expect(
      FlvTagUtils.timestamp(tag),
      greaterThanOrEqualTo(last),
      reason: 'timestamp regression at ${FlvTagUtils.timestamp(tag)}',
    );
    last = FlvTagUtils.timestamp(tag);
  }
}

void main() {
  group('FlvFramer / FlvTagUtils', () {
    test('跨分片增量解析与字段解析', () {
      final framer = FlvFramer();
      final builder = BytesBuilder()
        ..add(flvHeaderBytes())
        ..add(Uint8List(4))
        ..add(videoConfigTag(0, 1))
        ..add(videoTag(33, 1, 1, keyframe: false))
        ..add(audioTag(33, 1, 1));
      final all = builder.toBytes();

      final tags = <Uint8List>[];
      for (final b in all) {
        tags.addAll(framer.feed([b]));
      }
      expect(framer.header, isNotNull);
      expect(tags.length, 3);
      expect(FlvTagUtils.isVideoConfig(tags[0]), isTrue);
      expect(FlvTagUtils.isKeyframe(tags[0]), isFalse);
      expect(FlvTagUtils.isKeyframe(tags[1]), isFalse);
      expect(FlvTagUtils.isAudio(tags[2]), isTrue);
      expect(FlvTagUtils.timestamp(tags[1]), 33);
    });

    test('时间戳改写往返与配置比较', () {
      final tag = videoTag(0x010203, 1, 1, keyframe: true);
      final rewritten = FlvTagUtils.withTimestamp(tag, 0x0A0B0C);
      expect(FlvTagUtils.timestamp(rewritten), 0x0A0B0C);
      expect(FlvTagUtils.payload(rewritten), FlvTagUtils.payload(tag));

      final configA = videoConfigTag(0, 1);
      final configSame = videoConfigTag(500, 1);
      // 真实差异：SPS/PPS 字节不同（如编码参数变化）。
      final configOther = buildTag(9, 500, [
        0x17, 0x00, 0, 0, 0, 0x01, 0xAA, 0xBB, 0xCD,
      ]);
      expect(FlvTagUtils.sameConfig(configA, configSame), isTrue);
      expect(FlvTagUtils.sameConfig(configA, configOther), isFalse);
      expect(FlvTagUtils.sameConfig(configA, null), isFalse);
    });

    test('非法签名抛出', () {
      final framer = FlvFramer();
      expect(
        () => framer.feed(Uint8List.fromList(List.filled(9, 0))),
        throwsFormatException,
      );
    });

    test('LeasedSource 租约解析', () {
      final issuedAt = DateTime(2026, 1, 1);
      final leased = LeasedSource(
        url: Uri.parse('http://x/live.flv?expire=300&wsAuth=abc'),
        issuedAt: issuedAt,
      );
      expect(leased.expireSeconds, 300);
      expect(
        leased.invalidAt,
        issuedAt.add(const Duration(seconds: 300)),
      );
      expect(LeasedSource.hasLease('http://x/a.flv?expire=0'), isFalse);
      expect(LeasedSource.hasLease('http://x/a.flv?wsAuth=abc'), isFalse);
      expect(LeasedSource.hasLease('http://x/a.flv?expire=300'), isTrue);
    });
  });

  group('FlvLeaseRelay 端到端', () {
    tearDown(() {
      FlvLeaseRelay.readTimeout = const Duration(seconds: 20);
    });

    test('正常交接：旧流到达目标关键帧即停，新流无缝续上', () async {
      FlvLeaseRelay.readTimeout = const Duration(seconds: 2);
      final relay = FlvLeaseRelay();
      await relay.start();

      // 共享广播时钟：每次连接都从「当前直播边缘」开始播（与真实 CDN 的
      // 续流行为一致），内容时间 = 墙钟 × 1.5（30ms 步进 / 20ms 节奏）。
      // A 从 0 开播；续流到的 B(n) 从当时的直播边缘续播，可验证链式交接。
      final broadcastStart = DateTime.now();
      Stream<List<int>> liveFrom(int sourceId) async* {
        var ts = DateTime.now().difference(broadcastStart).inMilliseconds;
        ts -= ts % 1000; // 关键帧对齐
        yield flvHeaderBytes();
        yield Uint8List(4);
        yield videoConfigTag(ts, sourceId);
        var seq = 0;
        while (true) {
          yield videoTag(ts, sourceId, seq, keyframe: ts % 1000 == 0);
          yield audioTag(ts, sourceId, seq);
          seq += 1;
          ts += 30;
          await Future.delayed(const Duration(milliseconds: 20));
        }
      }

      final urlA = await serveStream(() => liveFrom(1));
      final urlB = await serveStream(() => liveFrom(2));

      final localUrl = await relay.register(
        key: 'line0',
        source: LeasedSource(url: urlA, issuedAt: DateTime.now()),
        renewer: () async => LeasedSource(url: urlB, issuedAt: DateTime.now()),
      );

      // 收满即断开（模拟播放器退出），避免依赖流自然结束。
      final (header, tags) = await readRelay(localUrl, maxTags: 700);
      await relay.close();

      expect(header, isNotNull);
      final videos =
          tags.where((t) => FlvTagUtils.isVideo(t) && !FlvTagUtils.isVideoConfig(t)).toList();
      expect(videos.map(videoSourceId).toSet(), containsAll([1, 2]));

      // 时间戳单调不回退。
      expectMonotonic(tags);

      // 无倒带：B 的首个关键帧不早于 A 的最后位置。
      final lastATs = videos
          .where((t) => videoSourceId(t) == 1)
          .map(FlvTagUtils.timestamp)
          .reduce((a, b) => a > b ? a : b);
      final firstBKeyframe = videos
          .where((t) => videoSourceId(t) == 2 && FlvTagUtils.isKeyframe(t))
          .map(FlvTagUtils.timestamp)
          .first;
      expect(firstBKeyframe, greaterThanOrEqualTo(lastATs));

      // 解码器配置字节相同，跨源只发一次。
      final configs = tags.where(FlvTagUtils.isVideoConfig).toList();
      expect(configs.length, 1);
    });

    test('提前断流：旧连接在切换点前死亡仍能接上', () async {
      FlvLeaseRelay.readTimeout = const Duration(seconds: 2);
      final relay = FlvLeaseRelay();
      await relay.start();

      // 源 A：只播到 1350 就断（目标关键帧在 1800）。
      final messagesA = <List<int>>[
        flvHeaderBytes(),
        Uint8List(4),
        videoConfigTag(0, 1),
      ];
      var seqA = 0;
      for (var ts = 0; ts <= 1350; ts += 30) {
        messagesA.add(videoTag(ts, 1, seqA, keyframe: ts % 1000 == 0));
        seqA += 1;
      }
      final urlA = await serveStream(
        // 100ms/条：源 A 活到 ~4.6s 才断，续流早已就绪（~3.05s）。
        () => paced(messagesA, const Duration(milliseconds: 100)),
      );

      // 源 B：1800 关键帧起（与 A 的 GOP 不对齐，验证硬切兜底）。
      final messagesB = <List<int>>[
        flvHeaderBytes(),
        Uint8List(4),
        videoConfigTag(1800, 1),
      ];
      var seqB = 0;
      for (var ts = 1800; ts <= 4000; ts += 30) {
        messagesB.add(videoTag(ts, 2, seqB, keyframe: ts % 600 == 0));
        seqB += 1;
      }
      final urlB = await serveStream(
        () => paced(messagesB, const Duration(milliseconds: 1)),
      );

      final localUrl = await relay.register(
        key: 'line0',
        source: LeasedSource(url: urlA, issuedAt: DateTime.now()),
        renewer: () async => LeasedSource(url: urlB, issuedAt: DateTime.now()),
      );

      final (header, tags) = await readRelay(localUrl);
      await relay.close();

      expect(header, isNotNull);
      final videos = tags.where(FlvTagUtils.isVideo).toList();
      final keyframes = videos
          .where(FlvTagUtils.isKeyframe)
          .map(FlvTagUtils.timestamp)
          .toList();
      // 1800 是 B 的第一帧：硬切后从关键帧恢复。
      expect(keyframes, contains(1800));
      expectMonotonic(tags);
    });

    test('注册时已过期：先续期再连接', () async {
      FlvLeaseRelay.readTimeout = const Duration(seconds: 2);
      final relay = FlvLeaseRelay();
      await relay.start();

      // 过期地址指向源 A（sourceId=1）；续期后的新地址是源 B（sourceId=2）。
      final messagesA = <List<int>>[
        flvHeaderBytes(),
        Uint8List(4),
        videoConfigTag(0, 1),
      ];
      var seqA = 0;
      for (var ts = 0; ts <= 600; ts += 30) {
        messagesA.add(videoTag(ts, 1, seqA, keyframe: ts == 0));
        seqA += 1;
      }
      final urlA = await serveStream(
        () => paced(messagesA, const Duration(milliseconds: 1)),
      );

      final messagesB = <List<int>>[
        flvHeaderBytes(),
        Uint8List(4),
        videoConfigTag(0, 2),
      ];
      var seqB = 0;
      for (var ts = 0; ts <= 900; ts += 30) {
        messagesB.add(videoTag(ts, 2, seqB, keyframe: ts == 0));
        seqB += 1;
      }
      final urlB = await serveStream(
        () => paced(messagesB, const Duration(milliseconds: 1)),
      );

      // 源 A 的地址签发于 60 秒前，expire=8 → 已过期，连接前必须先续期。
      final staleUrl = urlA.replace(queryParameters: {
        'expire': '8',
        'wsAuth': 'stale',
      });
      final localUrl = await relay.register(
        key: 'line0',
        source: LeasedSource(
          url: staleUrl,
          issuedAt: DateTime.now().subtract(const Duration(seconds: 60)),
        ),
        renewer: () async => LeasedSource(url: urlB, issuedAt: DateTime.now()),
      );

      final (header, tags) = await readRelay(localUrl);
      await relay.close();

      expect(header, isNotNull);
      expect(tags, isNotEmpty);
      // 所有视频帧都来自续期后的源 B，不含有过期地址的内容。
      final videos = tags
          .where((t) => FlvTagUtils.isVideo(t) && !FlvTagUtils.isVideoConfig(t))
          .toList();
      expect(videos, isNotEmpty);
      expect(videos.map(videoSourceId).toSet(), equals({2}));
    });
  });
}
