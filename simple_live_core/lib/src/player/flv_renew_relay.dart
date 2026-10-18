import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import '../common/core_log.dart';

/// 上游连接的预期寿命。
///
/// 斗鱼自 2026-09 起对第三方拉流按固定寿命掐线：实测同一地址的存活稳定在
/// 300.1~300.4s，与带宽、码率、CDN 无关；部分线路即使地址里没有 expire
/// 参数也同样准时断开，所以不能靠解析 URL 判断是否需要续流。
const Duration kFlvRenewTtl = Duration(seconds: 300);

/// 到期前多久开始预取下一条连接。
///
/// 一次取流 + 首个关键帧约 0.9s，5s 余量充足；留得过长会让预取连接
/// 在切换前积压过多数据。
const Duration kFlvRenewLead = Duration(seconds: 5);

/// 预取连接最多先缓冲多少字节，超出后暂停读取上游（切换时恢复）。
const int kFlvPrefetchBufferBytes = 8 << 20;

/// 上游无数据判定死亡的时间。
const Duration kFlvUpstreamIdleTimeout = Duration(seconds: 15);

/// 续流调度与拼接的日志回调，宿主可接到自己的日志系统上。
typedef FlvRenewLogger = void Function(String message, {Object? error});

/// FLV 续流中继。
///
/// 用法：创建中继并 start()，为每条线路 register() 一个本机地址交给播放器，
/// 离开直播间时 close()。中继对播放器完全透明：播放器只连本机固定地址，
/// 换流、时间戳去重、连接重试都在中继内部完成。
class FlvRenewRelay {
  FlvRenewRelay({
    this.ttl = kFlvRenewTtl,
    this.prefetchLead = kFlvRenewLead,
    this.prefetchBufferBytes = kFlvPrefetchBufferBytes,
    this.renewRetryInterval = const Duration(seconds: 15),
    this.spliceDeadline = const Duration(seconds: 8),
  });

  /// 全局日志钩子；未设置时输出到 core 日志。
  static FlvRenewLogger? logger;

  /// 输出一条续流日志（外部接入方也可复用同一钩子）。
  static void log(String message, {Object? error}) =>
      _log(message, error: error);

  static void _log(String message, {Object? error}) {
    final hook = logger;
    if (hook == null) {
      CoreLog.d(error == null ? message : '$message（$error）');
      return;
    }
    try {
      hook(message, error: error);
    } catch (_) {
      // 日志失败不影响续流
    }
  }

  /// 上游连接预期寿命。
  final Duration ttl;

  /// 到期前预取提前量。
  final Duration prefetchLead;

  /// 预取缓冲上限。
  final int prefetchBufferBytes;

  /// 预取失败后的重试间隔（连续失败会按倍数退避）。
  final Duration renewRetryInterval;

  /// 等待新流拼接点的上限；等不到会退回兜底规则取切换点。
  final Duration spliceDeadline;

  HttpServer? _server;
  final Map<String, _RelaySource> _sources = {};
  final Set<_RelaySession> _sessions = {};
  bool _closed = false;

  /// 本机监听端口，未启动时为 0。
  int get port => _server?.port ?? 0;

  /// 是否为中继地址（用于跳过强制 HTTPS 之类的改写）。
  static bool isRelayUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      return false;
    }
    return (uri.host == '127.0.0.1' || uri.host == 'localhost') && uri.port > 0;
  }

  /// 启动本机代理服务。
  Future<void> start() async {
    if (_server != null || _closed) {
      return;
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.autoCompress = false;
    _server = server;
    server.listen(
      _handleRequest,
      onError: (Object error) => _log('中继监听出错', error: error),
    );
    _log('FLV 续流中继已启动：127.0.0.1:${server.port}');
  }

  /// 登记一条可续流的播放地址，返回交给播放器的本机地址。
  Future<String> register({
    required String key,
    required String url,
    required Future<String?> Function() renew,
    Map<String, String>? headers,
  }) async {
    await start();
    _sources[key] = _RelaySource(
      key: key,
      url: url,
      headers: headers ?? const {},
      renew: renew,
    );
    return 'http://127.0.0.1:$port/$key.flv';
  }

  /// 关闭中继：断开所有下游与上游连接。
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    _sources.clear();
    for (final session in _sessions.toList()) {
      session.cancel();
    }
    _sessions.clear();
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  void _handleRequest(HttpRequest request) {
    final path = request.uri.path;
    final name = path.startsWith('/') ? path.substring(1) : path;
    final key = name.endsWith('.flv') ? name.substring(0, name.length - 4) : name;
    final source = _sources[key];
    if (source == null || _closed) {
      request.response.statusCode = HttpStatus.notFound;
      unawaited(request.response.close().catchError((Object _) {}));
      return;
    }
    final session = _RelaySession(
      relay: this,
      source: source,
      response: request.response,
    );
    _sessions.add(session);
    unawaited(session.run().whenComplete(() => _sessions.remove(session)));
  }
}

