import 'package:flutter_test/flutter_test.dart';

import 'package:aubade/ui/player_dock/player_dock.dart';

// The dock's timeline helpers (pure functions behind _DockProgress): what
// the right-hand clock prints and where an arrow-key step may land.
// mpv reports no duration until the source is open, so a restored session
// or a freshly resolved stream sits at Duration.zero for a beat; the dock
// must not read that absence as a zero-length track.

void main() {
  group('dock clock while the track length is unknown', () {
    test('zero and negative totals render --:--', () {
      expect(dockClockLabel(Duration.zero), '--:--');
      expect(dockClockLabel(const Duration(milliseconds: -1)), '--:--');
    });

    test('a real total renders m:ss exactly as before', () {
      expect(dockClockLabel(const Duration(minutes: 3, seconds: 5)), '3:05');
      expect(dockClockLabel(const Duration(seconds: 65)), '1:05');
      expect(dockClockLabel(const Duration(milliseconds: 59999)), '0:59');
    });
  });

  group('dock arrow-key seek target', () {
    test('no total: no seek target, so _seekBy bails', () {
      expect(dockSeekTarget(Duration.zero, Duration.zero, 5), isNull);
      expect(
        dockSeekTarget(const Duration(minutes: 1), Duration.zero, -5),
        isNull,
      );
    });

    test('a real total: clamps into [zero, total] exactly as before', () {
      const total = Duration(minutes: 3, seconds: 5);
      const base = Duration(minutes: 1);
      expect(
        dockSeekTarget(base, total, 5),
        const Duration(minutes: 1, seconds: 5),
      );
      expect(dockSeekTarget(base, total, -5), const Duration(seconds: 55));
      expect(dockSeekTarget(base, total, -120), Duration.zero);
      expect(dockSeekTarget(base, total, 600), total);
    });
  });
}
