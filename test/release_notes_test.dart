import 'package:aubade/features/updater/release_notes.dart';
import 'package:aubade/features/updater/update_models.dart';
import 'package:aubade/features/updater/update_service.dart';
import 'package:aubade/ui/components/update_dialog.dart';
import 'package:fluent_ui/fluent_ui.dart' as f;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

String _plain(List<TextSpan> spans) => spans.map((s) => s.text ?? '').join();

AppReleaseInfo _release(String notes) => AppReleaseInfo(
  tagName: 'v1.0.3',
  version: '1.0.3',
  title: 'Aubade v1.0.3',
  notes: notes,
  publishedAt: DateTime(2026, 10, 20),
  htmlUrl: 'https://github.com/workbydivyanshu/aubade-music-player/releases/tag/v1.0.3',
  assetName: 'aubade_1.0.3_x86_64.AppImage',
  assetDownloadUrl: 'https://example.test/aubade_1.0.3_x86_64.AppImage',
  assetSizeBytes: 65 * 1024 * 1024,
);

class _FixedUpdateService extends UpdateService {
  _FixedUpdateService(UpdateState initial) {
    state = initial;
  }
}

Future<void> _openDialog(
  WidgetTester tester,
  AppReleaseInfo release, {
  UpdateStatus status = UpdateStatus.available,
  String? downloadedFilePath,
  String? errorMessage,
  bool settle = true,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        updateServiceProvider.overrideWith(
          (ref) => _FixedUpdateService(
            UpdateState(
              status: status,
              release: release,
              downloadedFilePath: downloadedFilePath,
              errorMessage: errorMessage,
            ),
          ),
        ),
      ],
      child: f.FluentApp(
        home: Consumer(
          builder: (context, ref, _) => f.Button(
            onPressed: () => showUpdateDialog(context, ref),
            child: const f.Text('Open update'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open update'));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    // An indeterminate ProgressRing never settles while installing.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }
}

String _renderedText(WidgetTester tester) => tester
    .widgetList<RichText>(find.byType(RichText))
    .map((widget) => widget.text.toPlainText())
    .join('\n');

void main() {
  group('formatReleaseNotes', () {
    test('heading loses its hashes and gains heading weight', () {
      final spans = formatReleaseNotes(
        '## Fixed in 1.0.3\n---\n### Details\nBody',
      );
      final plain = _plain(spans);

      expect(plain, isNot(contains('#')));
      expect(plain, isNot(contains('---')));
      expect(plain, contains('Fixed in 1.0.3'));
      expect(plain, contains('Details'));

      final heading = spans.firstWhere((s) => s.text == 'Fixed in 1.0.3');
      expect(heading.style!.fontWeight, FontWeight.w700);
      expect(heading.style!.fontSize, greaterThan(13));
    });

    test('bold markers are removed but emphasis survives', () {
      final spans = formatReleaseNotes('This **matters** a lot **');
      final plain = _plain(spans);

      expect(plain, equals('This matters a lot'));
      expect(plain, isNot(contains('**')));

      final emphasis = spans.firstWhere((s) => s.text == 'matters');
      expect(emphasis.style!.fontWeight, FontWeight.w700);
    });

    test('bullet markers become bullet rows', () {
      final plain = _plain(formatReleaseNotes('- First\n* Second\n+ Third'));

      expect(plain, equals('•  First\n•  Second\n•  Third'));
      expect(plain, isNot(contains('- ')));
      expect(plain, isNot(contains('* ')));
    });

    test('markdown links keep only their label', () {
      final plain = _plain(
        formatReleaseNotes(
          'See [the changelog](https://github.com/workbydivyanshu/aubade-music-player/releases) for details.',
        ),
      );

      expect(plain, equals('See the changelog for details.'));
      expect(plain, isNot(contains('http')));
      expect(plain, isNot(contains('github.com')));
    });

    test('parenthetical bare URLs lose their scheme and URL text', () {
      final plain = _plain(
        formatReleaseNotes('Notes (https://aubadehq.vercel.app) here'),
      );

      expect(plain, equals('Notes here'));
      expect(plain, isNot(contains('https://')));
    });

    test('github.com never survives anywhere in the body', () {
      final plain = _plain(
        formatReleaseNotes(
          '## Notes\n'
          '- Repo: https://github.com/workbydivyanshu/aubade-music-player\n'
          '- Mirror: github.com/workbydivyanshu/aubade-music-player\n'
          '- See [the release](https://github.com/workbydivyanshu/aubade-music-player/releases)\n',
        ),
      );

      expect(plain.toLowerCase(), isNot(contains('github.com')));
      expect(plain, isNot(contains('https://')));
      expect(plain, contains('See the release'));
    });

    test('collapses excessive blank lines', () {
      expect(_plain(formatReleaseNotes('One\n\n\n\nTwo')), 'One\n\nTwo');
      expect(_plain(formatReleaseNotes('One\n\n\n')), 'One');
    });

    test('empty or decoration-only bodies produce no spans', () {
      expect(formatReleaseNotes(''), isEmpty);
      expect(formatReleaseNotes('  \n\t\n'), isEmpty);
      expect(formatReleaseNotes('---\n###'), isEmpty);
    });
  });

  group('Linux install command builders', () {
    test('rpm replaces packages through pkexec', () {
      final command = linuxInstallCommand('/tmp/aubade-1.0.3.x86_64.rpm');

      expect(command, isNotNull);
      expect(command!.executable, 'pkexec');
      expect(command.arguments, [
        'rpm',
        '-Uvh',
        '--replacepkgs',
        '/tmp/aubade-1.0.3.x86_64.rpm',
      ]);
    });

    test('deb installs through pkexec', () {
      final command = linuxInstallCommand('/tmp/aubade_1.0.3_amd64.deb');

      expect(command, isNotNull);
      expect(command!.executable, 'pkexec');
      expect(command.arguments, ['dpkg', '-i', '/tmp/aubade_1.0.3_amd64.deb']);
    });

    test('AppImage never asks for pkexec', () {
      expect(linuxInstallCommand('/tmp/aubade_1.0.3.AppImage'), isNull);
      expect(linuxInstallCommand(''), isNull);
    });
  });

  group('install outcome state mapping', () {
    test('exit code maps to an install outcome', () {
      expect(installOutcomeForExitCode(0), InstallOutcome.installed);
      expect(installOutcomeForExitCode(126), InstallOutcome.cancelled);
      expect(installOutcomeForExitCode(127), InstallOutcome.cancelled);
      expect(installOutcomeForExitCode(1), InstallOutcome.failed);
    });

    test('success transitions to readyToRelaunch', () {
      const installing = UpdateState(
        status: UpdateStatus.installing,
        downloadedFilePath: '/tmp/aubade.rpm',
      );

      final installed = installing.finishInstall(InstallOutcome.installed);

      expect(installed.status, UpdateStatus.readyToRelaunch);
      expect(installed.errorMessage, isNull);
      expect(installed.downloadedFilePath, '/tmp/aubade.rpm');
    });

    test('cancelled and failed transitions report the reason', () {
      const installing = UpdateState(status: UpdateStatus.installing);

      final cancelled = installing.finishInstall(InstallOutcome.cancelled);
      expect(cancelled.status, UpdateStatus.error);
      expect(
        cancelled.errorMessage,
        "Update couldn't be installed — cancelled",
      );

      final failed = installing.finishInstall(
        InstallOutcome.failed,
        detail: 'package is corrupt',
      );
      expect(failed.status, UpdateStatus.error);
      expect(failed.errorMessage, contains('package is corrupt'));
    });
  });

  group('relaunch command builder', () {
    test('uses resolvedExecutable for an installed app', () {
      final command = buildRelaunchCommand(
        resolvedExecutable: '/usr/bin/aubade',
      );

      expect(command, isNotNull);
      expect(command!.executable, '/usr/bin/aubade');
      expect(command.arguments, isEmpty);
    });

    test('prefers the downloaded AppImage', () {
      final command = buildRelaunchCommand(
        resolvedExecutable: '/usr/bin/aubade',
        preferredExecutable: '/tmp/aubade_1.0.3.AppImage',
      );

      expect(command!.executable, '/tmp/aubade_1.0.3.AppImage');
    });

    test(
      'falls back to resolvedExecutable when the preferred path is empty',
      () {
        final command = buildRelaunchCommand(
          resolvedExecutable: '/usr/bin/aubade',
          preferredExecutable: '   ',
        );

        expect(command!.executable, '/usr/bin/aubade');
      },
    );

    test('returns null when the path is not an installed app', () {
      expect(
        buildRelaunchCommand(resolvedExecutable: '/tmp/flutter_tester'),
        isNull,
      );
      expect(buildRelaunchCommand(resolvedExecutable: ''), isNull);
      expect(
        buildRelaunchCommand(
          resolvedExecutable: '/usr/bin/aubade',
          preferredExecutable: '/tmp/dart',
        )!.executable,
        '/usr/bin/aubade',
      );
    });
  });

  group('update dialog release notes', () {
    testWidgets('renders markdown-y notes without leaking markup', (
      tester,
    ) async {
      await _openDialog(
        tester,
        _release(
          "## What's New in 1.0.3\n"
          '- Fixed the **raw markdown** leak in update notes\n'
          '- Links now show [labels](https://github.com/workbydivyanshu/aubade-music-player) only\n'
          'Download notes from (https://aubadehq.vercel.app)\n',
        ),
      );

      final rendered = _renderedText(tester);
      expect(rendered, contains("What's New in 1.0.3"));
      expect(
        rendered,
        contains('•  Fixed the raw markdown leak in update notes'),
      );
      expect(rendered, contains('Links now show labels only'));
      expect(rendered, isNot(contains('##')));
      expect(rendered, isNot(contains('**')));
      expect(rendered, isNot(contains('https://')));
      expect(rendered, isNot(contains('github.com')));
    });

    testWidgets('hides the What\'s New section for blank notes', (
      tester,
    ) async {
      await _openDialog(tester, _release('   \n\n'));

      expect(find.text("What's New:"), findsNothing);
    });

    testWidgets('installing state asks for permission', (tester) async {
      await _openDialog(
        tester,
        _release(''),
        status: UpdateStatus.installing,
        downloadedFilePath: '/tmp/aubade.rpm',
        settle: false,
      );

      expect(find.text('Requesting permission…'), findsOneWidget);
    });

    testWidgets('readyToRelaunch offers restart now and later', (tester) async {
      await _openDialog(
        tester,
        _release(''),
        status: UpdateStatus.readyToRelaunch,
        downloadedFilePath: '/tmp/aubade.rpm',
      );

      expect(find.text('Restart now'), findsOneWidget);
      expect(find.text('Restart later'), findsOneWidget);
      expect(find.textContaining('is installed'), findsOneWidget);
    });

    testWidgets('install failure shows reason and open-folder fallback', (
      tester,
    ) async {
      await _openDialog(
        tester,
        _release(''),
        status: UpdateStatus.error,
        downloadedFilePath: '/tmp/aubade.rpm',
        errorMessage: "Update couldn't be installed — cancelled",
      );

      expect(
        find.text("Update couldn't be installed — cancelled"),
        findsOneWidget,
      );
      expect(find.text('Open folder'), findsOneWidget);
    });
  });
}