/// 一条线路的续流配置。
///
/// [url]/[freshAt] 会被续期结果持续刷新：播放器换线路、重连或 mediaError 重试
/// 都会新建会话，如果不落盘新地址，第二次起就会拿注册时的旧地址去连（斗鱼
/// 签名窗口只有约 5 分钟），表现为「看满 5 分钟后再也连不上」。
class _RelaySource {
  _RelaySource({
    required this.key,
    required this.url,
    required this.headers,
    required this.renew,
  }) : freshAt = DateTime.now();

  final String key;

  /// 最近一次已知可用的地址（续期成功后会刷新）。
  String url;

  /// [url] 的取得时刻。
  DateTime freshAt;

  final Map<String, String> headers;
  final Future<String?> Function() renew;
}

/// 一次下游播放会话：把多段上游连接拼成一条连续 FLV。
class _RelaySession {
  _RelaySession({required this.relay, required this.source, required this.response});

  final FlvRenewRelay relay;
  final _RelaySource source;
  final HttpResponse response;

  _Upstream? _current;
  _Upstream? _prefetch;
  bool _cancelled = false;
  bool _clientGone = false;

  /// 会话是否已收尾；用于挡住「预取 Future 迟到才回来」的泄漏。
  bool _finished = false;

  /// response.close() 只能走一次；重复关闭会抛 StreamSink is bound to a stream。
  bool _responseClosed = false;

  /// 上次预取失败的时刻；为空表示还没失败过（首次预取不受重试间隔限制）。
  DateTime? _prefetchFailedAt;

  /// 连续预取失败次数，用于退避。
  int _prefetchFailCount = 0;

  void cancel() {
    _cancelled = true;
    _finished = true;
    _current?.close();
    _current = null;
    _prefetch?.close();
    _prefetch = null;
    _clientGone = true;
    unawaited(_closeResponse());
  }

  /// 关闭下游响应；只允许关闭一次，且不因播放器已断开而抛错。
  Future<void> _closeResponse() async {
    if (_responseClosed) {
      return;
    }
    _responseClosed = true;
    try {
      await response.close();
    } catch (_) {
      // 播放器可能已经断开，忽略
    }
  }

