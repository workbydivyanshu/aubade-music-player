import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aubade/ui/components/buttons.dart';

/// Fluent's own push buttons pass `cursor ?? MouseCursor.defer` to their
/// inner `MouseRegion`, so a raw `Button` / `FilledButton` / `HyperlinkButton`
/// paints the plain arrow. The Wave wrappers own the rule instead: an enabled
/// control paints the pointer, a disabled one keeps the arrow (there is
/// nothing to click).
void main() {
  Future<void> pump(WidgetTester tester, {required bool enabled}) async {
    await tester.pumpWidget(
      FluentApp(
        themeMode: ThemeMode.dark,
        home: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              WaveButton(
                onPressed: enabled ? () {} : null,
                child: const Text('go'),
              ),
              WaveFilledButton(
                onPressed: enabled ? () {} : null,
                child: const Text('fill'),
              ),
              WaveLink(
                onPressed: enabled ? () {} : null,
                child: const Text('link'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// The wrapper's own `MouseRegion` — the outermost one in the wrapper's
  /// subtree (preorder), before Fluent's defer region inside the button.
  MouseRegion wrapperRegion(WidgetTester tester, Type type) {
    return tester.widget<MouseRegion>(
      find
          .descendant(
            of: find.byType(type),
            matching: find.byType(MouseRegion),
          )
          .first,
    );
  }

  Future<void> hover(WidgetTester tester, Finder target) async {
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      pointer: 1,
    );
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(target));
    await tester.pump();
  }

  testWidgets('enabled push buttons paint the pointer', (tester) async {
    await pump(tester, enabled: true);
    expect(
        wrapperRegion(tester, WaveButton).cursor, SystemMouseCursors.click);
    expect(wrapperRegion(tester, WaveFilledButton).cursor,
        SystemMouseCursors.click);
    expect(wrapperRegion(tester, WaveLink).cursor, SystemMouseCursors.click);

    // The painted cursor, not just the widget property: hover a WaveButton
    // and the tracker resolves to the pointer (device 1 is the test mouse).
    await hover(tester, find.text('go'));
    expect(
      RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.click,
    );
  });

  testWidgets('disabled push buttons keep the basic arrow', (tester) async {
    await pump(tester, enabled: false);
    expect(wrapperRegion(tester, WaveButton).cursor,
        isNot(SystemMouseCursors.click));
    expect(wrapperRegion(tester, WaveFilledButton).cursor,
        isNot(SystemMouseCursors.click));
    expect(wrapperRegion(tester, WaveLink).cursor,
        isNot(SystemMouseCursors.click));

    await hover(tester, find.text('go'));
    expect(
      RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
      isNot(SystemMouseCursors.click),
    );
  });
}
