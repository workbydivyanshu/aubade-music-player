import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aubade/ui/settings/settings_search.dart';
import 'package:aubade/core/storage/prefs.dart';
import 'package:aubade/core/storage/app_database.dart';
import 'package:aubade/features/search/shared_providers.dart'
    show databaseProvider;
import 'package:aubade/ui/settings/settings_page.dart';

/// Settings search contracts: the catalog stays consistent with the
/// searchable groups, queries filter deterministically, and the jump
/// scope hands exactly one scroll target to the matching group.
class _Peek extends StatelessWidget {
  const _Peek();

  @override
  Widget build(BuildContext context) {
    final scope = SettingsJumpScope.maybeOf(context);
    if (scope?.jumpId != null) {
      // Mirror _Group: consumption is deferred out of build.
      final element = context as Element;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (element.mounted) scope?.onJumpConsumed();
      });
    }
    return Text('jump=${scope?.jumpId} highlight=${scope?.highlightId}');
  }
}

void main() {
  group('catalog integrity', () {
    test('group ids are unique and sections are canon', () {
      final ids = kSettingsSearchCatalog.map((e) => e.groupId).toList();
      expect(ids.toSet(), ids, reason: 'ids must be unique');
      for (final e in kSettingsSearchCatalog) {
        expect(e.sectionLabel, isNot(e.section),
            reason: 'every section should have a rail label');
      }
    });

    test('expected groups are all present', () {
      final titles = kSettingsSearchCatalog.map((e) => e.groupTitle).toList();
      for (final must in [
        'Music folders',
        'Library indexing',
        'Audio output',
        'Loudness & Dynamics',
        'Resampling & DAC',
        'Playback',
        'Theme',
        'Haze material',
        'Surfaces',
        'Timing',
        'Last.fm connection',
        'API keys',
        'Last.fm scrobbling',
        'Behaviour',
        'Open with',
        'Offline',
        'Addon sources',
        'Experimental',
        'System & Audio Telemetry',
      ]) {
        expect(titles, contains(must));
      }
      expect(titles, hasLength(19));
    });
  });

  group('searchSettingsGroups', () {
    test('empty or whitespace queries stay idle', () {
      expect(searchSettingsGroups(''), isEmpty);
      expect(searchSettingsGroups('   '), isEmpty);
    });

    test('title, section label and keywords all match', () {
      expect(
        searchSettingsGroups('replaygain').map((e) => e.groupId),
        containsAll(['loudness']),
      );
      // keyword 'translucency' only exists on Haze + Experimental.
      final haze = searchSettingsGroups('translucency');
      expect(haze.map((e) => e.groupId), contains('haze'));

      // Section label: 'Downloads' is the rail label of the Offline card.
      expect(
        searchSettingsGroups('downloads').map((e) => e.groupId),
        contains('offline'),
      );
    });

    test('multi-token queries require every token', () {
      expect(
        searchSettingsGroups('word offset').map((e) => e.groupId),
        contains('lyrics-timing'),
      );
      expect(searchSettingsGroups('word offset replaygain'), isEmpty);
    });

    test('unknown query yields no results, no throw', () {
      expect(searchSettingsGroups('zzz-unknown'), isEmpty);
    });
  });

  testWidgets('jump scope notifies dependents and one-shot consumption',
      (tester) async {
    var consumedCalls = 0;
    late StateSetter setScope;
    String? jump;
    String? highlight;

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: StatefulBuilder(
          builder: (context, setState) {
            setScope = setState;
            return SettingsJumpScope(
              jumpId: jump,
              highlightId: highlight,
              onJumpConsumed: () => setScope(() {
                consumedCalls++;
                jump = null;
              }),
              child: const _Peek(),
            );
          },
        ),
      ),
    );
    expect(find.text('jump=null highlight=null'), findsOneWidget);

    setScope(() {
      jump = 'theme';
      highlight = 'theme';
    });
    // The dependent rebuilt inside onJumpConsumed already reports the
    // new values, then consuming nulls the one-shot jump id only.
    await tester.pump();
    expect(consumedCalls, 1);
    await tester.pump();
    expect(
      find.text('jump=null highlight=theme'),
      findsOneWidget,
      reason: 'highlight survives consumption; jump does not',
    );
  });

  testWidgets('rail search jumps to the group and keeps the query',
      (tester) async {
    // ..., one hose of providers for the initial Library pane.
    SharedPreferences.setMockInitialValues({});
    final prefs = Prefs(await SharedPreferences.getInstance());
    final db = AppDatabase.inMemory();
    addTearDown(db.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefsProvider.overrideWithValue(prefs),
          databaseProvider.overrideWithValue(db),
        ],
        child: const FluentApp(home: WaveSettingsPage()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // The jump target: paylaş translucency toggle only lives on the
    // Experimental pane behind its switch row behaviour.
    await tester.enterText(find.byType(TextBox), 'translucency');
    await tester.pump();
    expect(find.text('No matching settings'), findsNothing);

    await tester.tap(find.text('Experimental').last);
    // Section switch + the one-shot scroll animation (~260ms).
    await tester.pump(const Duration(milliseconds: 400));
    // The 2.2s flash window: pump past it so no timer leaks.
    await tester.pump(const Duration(milliseconds: 2400));
    await tester.pump(const Duration(milliseconds: 200));

    // The Experimental group subtree renders (subtitle is unique).
    expect(find.text('Opt-in desktop prototypes'), findsOneWidget);

    // The standing query survives the jump (contract).
    expect(
      find.descendant(
        of: find.byType(TextBox),
        matching: find.text('translucency'),
      ),
      findsOneWidget,
    );
  });
}
