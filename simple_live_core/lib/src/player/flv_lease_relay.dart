import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import '../common/core_log.dart';

/// FLV 租约续流中继。
///
/// 背景：斗鱼 2026-09 起对游客态拉流收紧，原画 FLV 地址带 `expire` 租约参数，
/// CDN 在地址签发后到期即关闭连接，播放每 5 分钟断流一次。
///
/// 算法参照 liuchuancong/pure_live 提交 31982153 的公开提交说明（该仓库为
/// AGPL-3.0，本文件是 GPL-3.0 项目下的独立原创实现，未复制其源码）：
/// 在租约到期前提前重新解析同线路同画质的新地址，旧连接持续转发到新流上
/// 「旧连接尚未送达的关键帧」处再切换；两路连接共享同一时间轴时不平移，
/// 否则按对齐窗整体平移，且输出时间戳始终单调钳制；切换前若解码器配置
/// 变化则先发新配置。对播放器呈现为一条连续的本地 FLV 流，切换全程无感。
///
/// 用法：
/// ```dart
/// final relay = FlvLeaseRelay();
/// final url = await relay.register(
///   key: 'line0',
///   source: LeasedSource(url: Uri.parse(flvUrl), issuedAt: DateTime.now()),
///   renewer: () async => freshSourceOrNull,
/// );
/// // 把 url 交给播放器；页面退出时 relay.close()。
/// ```

/// 刷新提前量：租约到期前多少秒开始解析下一节地址。
const _renewLeadDefault = Duration(seconds: 45);

/// 签发时刻的安全回退：地址从签发到被使用有延迟，宁可早切。
const _invalidSafety = Duration(seconds: 3);

/// 新旧时间轴差异在该窗口内视为同一时间轴（不平移）。
const _alignmentWindow = Duration(seconds: 60);

/// 上游读超时：超时视为连接死亡。测试可注入更短值。
const _defaultReadTimeout = Duration(seconds: 20);

/// 新流预检 deadline：超时仍未等到关键帧则按兜底规则取切换点。
const _inspectDeadline = Duration(seconds: 15);

/// 旧连接超过失效时刻再加该宽限仍未到达切换点则强制切换。
const _forceSwitchGrace = Duration(seconds: 10);

/// 续流失败重试间隔与次数。
const _renewRetryDelay = Duration(seconds: 3);
const _renewMaxAttempts = 5;

/// 带租约的播放源：`expire` 查询参数决定地址何时失效。
class LeasedSource {
  LeasedSource({
    required this.url,
    this.headers = const {},
    this.issuedAt,
  });

  final Uri url;
  final Map<String, String> headers;

  /// 地址签发时刻；续流回调返回的源可不传（由中继记录当时时刻）。
  final DateTime? issuedAt;

  int? get expireSeconds {
    final raw = url.queryParameters['expire'];
    if (raw == null) return null;
    return int.tryParse(raw);
  }

  DateTime? get invalidAt {
    final expire = expireSeconds;
    if (expire == null || expire <= 0) return null;
    return (issuedAt ?? DateTime.now()).add(Duration(seconds: expire));
  }

  /// 距失效所剩无几视为已过期（新会话开始前需先续期）。
  /// 阈值取 min(10 秒, 租约的 1/3)，避免短租约被整体判死。
  bool get expiredSoon {
    final invalid = invalidAt;
    if (invalid == null) return false;
    final expire = expireSeconds ?? 0;
    final threshold = expire > 0 && expire < 30
        ? Duration(milliseconds: expire * 1000 ~/ 3)
        : const Duration(seconds: 10);
    return DateTime.now().isAfter(invalid.subtract(threshold));
  }

  /// 判断任意播放地址是否带租约（expire > 0）。
  static bool hasLease(String url) {
    final expire = Uri.tryParse(url)?.queryParameters['expire'];
    if (expire == null) return false;
    return (int.tryParse(expire) ?? 0) > 0;
  }

  LeasedSource withIssuedAt(DateTime at) => LeasedSource(
        url: url,
        headers: headers,
        issuedAt: at,
      );
}