  Future<void> run() async {
    response.statusCode = HttpStatus.ok;
    response.headers.contentType = ContentType('video', 'x-flv');
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    response.headers.set(HttpHeaders.accessControlAllowOriginHeader, '*');
    response.bufferOutput = false;
    unawaited(
      response.done.catchError((Object _) {
        _clientGone = true;
      }),
    );

    _Upstream current;
    try {
      // 注册时的地址可能已经过期：播放器换线路、重连、mediaError 重试都会新建
      // 会话，此时不能再拿几十分钟前那条地址去连（斗鱼签名窗口约 5 分钟）。
      var firstUrl = source.url;
      if (DateTime.now().difference(source.freshAt) >=
          relay.ttl - relay.prefetchLead) {
        final renewed = await _renewUrl();
        if (renewed != null) {
          firstUrl = renewed;
        } else {
          FlvRenewRelay._log('${source.key}: 首连前续期失败，沿用旧地址');
        }
      }
      current = await _open(firstUrl, source.headers);
    } catch (error) {
      FlvRenewRelay._log('${source.key}: 首次连接上游失败', error: error);
      await _fail(HttpStatus.badGateway);
      return;
    }
    if (_cancelled) {
      current.close();
      return;
    }
    _current = current;
    if (!current.isFlv) {
      // 上游不是 FLV（例如 CDN 回错误页）：报错让播放器走重试/换线路，
      // 而不是给一个 200 空响应把播放器挂死在这里
      FlvRenewRelay._log('${source.key}: 上游不是 FLV，放弃中继');
      current.close();
      await _fail(HttpStatus.badGateway);
      return;
    }
    if (!await _write(current.headerBytes)) {
      current.close();
      return;
    }

    var lastTs = -1;
    Future<void>? prefetchTask;

    while (!_cancelled && !_clientGone) {
      // 预取调度：到期前 lead 秒开始拉下一条；失败按退避间隔再试（上限 5 分钟），
      // 避免对平台取流接口做无上限打点。
      final failedAt = _prefetchFailedAt;
      final retryReady =
          failedAt == null || DateTime.now().difference(failedAt) >= _prefetchBackoff();
      if (current.isFlv &&
          _prefetch == null &&
          prefetchTask == null &&
          retryReady &&
          current.aliveFor >= relay.ttl - relay.prefetchLead) {
        prefetchTask = _startPrefetch((upstream) => _prefetch = upstream)
            .whenComplete(() => prefetchTask = null);
      }

      // 到期即主动切换：不依赖上游是否真的掐线（实测同一条线有的活 300s，
      // 有的更久），切在关键帧上对播放器无感。
      if (current.isFlv && _prefetch != null && current.aliveFor >= relay.ttl) {
        final ready = _prefetch!;
        final splicedTs = await _spliceTo(ready, lastTs);
        if (splicedTs != null) {
          lastTs = splicedTs;
          _prefetchFailedAt = null;
          _prefetchFailCount = 0;
          current.close();
          current = ready;
          _current = current;
          _prefetch = null;
          FlvRenewRelay._log('${source.key}: 到期换流完成');
          continue;
        }
        ready.close();
        _prefetch = null;
      }

      _Chunk? chunk;
      try {
        chunk = await current.next().timeout(kFlvUpstreamIdleTimeout);
      } on TimeoutException {
        FlvRenewRelay._log('${source.key}: 上游 ${kFlvUpstreamIdleTimeout.inSeconds}s 无数据，按断流处理');
        chunk = null;
      } catch (error) {
        FlvRenewRelay._log('${source.key}: 读取上游出错', error: error);
        chunk = null;
      }

      if (chunk == null) {
        // 上游结束：优先用预取连接，没有就同步补一条；一次拼不上再补一次，
        // 两次都失败才结束会话（避免一次抖动就断掉整场播放）。
        final next = _prefetch ?? await _openRenewed();
        _prefetch = null;
        prefetchTask = null;
        if (next != null) {
          final splicedTs = await _spliceTo(next, lastTs);
          if (splicedTs != null) {
            lastTs = splicedTs;
            _prefetchFailedAt = null;
            _prefetchFailCount = 0;
            current.close();
            current = next;
            _current = current;
            FlvRenewRelay._log('${source.key}: 断流续接完成');
            continue;
          }
          next.close();
        }
        await Future<void>.delayed(relay.renewRetryInterval ~/ 3);
        final retry = await _openRenewed();
        if (retry == null) {
          FlvRenewRelay._log('${source.key}: 上游断开且无法续流，结束本会话');
          break;
        }
        final retryTs = await _spliceTo(retry, lastTs);
        if (retryTs == null) {
          retry.close();
          FlvRenewRelay._log('${source.key}: 续流拼接失败，结束本会话');
          break;
        }
        lastTs = retryTs;
        current.close();
        current = retry;
        _current = current;
        FlvRenewRelay._log('${source.key}: 断流续接完成');
        continue;
      }

      // 正常转发：攒够一批再写，减少写放大。
      final batch = BytesBuilder(copy: false);
      batch.add(chunk.bytes);
      if (chunk.tag != null) {
        lastTs = _maxTs(lastTs, chunk.tag!.timestamp);
      }
      while (batch.length < 64 * 1024) {
        final more = current.tryNext();
        if (more == null) {
          break;
        }
        batch.add(more.bytes);
        if (more.tag != null) {
          lastTs = _maxTs(lastTs, more.tag!.timestamp);
        }
      }
      if (!await _write(batch.takeBytes())) {
        break;
      }
    }

    current.close();
    // 循环退出时预取连接可能还挂着（比如播放器刚断开），一并收掉
    _prefetch?.close();
    _prefetch = null;
    _finished = true;
    await _closeResponse();
  }

