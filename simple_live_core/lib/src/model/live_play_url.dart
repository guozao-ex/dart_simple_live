import 'dart:convert';

/// 按线路索引重新解析播放地址（同房间、同画质、同线路）。
///
/// 返回 null 表示平台不支持或本次解析失败。用于 FLV 续流中继在连接到期前
/// 换取新地址；斗鱼需要在续流时重新签名，签名时间戳的可用窗口约 5 分钟。
typedef LivePlayUrlRenewer = Future<String?> Function(int lineIndex);

class LivePlayUrl {
  /// 播放地址
  final List<String> urls;

  /// 请求头
  final Map<String, String>? headers;

  /// 可选：续流取址回调。为空表示这条流不需要（或不支持）续流。
  final LivePlayUrlRenewer? renewUrl;

  LivePlayUrl({
    required this.urls,
    this.headers,
    this.renewUrl,
  });

  /// 是否支持续流取址。
  bool get canRenew => renewUrl != null;

  @override
  String toString() {
    return json.encode({
      "urls": urls,
      "headers": headers.toString(),
      "canRenew": canRenew,
    });
  }
}