/// 续流回调：解析并返回同房间、同线路、同画质的新地址；失败返回 null。
typedef SourceRenewer = Future<LeasedSource?> Function();

/// 增量解析 HTTP-FLV 字节流。
///
/// 9 字节 FLV 头经 [header] 暴露（不作为 tag 吐出），其后 4 字节
/// PreviousTagSize0 被丢弃，之后每个完整 tag（11 字节 tag 头 + 数据 +
/// 4 字节 PreviousTagSize）作为一条消息输出。
class FlvFramer {
  Uint8List? header;

  Uint8List _pending = Uint8List(0);
  int _offset = 0;
  int _dataSize = 0;

  /// 0=待 FLV 头(9B)，1=待 PreviousTagSize0(4B)，2=tag 流。
  int _stage = 0;

  /// 喂入一段字节，返回新拼装完成的 tag（可能为空列表）。
  List<Uint8List> feed(List<int> chunk) {
    _append(chunk);
    final out = <Uint8List>[];
    if (_stage == 0) {
      if (_available < 9) return out;
      final head = _take(9);
      if (head[0] != 0x46 || head[1] != 0x4C || head[2] != 0x56) {
        throw const FormatException('FLV: bad signature');
      }
      header = head;
      _stage = 1;
    }
    if (_stage == 1) {
      if (_available < 4) return out;
      _take(4);
      _stage = 2;
    }
    while (_stage == 2) {
      if (_available < 11) break;
      _dataSize = (_pending[_offset + 1] << 16) |
          (_pending[_offset + 2] << 8) |
          _pending[_offset + 3];
      final total = 11 + _dataSize + 4;
      if (_available < total) break;
      out.add(_take(total));
    }
    return out;
  }

  int get _available => _pending.length - _offset;

  void _append(List<int> chunk) {
    if (_offset > 0 && _offset >= _pending.length) {
      _pending = Uint8List(0);
      _offset = 0;
    } else if (_offset > 65536 && _offset * 2 > _pending.length) {
      final rest = Uint8List.fromList(
        Uint8List.sublistView(_pending, _offset),
      );
      _pending = rest;
      _offset = 0;
    }
    final tail = _pending.length - _offset;
    final merged = Uint8List(tail + chunk.length);
    merged.setRange(0, tail, _pending, _offset);
    merged.setRange(tail, merged.length, chunk);
    _pending = merged;
    _offset = 0;
  }

  Uint8List _take(int n) {
    final view = Uint8List.sublistView(_pending, _offset, _offset + n);
    _offset += n;
    return Uint8List.fromList(view);
  }
}

/// FLV tag 字段工具，操作对象为含 11 字节 tag 头的完整 tag。
abstract final class FlvTagUtils {
  static const int _typeAudio = 8;
  static const int _typeVideo = 9;
  static const int _typeScript = 18;

  static int type(Uint8List tag) => tag[0] & 0x1f;

  static bool isAudio(Uint8List tag) => type(tag) == _typeAudio;
  static bool isVideo(Uint8List tag) => type(tag) == _typeVideo;
  static bool isScript(Uint8List tag) => type(tag) == _typeScript;

  /// 时间戳（毫秒），3 字节低位 + 1 字节扩展位。
  static int timestamp(Uint8List tag) =>
      (tag[7] << 24) | (tag[4] << 16) | (tag[5] << 8) | tag[6];

  /// 返回改写时间戳后的 tag 副本。
  static Uint8List withTimestamp(Uint8List tag, int timestamp) {
    final copy = Uint8List.fromList(tag);
    final value = timestamp & 0xFFFFFFFF;
    copy[4] = (value >> 16) & 0xFF;
    copy[5] = (value >> 8) & 0xFF;
    copy[6] = value & 0xFF;
    copy[7] = (value >> 24) & 0xFF;
    return copy;
  }

  /// tag 数据部分（不含 tag 头与 PreviousTagSize）。
  static Uint8List payload(Uint8List tag) =>
      Uint8List.sublistView(tag, 11, tag.length - 4);

  static bool _enhanced(Uint8List tag) =>
      isVideo(tag) && tag.length > 11 && (tag[11] & 0x80) != 0;