  /// 把 [next] 接到已转发位置 [lastTs] 之后。
  ///
  /// 返回续接后的最新时间戳；返回 null 表示这条连接不可用（调用方应结束或另找连接）。
  Future<int?> _spliceTo(_Upstream next, int lastTs) async {
    if (!next.isFlv) {
      return null;
    }
    // 旧连接里还没转发的尾巴先发出去：它是旧流的自然延续，
    // 不能和新连接的 tag 混在一起找切换点（混在一起会让时间轴来回跳）。
    final flushed = await _flushTail(_current, lastTs);
    if (flushed == null) {
      return null;
    }
    lastTs = flushed;
    final buffered = next.drain();
    final deadline = DateTime.now().add(relay.spliceDeadline);
    _SplicePlan? plan = _plan(buffered, lastTs);
    while (plan == null) {
      if (!next.alive || DateTime.now().isAfter(deadline)) {
        break;
      }
      // 主动换流时旧连接还活着：等新流关键帧的这段时间继续把旧流喂给播放器，
      // 换流瞬间既不空转也不丢一个 GOP。
      final old = _current;
      if (old != null && !identical(old, next) && old.alive) {
        final pumped = await _flushTail(old, lastTs);
        if (pumped == null) {
          return null;
        }
        lastTs = pumped;
        plan = _plan(buffered, lastTs);
        if (plan != null) {
          break;
        }
      }
      try {
        final chunk = await next.next().timeout(const Duration(milliseconds: 250));
        if (chunk == null) {
          break;
        }
        if (chunk.tag != null) {
          buffered.add(chunk.tag!);
        }
      } on TimeoutException {
        // 新流还没吐出下一个 tag，回去继续喂旧流
        continue;
      } catch (_) {
        break;
      }
      plan = _plan(buffered, lastTs);
    }
    if (plan == null) {
      return null;
    }

    final out = BytesBuilder(copy: false);
    var expected = lastTs;
    final planOffset = plan.offset;
    // 编码配置有变化时先补发新配置，避免播放器沿用旧的 SPS/PPS。
    // 配置 tag 的时间戳同样要跟着偏移，否则会把单调的时间轴拽回去。
    void emitConfig(FlvTag tag) {
      final ts = _clampTs(tag.timestamp + planOffset, expected);
      out.add(ts == tag.timestamp ? tag.bytes : tag.copyWithTimestamp(ts).bytes);
      expected = _maxTs(expected, ts);
    }

    final videoConfig = plan.videoConfig;
    final audioConfig = plan.audioConfig;
    if (videoConfig != null) {
      emitConfig(videoConfig);
    }
    if (audioConfig != null) {
      emitConfig(audioConfig);
    }
    for (final tag in plan.tags) {
      var bytes = tag.bytes;
      final ts = _clampTs(tag.timestamp + plan.offset, expected);
      if (ts != tag.timestamp) {
        bytes = tag.copyWithTimestamp(ts).bytes;
      }
      expected = _maxTs(expected, ts);
      out.add(bytes);
    }
    if (out.length > 0 && !await _write(out.takeBytes())) {
      return null;
    }
    return expected;
  }

  /// 把 [upstream] 已缓冲的 tag 分批写出去，返回推进后的时间戳。
  ///
  /// 返回 null 表示下游已断开。分批写是为了避免积压很多时做一次大拷贝。
  Future<int?> _flushTail(_Upstream? upstream, int lastTs) async {
    if (upstream == null) {
      return lastTs;
    }
    final pending = upstream.drain();
    if (pending.isEmpty) {
      return lastTs;
    }
    final tail = BytesBuilder(copy: false);
    var size = 0;
    for (final tag in pending) {
      tail.add(tag.bytes);
      size += tag.bytes.length;
      lastTs = _maxTs(lastTs, tag.timestamp);
      if (size >= 64 * 1024) {
        if (!await _write(tail.takeBytes())) {
          return null;
        }
        size = 0;
      }
    }
    if (size > 0 && !await _write(tail.takeBytes())) {
      return null;
    }
    return lastTs;
  }

