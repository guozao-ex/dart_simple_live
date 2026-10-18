import '../model/live_play_url.dart';
import 'flv_renew_relay.dart';

/// 把一份播放地址接到 FLV 续流中继上。
///
/// 只在「平台提供了续流取址回调 + 地址看起来是 HTTP-FLV」时启用；其余情况
/// （以及中继启动失败时）[create] 返回 null，调用方继续用原始地址播放。
class FlvRenewPlayback {
  FlvRenewPlayback._(this._relay, this.urls);

  final FlvRenewRelay _relay;

  /// 交给播放器的地址，顺序与原始地址一致。
  final List<String> urls;

  /// 是否是看起来可以直接走的 HTTP-FLV 地址。
  ///
  /// HLS（m3u8）不能按 tag 接续，所以不接入中继。
  static bool looksLikeFlv(String url) => url.toLowerCase().contains('.flv');

  /// 接入中继；返回 null 表示不接入（调用方用原始地址）。
  static Future<FlvRenewPlayback?> create(LivePlayUrl playUrl) async {
    final renew = playUrl.renewUrl;
    if (renew == null || playUrl.urls.isEmpty) {
      return null;
    }
    final wrapIndexes = <int>[
      for (var i = 0; i < playUrl.urls.length; i++)
        if (looksLikeFlv(playUrl.urls[i])) i,
    ];
    if (wrapIndexes.isEmpty) {
      return null;
    }
    final relay = FlvRenewRelay();
    try {
      await relay.start();
    } catch (error) {
      FlvRenewRelay.log('FLV 续流中继启动失败，改用直连播放', error: error);
      return null;
    }
    final urls = List<String>.from(playUrl.urls);
    for (final index in wrapIndexes) {
      try {
        urls[index] = await relay.register(
          key: 'line$index',
          url: playUrl.urls[index],
          headers: playUrl.headers,
          renew: () => renew(index),
        );
      } catch (error) {
        // 单条线路登记失败就保持原地址，不影响其他线路
        FlvRenewRelay.log('第 ${index + 1} 条线路无法接入续流', error: error);
      }
    }
    if (!urls.any(FlvRenewRelay.isRelayUrl)) {
      await relay.close();
      return null;
    }
    return FlvRenewPlayback._(relay, urls);
  }

  /// 断开中继（离开直播间或换清晰度时调用）。
  Future<void> close() => _relay.close();
}
