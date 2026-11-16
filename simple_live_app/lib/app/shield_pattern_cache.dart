import 'package:flutter/foundation.dart';
import 'package:simple_live_app/app/utils.dart';

/// 屏蔽关键词的编译缓存。
///
/// 列表内容不变时复用已编译的 [Pattern]，避免每条消息都新建 [RegExp]。
class ShieldPatternCache {
  List<String> _keywords = const [];
  List<Pattern> _patterns = const [];

  /// 重新编译次数，供调试与测试读取。
  int rebuilds = 0;

  List<Pattern> resolve(Iterable<String> keywords) {
    final next = keywords.toList(growable: false);
    if (!listEquals(next, _keywords)) {
      _keywords = next;
      _patterns = compile(next);
      rebuilds += 1;
    }
    return _patterns;
  }

  static List<Pattern> compile(List<String> keywords) {
    final patterns = <Pattern>[];
    for (final keyword in keywords) {
      if (Utils.isRegexFormat(keyword)) {
        final removedSlash = Utils.removeRegexFormat(keyword);
        try {
          patterns.add(RegExp(removedSlash));
        } catch (_) {
          // 非法正则由设置页负责提示，这里跳过该条。
        }
      } else {
        patterns.add(keyword);
      }
    }
    return patterns;
  }
}