  _SplicePlan? _plan(List<FlvTag> buffered, int lastTs) {
    if (buffered.isEmpty) {
      return null;
    }
    // 优先：已转发位置之后的第一条视频关键帧（无感接续的标准做法）。
    var index = _firstIndex(
      buffered,
      (tag) => tag.isVideo && tag.isKeyframe && tag.timestamp > lastTs,
    );
    // 兜底一：已转发位置之后的第一条视频帧（解码器会等到下一个关键帧）。
    index ??= _firstIndex(
      buffered,
      (tag) => tag.isVideo && tag.timestamp > lastTs,
    );
    // 兜底二：纯音频/没有视频关键帧的流（音乐、电台房），取第一条不落后于
    // 已转发位置的 tag，音频也接受。
    index ??= _firstIndex(buffered, (tag) => tag.timestamp >= lastTs);
    // 兜底三：整条流时间轴回退（主播重推/换会话），重设时间基准后从关键帧接。
    var offset = 0;
    if (index == null) {
      final keyIndex = _firstIndex(
        buffered,
        (tag) => tag.isVideo && tag.isKeyframe,
      );
      if (keyIndex == null) {
        return null;
      }
      offset = lastTs + 1 - buffered[keyIndex].timestamp;
      index = keyIndex;
    }
    final slice = buffered.sublist(index);
    if (slice.isEmpty) {
      return null;
    }

    // 只取切换点之前的配置：切换点之后才出现的新 SPS/PPS 不能提前发，
    // 否则用旧配置编出来的帧会被按新配置解（一帧花屏或报错）。
    FlvTag? videoConfig;
    FlvTag? audioConfig;
    for (var i = 0; i < index; i++) {
      final tag = buffered[i];
      if (tag.isVideoSequenceHeader) {
        videoConfig = tag;
      } else if (tag.isAudioSequenceHeader) {
        audioConfig = tag;
      }
    }
    final current = _current;
    final videoChanged = videoConfig != null &&
        videoConfig.dataSize > 0 &&
        !_samePayload(videoConfig, current?.videoConfig);
    final audioChanged = audioConfig != null &&
        audioConfig.dataSize > 0 &&
        !_samePayload(audioConfig, current?.audioConfig);

    return _SplicePlan(
      tags: slice,
      offset: offset,
      videoConfig: videoChanged ? videoConfig : null,
      audioConfig: audioChanged ? audioConfig : null,
    );
  }

  /// 预取失败后的退避间隔：15s、30s、60s…封顶 5 分钟，避免对取流接口无上限打点。
  Duration _prefetchBackoff() {
    final base = relay.renewRetryInterval.inMilliseconds;
    final shift = _prefetchFailCount > 4 ? 4 : _prefetchFailCount;
    final ms = base * (1 << shift);
    return Duration(milliseconds: ms > 300000 ? 300000 : ms);
  }

  /// 只取新地址（不建连接），成功后刷新 source，供后续会话复用。
  Future<String?> _renewUrl() async {
    try {
      final url = await source.renew();
      if (url == null || url.isEmpty) {
        return null;
      }
      source.url = url;
      source.freshAt = DateTime.now();
      return url;
    } catch (error) {
      FlvRenewRelay._log('${source.key}: 续流取地址失败', error: error);
      return null;
    }
  }

  /// 预取：解析地址并建立连接，成功后交给回调。
  Future<void> _startPrefetch(void Function(_Upstream?) assign) async {
    try {
      final upstream = await _openRenewed();
      if (upstream == null) {
        _prefetchFailedAt = DateTime.now();
        _prefetchFailCount += 1;
        FlvRenewRelay._log('${source.key}: 预取未取得新地址');
        return;
      }
      if (_cancelled || _clientGone || _finished) {
        // 会话已经结束（比如播放器刚断开），这条预取连接没人会用，直接收掉
        upstream.close();
        return;
      }
      _prefetchFailedAt = null;
      _prefetchFailCount = 0;
      assign(upstream);
    } catch (error) {
      _prefetchFailedAt = DateTime.now();
      _prefetchFailCount += 1;
      FlvRenewRelay._log('${source.key}: 预取失败', error: error);
    }
  }

  static int? _firstIndex(List<FlvTag> tags, bool Function(FlvTag) test) {
    for (var i = 0; i < tags.length; i++) {
      if (test(tags[i])) {
        return i;
      }
    }
    return null;
  }

  static bool _samePayload(FlvTag a, FlvTag? b) {
    if (b == null) {
      return false;
    }
    final x = a.data;
    final y = b.data;
    if (x.length != y.length) {
      return false;
    }
    for (var i = 0; i < x.length; i++) {
      if (x[i] != y[i]) {
        return false;
      }
    }
    return true;
  }

  static int _maxTs(int a, int b) => a > b ? a : b;

  /// 只防倒退，不改动正常时间轴。
  static int _clampTs(int ts, int expected) => ts < expected ? expected : ts;

