// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/features/workspace/services/crux_project_resolution.dart';
import 'package:simcrux/features/workspace/widgets/open_config_tab.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// The feedback half of opening a design manifest: what the user reads when
/// a manifest cannot be opened. The success and legacy-name paths, which
/// open a tab, are driven end to end through the command line in
/// `test/features/dashboard/widgets/cli_regression_bootstrapper_test.dart`.
void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('sc_open_config'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// A design directory holding two manifests, which opens neither.
  String ambiguousDesign() {
    final dir = Directory(p.join(tmp.path, 'uart'))..createSync();
    for (final name in ['uart.crux-project', 'uart_old.crux-project']) {
      File(p.join(dir.path, name)).writeAsStringSync('version: 1\n');
    }
    return dir.path;
  }

  Future<String?> openThroughButton(
    WidgetTester tester,
    String rawPath, {
    Locale locale = const Locale('en'),
  }) async {
    String? opened = 'not called';
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          locale: locale,
          localizationsDelegates: const [
            L10N.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: L10N.supportedLocales,
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () async {
                  opened = await openConfigAsTab(
                    ref: ref,
                    context: context,
                    rawPath: rawPath,
                    source: 'yaml',
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 750));
    return opened;
  }

  /// Lets the snack bar's display timer run out so no timer outlives the
  /// test.
  Future<void> dismissSnack(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  }

  group('cruxProjectRefusalMessage', () {
    test('every refusal names what the user has to act on', () async {
      final l10n = await L10N.delegate.load(const Locale('en'));
      expect(
        cruxProjectRefusalMessage(
          l10n,
          const ManifestInvalid(
            manifestPath: '/d/uart.crux-project',
            detail: 'missing version',
          ),
        ),
        contains('missing version'),
      );
      expect(
        cruxProjectRefusalMessage(
          l10n,
          const ManifestConfigMissing('sim/gone.yaml'),
        ),
        contains('sim/gone.yaml'),
      );
      final noSim = cruxProjectRefusalMessage(
        l10n,
        const ManifestNoSimulation('uart'),
      );
      expect(noSim, contains('uart'));
      expect(noSim, contains('simulation:'));
      final ambiguous = cruxProjectRefusalMessage(
        l10n,
        const ManifestAmbiguous(
          directory: '/d/uart',
          candidates: ['/d/uart/a.crux-project', '/d/uart/b.crux-project'],
        ),
      );
      expect(ambiguous, contains('/d/uart'));
      // File names, not full paths: the directory is already named once.
      expect(ambiguous, contains('a.crux-project, b.crux-project'));
      expect(ambiguous, isNot(contains('/d/uart/a.crux-project')));
    });

    test('the legacy-name notice names the file to rename to', () async {
      for (final locale in L10N.supportedLocales) {
        final l10n = await L10N.delegate.load(locale);
        expect(
          l10n.cruxProjectLegacyFileName('uart.crux-project'),
          contains('uart.crux-project'),
          reason: '$locale',
        );
      }
    });
  });

  group('openConfigAsTab refusals', () {
    testWidgets('an ambiguous design directory opens nothing and says why', (
      tester,
    ) async {
      final dir = ambiguousDesign();
      final opened = await openThroughButton(tester, dir);
      expect(opened, isNull);
      final l10n = await L10N.delegate.load(const Locale('en'));
      expect(
        find.text(
          l10n.cruxProjectAmbiguous(
            dir,
            'uart.crux-project, uart_old.crux-project',
          ),
        ),
        findsOneWidget,
      );
      await dismissSnack(tester);
    });

    testWidgets('an invalid manifest opens nothing and says why', (
      tester,
    ) async {
      final manifest = File(p.join(tmp.path, 'broken.crux-project'))
        ..writeAsStringSync('name: no version\n');
      final opened = await openThroughButton(tester, manifest.path);
      expect(opened, isNull);
      expect(find.textContaining('version'), findsOneWidget);
      await dismissSnack(tester);
    });

    testWidgets('locale sweep: the refusal renders in every locale', (
      tester,
    ) async {
      final dir = ambiguousDesign();
      for (final locale in L10N.supportedLocales) {
        final opened = await openThroughButton(tester, dir, locale: locale);
        expect(opened, isNull, reason: '$locale');
        expect(tester.takeException(), isNull, reason: '$locale');
        expect(find.byType(SnackBar), findsOneWidget, reason: '$locale');
        await dismissSnack(tester);
      }
    });
  });
}