  /// 解码器配置：Enhanced FLV 的 SequenceStart，或传统 FLV 中
  /// AVC(7)/HEVC(12) 的 AVCPacketType == 0。
  static bool isVideoConfig(Uint8List tag) {
    if (!isVideo(tag) || tag.length < 13) return false;
    if (_enhanced(tag)) return (tag[11] & 0x0F) == 0;
    final codec = tag[11] & 0x0F;
    return (codec == 7 || codec == 12) && tag[12] == 0;
  }

  /// 视频关键帧（排除解码器配置 tag）。
  static bool isKeyframe(Uint8List tag) {
    if (!isVideo(tag) || tag.length < 13) return false;
    if (isVideoConfig(tag)) return false;
    return ((tag[11] >> 4) & 0x07) == 1;
  }

  /// 比较两个解码器配置的数据部分是否一致。
  static bool sameConfig(Uint8List? a, Uint8List? b) {
    if (a == null || b == null) return false;
    final pa = payload(a);
    final pb = payload(b);
    if (pa.length != pb.length) return false;
    for (var i = 0; i < pa.length; i++) {
      if (pa[i] != pb[i]) return false;
    }
    return true;
  }
}

/// 上游 HTTP-FLV 连接，按完整 tag 输出。
class _UpstreamReader {
  _UpstreamReader._(this._client, this._iterator);

  final HttpClient _client;
  final StreamIterator<List<int>> _iterator;
  final FlvFramer _framer = FlvFramer();
  final Queue<Uint8List> _messages = Queue();
  bool _eof = false;

  /// 连接上游；非 200 或网络错误返回 null。
  static Future<_UpstreamReader?> open(
    Uri url,
    Map<String, String> headers,
  ) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(url);
      headers.forEach(request.headers.set);
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        CoreLog.w('FlvLeaseRelay: upstream ${response.statusCode} $url');
        client.close(force: true);
        return null;
      }
      return _UpstreamReader._(client, StreamIterator(response));
    } catch (e) {
      CoreLog.w('FlvLeaseRelay: upstream open failed $url: $e');
      client.close(force: true);
      return null;
    }
  }

  /// 读取下一条 tag；流结束或出错返回 null。
  Future<Uint8List?> next() async {
    while (_messages.isEmpty) {
      if (_eof) return null;
      bool moved;
      try {
        moved = await _iterator.moveNext();
      } catch (_) {
        _eof = true;
        return null;
      }
      if (!moved) {
        _eof = true;
        return null;
      }
      try {
        _messages.addAll(_framer.feed(_iterator.current));
      } catch (_) {
        _eof = true;
        return null;
      }
    }
    return _messages.removeFirst();
  }

  Future<void> cancel() async {
    _eof = true;
    try {
      await _iterator.cancel();
    } catch (_) {}
    _client.close(force: true);
  }
}

/// 交接准备：新连接的预检结果。
class _HandoverPrep {
  _HandoverPrep({required this.source, required this.reader});

  final LeasedSource source;
  final _UpstreamReader reader;

  /// 从新流缓冲的 tag（script 除外，含解码器配置与目标关键帧）。
  final List<Uint8List> buffer = <Uint8List>[];
  bool dead = false;
  bool targetFound = false;
  int targetRawTs = 0;

  /// 让预检任务尽快退出（交接时主循环要接管 reader，避免双读）。
  bool abort = false;
  final Completer<void> inspectorDone = Completer<void>();
}

/// 一次下游连接的拼接会话：把多节租约流拼成一条连续输出。
class _SpliceSession {
  _SpliceSession({required LeasedSource source, required this.renewer}) {
    _source = source;
    _updateLease();
  }

  /// 上游读超时；测试可通过 [FlvLeaseRelay.readTimeout] 注入更短值。
  static Duration get readTimeout => FlvLeaseRelay.readTimeout;

  final SourceRenewer renewer;

  late LeasedSource _source;
  DateTime? _invalidAt;
  DateTime? _refreshAt;
  _UpstreamReader? _reader;
  _HandoverPrep? _prep;
  bool _prepActive = false;

