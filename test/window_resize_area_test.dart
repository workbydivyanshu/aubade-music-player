import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aubade/ui/app_shell/wave_resize_area.dart';

/// Frameless Linux windows lose the compositor's resize grips. These
/// tests pin the two properties that matter: the grips exist with the
/// right hit zones, and they disappear while maximized so they never
/// steal clicks from the title bar.
void main() {
  Future<void> pumpArea(
    WidgetTester tester, {
    required bool enabled,
  }) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 800,
          height: 600,
          child: WaveWindowResizeArea(
            enabled: enabled,
            edgeSize: 4,
            cornerSize: 14,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }

  bool hitHasMouseRegion(WidgetTester tester, Offset point) {
    final result = tester.hitTestOnBinding(point);
    return result.path.any((entry) => entry.target is RenderMouseRegion);
  }

  testWidgets('corner and edge grips are hit-testable when enabled',
      (tester) async {
    await pumpArea(tester, enabled: true);

    // Four 14px corners and four 4px edges.
    expect(find.byType(MouseRegion), findsNWidgets(8));

    expect(hitHasMouseRegion(tester, const Offset(5, 5)), isTrue,
        reason: 'top-left corner');
    expect(hitHasMouseRegion(tester, const Offset(795, 5)), isTrue,
        reason: 'top-right corner');
    expect(hitHasMouseRegion(tester, const Offset(5, 595)), isTrue,
        reason: 'bottom-left corner');
    expect(hitHasMouseRegion(tester, const Offset(795, 595)), isTrue,
        reason: 'bottom-right corner');

    expect(hitHasMouseRegion(tester, const Offset(400, 1)), isTrue,
        reason: 'top edge');
    expect(hitHasMouseRegion(tester, const Offset(400, 599)), isTrue,
        reason: 'bottom edge');
    expect(hitHasMouseRegion(tester, const Offset(1, 300)), isTrue,
        reason: 'left edge');
    expect(hitHasMouseRegion(tester, const Offset(799, 300)), isTrue,
        reason: 'right edge');
  });

  testWidgets('no grips render while maximized (enabled: false)',
      (tester) async {
    await pumpArea(tester, enabled: false);

    expect(find.byType(Positioned), findsNothing);
    expect(find.byType(MouseRegion), findsNothing);
    // The child still fills the window.
    expect(hitHasMouseRegion(tester, const Offset(5, 5)), isFalse);
  });

  testWidgets('grips use resize cursors, not the default arrow',
      (tester) async {
    await pumpArea(tester, enabled: true);

    final regions = tester
        .widgetList<MouseRegion>(find.byType(MouseRegion))
        .map((r) => r.cursor)
        .toList();
    expect(regions, contains(SystemMouseCursors.resizeUpLeft));
    expect(regions, contains(SystemMouseCursors.resizeUpRight));
    expect(regions, contains(SystemMouseCursors.resizeDownLeft));
    expect(regions, contains(SystemMouseCursors.resizeDownRight));
    expect(regions, contains(SystemMouseCursors.resizeUp));
    expect(regions, contains(SystemMouseCursors.resizeDown));
    expect(regions, contains(SystemMouseCursors.resizeLeft));
    expect(regions, contains(SystemMouseCursors.resizeRight));
    expect(regions, isNot(contains(SystemMouseCursors.basic)));
  });
}
