import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/shield_pattern_cache.dart';

void main() {
  test('列表未变化时复用编译结果', () {
    final cache = ShieldPatternCache();
    final first = cache.resolve(['bad', 'word']);
    expect(first, hasLength(2));
    expect(cache.rebuilds, 1);

    final second = cache.resolve(['bad', 'word']);
    expect(identical(first, second), isTrue);
    expect(cache.rebuilds, 1);

    final third = cache.resolve(['bad', 'word', 'new']);
    expect(third, hasLength(3));
    expect(cache.rebuilds, 2);
  });

  test('正则格式关键词编译为 RegExp，非法正则跳过', () {
    final cache = ShieldPatternCache();
    final patterns = cache.resolve(['/a+b/', '/[invalid/']);
    expect(patterns, hasLength(1));
    expect(patterns.single, isA<RegExp>());
    expect('aaab'.contains(patterns.single), isTrue);
  });
}