  int _offset = 0;
  bool _offsetFixed = false;
  int? _lastOutTs;
  int? _lastRawVideoTs;
  Uint8List? _lastConfig;
  bool _scriptSent = false;
  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
    _reader?.cancel();
    _prep?.reader.cancel();
  }

  void _updateLease() {
    final invalid = _source.invalidAt;
    if (invalid == null) {
      _invalidAt = null;
      _refreshAt = null;
      return;
    }
    final adjusted = invalid.subtract(_invalidSafety);
    _invalidAt = adjusted;
    final expire = _source.expireSeconds!;
    final leadSeconds = expire ~/ 4 < _renewLeadDefault.inSeconds
        ? expire ~/ 4
        : _renewLeadDefault.inSeconds;
    _refreshAt = adjusted.subtract(Duration(seconds: leadSeconds));
  }

  int _computeOffset(int rawTs) {
    final last = _lastRawVideoTs;
    if (last == null) return 0;
    if ((rawTs - last).abs() <= _alignmentWindow.inMilliseconds) return 0;
    final out = _lastOutTs;
    if (out == null) return 0;
    return out + 1 - rawTs;
  }

  /// 统一转发路径：新源首条视频 tag 处自适应偏移，输出时间戳单调钳制。
  /// [needKeyframe] 为 true 时丢弃关键帧之前的视频帧（硬切恢复用）。
  Uint8List? _forward(Uint8List tag, {bool needKeyframe = false}) {
    final isVideo = FlvTagUtils.isVideo(tag);
    final isConfig = FlvTagUtils.isVideoConfig(tag);

    // 与上一份解码器配置相同则不重发，避免解码器无谓重置。
    if (isConfig && FlvTagUtils.sameConfig(tag, _lastConfig)) {
      return null;
    }

    if (isVideo && !_offsetFixed) {
      _offset = _computeOffset(FlvTagUtils.timestamp(tag));
      _offsetFixed = true;
    }

    var outTs = FlvTagUtils.timestamp(tag) + _offset;
    final last = _lastOutTs;
    final stale = last != null && outTs <= last;

    if (isVideo) {
      _lastRawVideoTs = FlvTagUtils.timestamp(tag);
      // 硬切恢复：丢弃落后于输出进度的帧与非关键帧，直到关键帧追上。
      if (needKeyframe &&
          !isConfig &&
          (!FlvTagUtils.isKeyframe(tag) || stale)) {
        return null;
      }
    }

    if (stale) outTs = last + 1;
    final out = FlvTagUtils.withTimestamp(tag, outTs);
    if (isConfig) {
      _lastConfig = tag;
    }
    if (isVideo) {
      _lastOutTs = outTs;
    }
    return out;
  }

  /// 拼接输出流。下游断开时 addStream 取消生成器，finally 负责清理上游。
  Stream<Uint8List> pump() async* {
    try {
      // ---------- 首个源：临近过期先续期再连接 ----------
      var src = _source;
      if (src.expiredSoon) {
        final renewed = await _renewSafe();
        if (renewed != null) {
          src = renewed;
          _source = renewed;
          _updateLease();
        }
      }
      var opened = await _UpstreamReader.open(src.url, src.headers);
      if (opened == null) return;
      _UpstreamReader reader = opened;
      _reader = reader;

      // 先读出首条 tag（触发分帧），FLV 头就绪后只发一次。
      var carry = await _nextTag(reader);
      if (carry == null) return;
      final header = reader._framer.header;
      if (header != null) {
        yield header;
        yield Uint8List(4);
      }

      var attempts = 0;
      var nextRenewAt = DateTime.now();
      while (!_cancelled) {
        // ---------- 到点续流：时间驱动，独立任务执行 ----------
        final now = DateTime.now();
        if (!_prepActive &&
            _prep == null &&
            _refreshAt != null &&
            now.isAfter(_refreshAt!) &&
            now.isAfter(nextRenewAt) &&
            attempts < _renewMaxAttempts) {
          attempts += 1;
          nextRenewAt = now.add(_renewRetryDelay);
          _prepActive = true;
          unawaited(
            _prepareTask().whenComplete(() => _prepActive = false),
          );
        }

        final tag = carry ?? await _nextTag(reader);
        carry = null;
        if (tag == null) {
          // 旧连接死亡：有准备就立即交接（最多丢一个 GOP），否则输出结束。
          if (_prep != null) {
            final prep = _prep!;
            await _waitInspector(prep);
            final needKeyframe = !prep.targetFound;
            _adopt(prep);
            for (final buffered in prep.buffer) {
              final out = _forward(buffered, needKeyframe: needKeyframe);
              if (out != null) yield out;
            }
            unawaited(reader.cancel());
            reader = prep.reader;
            _reader = reader;
            _prep = null;
            attempts = 0;
            continue;
          }
          return;
        }

        if (FlvTagUtils.isScript(tag)) {
          // 元数据只转发首个源的。
          if (!_scriptSent) {
            _scriptSent = true;
            yield tag;
          }
          continue;
        }

        // ---------- 切换判定（先于转发）：旧流到达目标帧即停 ----------
        // 该帧起的旧内容由新流覆盖，避免重复帧；从新流的目标关键帧无缝续上。
        if (_prep != null && _prep!.targetFound) {
          final reached = FlvTagUtils.timestamp(tag) >= _prep!.targetRawTs;
          final forced = _invalidAt != null &&
              DateTime.now().isAfter(_invalidAt!.add(_forceSwitchGrace));
          if (reached || forced) {
            final prep = _prep!;
            await _waitInspector(prep);
            _adopt(prep);
            for (final buffered in prep.buffer) {
              final out2 = _forward(buffered);
              if (out2 != null) yield out2;
            }
            unawaited(reader.cancel());
            reader = prep.reader;
            _reader = reader;
            _prep = null;
            attempts = 0;
            continue;
          }
        }

        final out = _forward(tag);
        if (out != null) yield out;
      }
    } finally {
      await _reader?.cancel();
      _prep?.reader.cancel();
    }
  }

  /// 交接：接管新源并更新租约信息（缓冲数据由 pump 转发）。
  /// 偏移量在缓冲/后续首条视频 tag 处重新自适应。
  void _adopt(_HandoverPrep prep) {
    _reader = prep.reader;
    _source = prep.source;
    _updateLease();
    _offsetFixed = false;
  }

  Future<LeasedSource?> _renewSafe() async {
    try {
      return await renewer();
    } catch (e) {
      CoreLog.w('FlvLeaseRelay: renew failed: $e');
      return null;
    }
  }

  Future<Uint8List?> _nextTag(_UpstreamReader reader) async {
    try {
      return await reader.next().timeout(readTimeout);
    } on TimeoutException {
      await reader.cancel();
      return null;
    }
  }

  /// 让预检任务在接管 reader 前退出，避免双读。
  Future<void> _waitInspector(_HandoverPrep prep) async {
    prep.abort = true;
    if (!prep.inspectorDone.isCompleted) {
      await prep.inspectorDone.future.timeout(
        const Duration(milliseconds: 300),
        onTimeout: () {},
      );
    }
  }

  /// 续流任务：单次尝试「解析下一节 → 连接 → 预检」。
  /// 失败后由主循环按节奏重新发起。
  Future<void> _prepareTask() async {
    final source = await _renewSafe();
    CoreLog.d('FlvLeaseRelay: prepare renewed=${source != null}');
    if (_cancelled || source == null || _prep != null) return;
    final reader = await _UpstreamReader.open(source.url, source.headers);
    CoreLog.d('FlvLeaseRelay: prepare opened=${reader != null}');
    if (_cancelled || reader == null) return;
    final prep = _HandoverPrep(source: source, reader: reader);
    _prep = prep;
    await _inspect(prep);
    CoreLog.d(
      'FlvLeaseRelay: inspect done target=${prep.targetFound} '
      'ts=${prep.targetRawTs} buffer=${prep.buffer.length} dead=${prep.dead}',
    );
  }

  /// 预检新流：缓冲到「旧流尚未送达的关键帧」为止。
  Future<void> _inspect(_HandoverPrep prep) async {
    try {
      final deadline = DateTime.now().add(_inspectDeadline);
      while (!prep.abort && !_cancelled) {
        final tag = await prep.reader.next();
        if (tag == null) {
          prep.dead = true;
          return;
        }
        if (FlvTagUtils.isScript(tag)) continue;
        // 重连到的流可能从早于当前进度的时间点开始（如缓存/回放地址），
        // 落后于当前进度的内容直接丢弃，避免倒带。
        if (!FlvTagUtils.isVideoConfig(tag) &&
            _lastRawVideoTs != null &&
            FlvTagUtils.timestamp(tag) <= _lastRawVideoTs!) {
          continue;
        }
        prep.buffer.add(tag);
        if (FlvTagUtils.isVideoConfig(tag)) continue;
        if (FlvTagUtils.isKeyframe(tag)) {
          prep.targetRawTs = FlvTagUtils.timestamp(tag);
          prep.targetFound = true;
          return;
        }
        if (DateTime.now().isAfter(deadline) && prep.buffer.isNotEmpty) {
          // 等不到关键帧（如纯音频）：退化为首个不落后于旧进度的分片。
          final last = _lastRawVideoTs ?? 0;
          final fallback = prep.buffer.firstWhere(
            (t) => FlvTagUtils.timestamp(t) >= last,
            orElse: () => prep.buffer.last,
          );
          prep.targetRawTs = FlvTagUtils.timestamp(fallback);
          prep.targetFound = true;
          return;
        }
      }
    } catch (_) {
      prep.dead = true;
    } finally {
      if (!prep.inspectorDone.isCompleted) {
        prep.inspectorDone.complete();
      }
    }
  }
}