  Future<_Upstream?> _openRenewed() async {
    final url = await _renewUrl();
    if (url == null) {
      return null;
    }
    try {
      final upstream = await _open(url, source.headers);
      if (!upstream.isFlv) {
        upstream.close();
        FlvRenewRelay._log('${source.key}: 新地址不是 FLV，放弃续流');
        return null;
      }
      return upstream;
    } catch (error) {
      FlvRenewRelay._log('${source.key}: 续流取地址失败', error: error);
      return null;
    }
  }

  /// 建立上游连接。
  ///
  /// 这里对**当前连接**也启用「缓冲满就暂停读取」：下游播放器一旦停止读取
  /// （缓冲满、进后台、解码跟不上），暂停会顺着 TCP 反压回 CDN，而不是让
  /// 队列在内存里无限增长。
  Future<_Upstream> _open(String url, Map<String, String> headers) {
    return _Upstream.open(
      Uri.parse(url),
      headers,
      bufferLimit: relay.prefetchBufferBytes,
      pauseWhenBuffered: true,
    );
  }

  Future<bool> _write(Uint8List bytes) async {
    if (_clientGone || _cancelled) {
      return false;
    }
    try {
      response.add(bytes);
      await response.flush();
      return true;
    } catch (error) {
      _clientGone = true;
      _current?.close();
      return false;
    }
  }

  Future<void> _fail(int status) async {
    if (_clientGone) {
      return;
    }
    _clientGone = true;
    try {
      response.statusCode = status;
    } catch (_) {
      // 播放器可能已经断开
    }
    await _closeResponse();
  }
}

/// 一次拼接计划。
class _SplicePlan {
  _SplicePlan({
    required this.tags,
    required this.offset,
    required this.videoConfig,
    required this.audioConfig,
  });

  final List<FlvTag> tags;
  final int offset;
  final FlvTag? videoConfig;
  final FlvTag? audioConfig;
}

/// 上游连接的一条输出：FLV 模式为一条完整 tag，不透明模式为一段原始字节。
class _Chunk {
  _Chunk(this.bytes, this.tag);

  final Uint8List bytes;

  /// 解析出的 tag；为 null 表示这段数据不参与时间轴跟踪。
  final FlvTag? tag;
}

/// 上游 HTTP-FLV 连接。
class _Upstream {
  _Upstream._(this._client, this._response);

  final HttpClient _client;
  final HttpClientResponse _response;

  final FlvFramer _framer = FlvFramer();
  final Queue<_Chunk> _queue = Queue();

  StreamSubscription<List<int>>? _subscription;
  Completer<void>? _waiter;
  bool _done = false;
  bool _paused = false;
  int _bufferedBytes = 0;
  final DateTime _openedAt = DateTime.now();
  Duration _startDelay = Duration.zero;

  /// 是否解析出 FLV 头。
  bool get hasHeader => _framer.header != null;

  /// 是否为可解析的 FLV 流。
  bool get isFlv => _framer.header != null;

  /// 连接建立至今。
  Duration get aliveFor => DateTime.now().difference(_openedAt);

  /// 首包到达耗时。
  Duration get startDelay => _startDelay;

  /// 连接是否还活着。
  bool get alive => !_done;

  /// FLV 头 + PreviousTagSize0。
  Uint8List get headerBytes => _framer.header!;

  FlvTag? get videoConfig => _framer.videoConfig;
  FlvTag? get audioConfig => _framer.audioConfig;

  static Future<_Upstream> open(
    Uri uri,
    Map<String, String> headers, {
    int bufferLimit = kFlvPrefetchBufferBytes,
    bool pauseWhenBuffered = false,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8);
    _Upstream? upstream;
    try {
      final request = await client.getUrl(uri);
      headers.forEach((key, value) {
        try {
          request.headers.set(key, value);
        } catch (_) {
          // 个别头不允许设置时忽略
        }
      });
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      // connectionTimeout 只管建连，等响应头必须自己限时，否则对端只收不回时会挂死
      final response = await request
          .close()
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      upstream = _Upstream._(client, response);
      upstream._listen(
        bufferLimit: bufferLimit,
        pauseWhenBuffered: pauseWhenBuffered,
      );
      await upstream._waitFirst();
      return upstream;
    } catch (error) {
      if (upstream != null) {
        upstream.close();
      } else {
        client.close(force: true);
      }
      rethrow;
    }
  }

