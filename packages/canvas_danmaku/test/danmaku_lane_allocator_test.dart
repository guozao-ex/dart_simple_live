import 'package:canvas_danmaku/danmaku_lane_allocator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  DanmakuLaneAllocator allocator({
    double speed = 0.1,
    double laneHeight = 20,
    double areaHeight = 100,
    double width = 300,
  }) {
    return DanmakuLaneAllocator(
      DanmakuLaneLayout(
        laneHeight: laneHeight,
        areaHeight: areaHeight,
        width: width,
        speed: speed,
      ),
    );
  }

  test('车道尾部清出右边缘后立即可复用', () {
    final lanes = allocator();
    expect(lanes.laneCount, 5);

    final first = lanes.allocate(1000, 50);
    expect(first, isNotNull);
    expect(first!.lane, 0);
    expect(first.top, 0);
    // 50px / 0.1px/ms = 500ms 后尾部清出。
    expect(lanes.freeLanes(1499), 4);
    expect(lanes.allocate(1499, 10)!.lane, 1);
    expect(lanes.allocate(1500, 10)!.lane, 0);
  });

  test('没有空车道时返回 null', () {
    final lanes = allocator(areaHeight: 60);
    expect(lanes.laneCount, 3);
    expect(lanes.allocate(0, 10), isNotNull);
    expect(lanes.allocate(0, 10), isNotNull);
    expect(lanes.allocate(0, 10), isNotNull);
    expect(lanes.allocate(0, 10), isNull);
    expect(lanes.freeLanes(0), 0);
  });

  test('等速下不同宽度的清除时间只取决于自身宽度', () {
    final lanes = allocator(speed: 0.2);
    lanes.allocate(0, 40); // lane 0, clear at 200
    lanes.allocate(0, 80); // lane 1, clear at 400
    expect(lanes.freeLanes(199), 3);
    expect(lanes.freeLanes(200), 4);
    expect(lanes.freeLanes(399), 4);
    expect(lanes.freeLanes(400), 5);
  });

  test('变速按比例缩放剩余等待', () {
    final lanes = allocator();
    lanes.allocate(1000, 100); // clear at 2000
    lanes.rescale(1000, 2);
    expect(lanes.freeLanes(2999), 4);
    expect(lanes.freeLanes(3000), 5);
  });

  test('变窄延迟所有忙碌车道，变宽不延迟', () {
    final lanes = allocator();
    lanes.allocate(0, 100); // clear at 1000
    lanes.setLayout(
      const DanmakuLaneLayout(
        laneHeight: 20,
        areaHeight: 100,
        width: 260,
        speed: 0.1,
      ),
      0,
    );
    // 丢失 40px，按 0.1px/ms 延迟 400ms。
    expect(lanes.freeLanes(1399), 4);
    expect(lanes.freeLanes(1400), 5);

    lanes.allocate(1400, 10);
    lanes.setLayout(
      const DanmakuLaneLayout(
        laneHeight: 20,
        areaHeight: 100,
        width: 400,
        speed: 0.1,
      ),
      1400,
    );
    expect(lanes.freeLanes(1499), 4);
    expect(lanes.freeLanes(1500), 5);
  });

  test('extend 与 ensureFreeAt 只向后延长', () {
    final lanes = allocator();
    lanes.allocate(0, 10); // clear at 100
    lanes.extend(0, 100);
    expect(lanes.freeLanes(150), 4);
    expect(lanes.freeLanes(200), 5);
    lanes.ensureFreeAt(1, 500);
    expect(lanes.freeLanes(400), 4);
    expect(lanes.freeLanes(500), 5);
    lanes.ensureFreeAt(1, 100);
    expect(lanes.freeLanes(500), 5);
  });

  test('车道数跟随区域高度变化并保留已有占用', () {
    final lanes = allocator();
    lanes.allocate(0, 100); // lane 0 clear at 1000
    lanes.setLayout(
      const DanmakuLaneLayout(
        laneHeight: 20,
        areaHeight: 40,
        width: 300,
        speed: 0.1,
      ),
      0,
    );
    expect(lanes.laneCount, 2);
    expect(lanes.freeLanes(999), 1);
    expect(lanes.freeLanes(1000), 2);
  });
}