/// 本地 FLV 租约续流服务。
///
/// 为每个注册的线路 key 提供一个本地地址；播放器 GET 时才真正连接上游，
/// 同 key 的旧会话会被新请求取代。整个服务随 [close] 一起销毁。
class FlvLeaseRelay {
  /// 上游读超时；测试可注入更短值。
  static Duration readTimeout = _defaultReadTimeout;

  final _endpoints = <String, _Endpoint>{};
  final _active = <String, _SpliceSession>{};
  HttpServer? _server;
  bool _closed = false;

  int get port => _server?.port ?? 0;

  /// 启动本地监听（127.0.0.1 随机端口）。
  Future<void> start() async {
    if (_server != null) return;
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(
      _handle,
      onError: (Object e) => CoreLog.w('FlvLeaseRelay: server error: $e'),
    );
    CoreLog.d('FlvLeaseRelay: listening on 127.0.0.1:${_server!.port}');
  }

  /// 注册一条线路，返回交给播放器的本地地址。
  Future<String> register({
    required String key,
    required LeasedSource source,
    required SourceRenewer renewer,
  }) async {
    if (_server == null) {
      await start();
    }
    _endpoints[key] = _Endpoint(source: source, renewer: renewer);
    return 'http://127.0.0.1:${_server!.port}/$key.flv';
  }

