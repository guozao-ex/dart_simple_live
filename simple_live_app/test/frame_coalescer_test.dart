import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/frame_coalescer.dart';

void main() {
  testWidgets('同一帧内多次请求只执行一次', (tester) async {
    await tester.pumpWidget(const SizedBox());
    final coalescer = FrameCoalescer();
    var calls = 0;

    for (var i = 0; i < 10; i++) {
      coalescer.schedule(() => calls += 1);
    }

    expect(calls, 0);
    expect(coalescer.runs, 0);

    await tester.pump();

    expect(calls, 1);
    expect(coalescer.runs, 1);

    coalescer.schedule(() => calls += 1);
    await tester.pump();

    expect(calls, 2);
    expect(coalescer.runs, 2);
  });
}