  void _listen({required int bufferLimit, required bool pauseWhenBuffered}) {
    _subscription = _response.listen(
      (data) {
        List<FlvTag> tags;
        try {
          tags = _framer.feed(data);
        } catch (_) {
          // 不是 FLV：不透明转发，交给上层自行判断
          if (_framer.header == null && _queue.isEmpty) {
            _queue.add(_Chunk(Uint8List.fromList(data), null));
            _bufferedBytes += data.length;
            _notify();
          }
          return;
        }
        if (tags.isEmpty) {
          if (_framer.header == null && _queue.isEmpty) {
            _queue.add(_Chunk(Uint8List.fromList(data), null));
            _bufferedBytes += data.length;
            _notify();
          }
          return;
        }
        for (final tag in tags) {
          _queue.add(_Chunk(tag.bytes, tag));
          _bufferedBytes += tag.bytes.length;
        }
        _notify();
        if (pauseWhenBuffered && _bufferedBytes >= bufferLimit && !_paused) {
          _paused = true;
          _subscription?.pause();
        }
      },
      onError: (Object _) => _finish(),
      onDone: _finish,
      cancelOnError: false,
    );
  }

  Future<void> _waitFirst() async {
    if (_framer.header != null || _queue.isNotEmpty || _done) {
      _startDelay = DateTime.now().difference(_openedAt);
      return;
    }
    await (_waiter ??= Completer<void>()).future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {},
    );
    _startDelay = DateTime.now().difference(_openedAt);
    if (_framer.header == null && _queue.isEmpty && !_done) {
      throw const HttpException('上游未返回数据');
    }
  }

  void _finish() {
    _done = true;
    _notify();
  }

  void _notify() {
    final waiter = _waiter;
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
    }
  }

  /// 取下一段数据；返回 null 表示上游已结束。
  Future<_Chunk?> next() async {
    if (_queue.isNotEmpty) {
      return _dequeue();
    }
    if (_done) {
      return null;
    }
    final waiter = _waiter = Completer<void>();
    await waiter.future;
    if (_queue.isNotEmpty) {
      return _dequeue();
    }
    return null;
  }

  /// 立即取一段已缓冲的数据，没有则返回 null。
  _Chunk? tryNext() => _queue.isEmpty ? null : _dequeue();

  /// 取走当前已缓冲的全部 tag（用于拼接时挑选切换点）。
  List<FlvTag> drain() {
    final tags = <FlvTag>[
      for (final chunk in _queue)
        if (chunk.tag != null) chunk.tag!,
    ];
    _queue.clear();
    _bufferedBytes = 0;
    _resume();
    return tags;
  }

  _Chunk _dequeue() {
    final chunk = _queue.removeFirst();
    _bufferedBytes -= chunk.bytes.length;
    if (_queue.isEmpty) {
      _resume();
    }
    return chunk;
  }

  void _resume() {
    if (_paused) {
      _paused = false;
      try {
        _subscription?.resume();
      } catch (_) {
        // 订阅可能已取消
      }
    }
  }

  void close() {
    _done = true;
    _notify();
    final subscription = _subscription;
    _subscription = null;
    unawaited(subscription?.cancel() ?? Future<void>.value());
    _client.close(force: true);
  }
}

/// 增量解析 HTTP-FLV：先给出 9 字节 FLV 头 + 4 字节 PreviousTagSize0，
/// 之后每个完整 tag（11 字节 tag 头 + 数据 + 4 字节 PreviousTagSize）作为一条输出。
class FlvFramer {
  final _BytesQueue _buffer = _BytesQueue();

  /// 9 字节 FLV 头 + 4 字节 PreviousTagSize0。
  Uint8List? header;

  /// 最近一次出现的视频/音频编码配置（sequence header）。
  FlvTag? videoConfig;
  FlvTag? audioConfig;