  Future<void> close() async {
    _closed = true;
    for (final session in _active.values) {
      session.cancel();
    }
    _active.clear();
    _endpoints.clear();
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path.startsWith('/')
        ? request.uri.path.substring(1)
        : request.uri.path;
    // 本地地址形如 /<key>.flv，剥掉后缀得到注册 key。
    final key =
        path.endsWith('.flv') ? path.substring(0, path.length - 4) : path;
    final endpoint = _endpoints[key];
    if (_closed || endpoint == null) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final previous = _active.remove(path);
    previous?.cancel();

    CoreLog.d('FlvLeaseRelay: session start for $path');
    final session =
        _SpliceSession(source: endpoint.source, renewer: endpoint.renewer);
    _active[path] = session;
    try {
      request.response.headers.set(HttpHeaders.contentTypeHeader, 'video/x-flv');
      request.response.bufferOutput = false;
      await request.response.addStream(session.pump());
    } catch (e) {
      CoreLog.w('FlvLeaseRelay: session $path ended: $e');
    } finally {
      if (identical(_active[path], session)) {
        _active.remove(path);
      }
      session.cancel();
      try {
        await request.response.close();
      } catch (_) {}
    }
  }
}

class _Endpoint {
  _Endpoint({required this.source, required this.renewer});

  final LeasedSource source;
  final SourceRenewer renewer;
}
