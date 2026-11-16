import 'dart:ui' as ui;

import 'package:canvas_danmaku/danmaku_image_cache.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ui.Image makeImage() {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 1, 1),
    Paint()..color = const Color(0xFFFFFFFF),
  );
  return recorder.endRecording().toImageSync(4, 4);
}

DanmakuImageEntry entry(String key, ui.Image image) {
  return DanmakuImageEntry(
    key: key,
    image: image,
    width: 10,
    height: 10,
  );
}

void main() {
  test('命中复用并增加引用，release 后仍留在缓存', () {
    final cache = DanmakuImageCache();
    final image = makeImage();
    addTearDown(cache.clear);

    final first = cache.acquire(
      'a',
      () => entry('a', image),
      tick: 1,
    );
    expect(first.refs, 1);
    expect(cache.misses, 1);
    expect(cache.hits, 0);

    cache.release(first);
    expect(first.refs, 0);
    expect(cache.length, 1);

    final second = cache.acquire(
      'a',
      () => entry('a', makeImage()),
      tick: 2,
    );
    expect(identical(first, second), isTrue);
    expect(second.refs, 1);
    expect(cache.hits, 1);
    expect(cache.misses, 1);
  });

  test('引用中的条目不会被淘汰', () {
    final cache = DanmakuImageCache(maxEntries: 1);
    addTearDown(cache.clear);

    final held =
        cache.acquire('held', () => entry('held', makeImage()), tick: 1);
    cache.acquire('other', () => entry('other', makeImage()), tick: 2);
    // held 仍被引用，不能淘汰；other 保留在缓存里。
    expect(cache.length, 2);

    cache.release(held);
    cache.acquire('third', () => entry('third', makeImage()), tick: 3);
    expect(cache.length, 2);
  });

  test('clear 释放全部位图并复位计数', () {
    final cache = DanmakuImageCache();
    cache.acquire('a', () => entry('a', makeImage()), tick: 1);
    cache.acquire('b', () => entry('b', makeImage()), tick: 2);
    cache.clear();
    expect(cache.length, 0);
    expect(cache.bytes, 0);
  });
}