  List<FlvTag> feed(List<int> data) {
    if (data.isNotEmpty) {
      _buffer.add(data);
    }
    final tags = <FlvTag>[];
    if (header == null) {
      if (_buffer.length < 13) {
        return tags;
      }
      final head = _buffer.peek(13);
      if (head[0] != 0x46 || head[1] != 0x4C || head[2] != 0x56) {
        throw const FormatException('不是 FLV 流');
      }
      header = _buffer.take(13);
    }
    while (_buffer.length >= 11) {
      final tagHeader = _buffer.peek(11);
      final dataSize = (tagHeader[1] << 16) | (tagHeader[2] << 8) | tagHeader[3];
      final total = 11 + dataSize + 4;
      if (_buffer.length < total) {
        break;
      }
      final tag = FlvTag(_buffer.take(total));
      if (tag.isVideoSequenceHeader) {
        videoConfig = tag;
      } else if (tag.isAudioSequenceHeader) {
        audioConfig = tag;
      }
      tags.add(tag);
    }
    return tags;
  }
}

/// 一条完整的 FLV tag：11 字节 tag 头 + 数据 + 4 字节 PreviousTagSize。
class FlvTag {
  FlvTag(this.bytes);

  final Uint8List bytes;

  /// tag 类型：8 音频、9 视频、18 脚本数据。
  int get type => bytes[0] & 0x0F;

  bool get isAudio => type == 8;
  bool get isVideo => type == 9;
  bool get isScript => type == 18;

  int get dataSize => (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];

  /// 时间戳（毫秒）。
  int get timestamp =>
      (bytes[4] << 16) | (bytes[5] << 8) | bytes[6] | (bytes[7] << 24);

  /// tag 数据（去掉 tag 头与 PreviousTagSize）。
  Uint8List get data => Uint8List.sublistView(bytes, 11, 11 + dataSize);

  /// 视频关键帧。
  ///
  /// 传统 AVC 布局：高 4 位是 frame type（1 = 关键帧）；
  /// 增强型布局（ExVideoTagHeader）：最高位是 isExHeader，紧接的 3 位才是 frame type。
  /// 编码配置 tag（sequence header）不算帧，必须排除。
  bool get isKeyframe {
    if (!isVideo || dataSize < 2 || isVideoSequenceHeader) {
      return false;
    }
    final first = bytes[11];
    if (first & 0x80 != 0) {
      return ((first >> 4) & 0x07) == 1;
    }
    return (first >> 4) == 1;
  }

  /// 视频编码配置（AVC sequence header 或增强型 SequenceStart）。
  bool get isVideoSequenceHeader {
    if (!isVideo || dataSize < 2) {
      return false;
    }
    final first = bytes[11];
    if (first & 0x80 != 0) {
      return (first & 0x0F) == 0;
    }
    return bytes[12] == 0;
  }

  /// AAC 编码配置。
  bool get isAudioSequenceHeader {
    if (!isAudio || dataSize < 2) {
      return false;
    }
    final soundFormat = bytes[11] >> 4;
    return soundFormat == 10 && bytes[12] == 0;
  }

  /// 复制一份并改写时间戳。
  FlvTag copyWithTimestamp(int ts) {
    final copy = Uint8List.fromList(bytes);
    copy[4] = (ts >> 16) & 0xFF;
    copy[5] = (ts >> 8) & 0xFF;
    copy[6] = ts & 0xFF;
    copy[7] = (ts >> 24) & 0x7F;
    return FlvTag(copy);
  }
}

/// 只进不出的字节队列：支持 peek/take，内部按需压缩扩容。
class _BytesQueue {
  Uint8List _data = Uint8List(0);
  int _start = 0;
  int _end = 0;

  int get length => _end - _start;

  void add(List<int> chunk) {
    if (chunk.isEmpty) {
      return;
    }
    if (_start > 0 && _end + chunk.length > _data.length) {
      final kept = length;
      final compact = Uint8List(_data.length);
      compact.setRange(0, kept, _data, _start);
      _data = compact;
      _start = 0;
      _end = kept;
    }
    if (_end + chunk.length > _data.length) {
      var size = _data.isEmpty ? 4096 : _data.length;
      while (size < length + chunk.length) {
        size *= 2;
      }
      final grown = Uint8List(size);
      grown.setRange(0, length, _data, _start);
      _data = grown;
      _end = length;
      _start = 0;
    }
    _data.setRange(_end, _end + chunk.length, chunk);
    _end += chunk.length;
  }

  Uint8List peek(int count) =>
      Uint8List.fromList(Uint8List.sublistView(_data, _start, _start + count));

  Uint8List take(int count) {
    final out = Uint8List.fromList(
      Uint8List.sublistView(_data, _start, _start + count),
    );
    _start += count;
    if (_start == _end) {
      _start = 0;
      _end = 0;
    }
    return out;
  }
}
