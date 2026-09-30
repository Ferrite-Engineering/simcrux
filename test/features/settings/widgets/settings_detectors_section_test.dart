// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/domain/models/pass_fail_config_codec.dart';
import 'package:simcrux/features/settings/widgets/detector_editor_dialog.dart';
import 'package:simcrux/features/settings/widgets/settings_detectors_section.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

Widget _harness({
  required AppSettings settings,
  Locale? locale,
}) {
  return ProviderScope(
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
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: SettingsDetectorsSection(settings: settings),
        ),
      ),
    ),
  );
}

void main() {
  group('SettingsDetectorsSection', () {
    testWidgets('renders empty-state body when no detectors are defined', (
      tester,
    ) async {
      await tester.pumpWidget(_harness(settings: const AppSettings()));
      await tester.pumpAndSettle();
      expect(find.textContaining('No reusable detectors'), findsOneWidget);
    });

    testWidgets('lists existing detectors with kind summary', (tester) async {
      const settings = AppSettings(
        reusableDetectors: <String, DetectorSpec>{
          'strict-uvm': UvmReportSpec(fatalThreshold: 0),
          'spi-pass': StringMatchSpec(passString: 'PASS'),
        },
      );
      await tester.pumpWidget(_harness(settings: settings));
      await tester.pumpAndSettle();
      expect(find.text('strict-uvm'), findsOneWidget);
      expect(find.text('spi-pass'), findsOneWidget);
      expect(find.textContaining('UVM'), findsOneWidget);
    });

    for (final locale in const [
      Locale('en'),
      Locale('zh', 'CN'),
      Locale('ja'),
      Locale('ko'),
    ]) {
      testWidgets('locale sweep — ${locale.toLanguageTag()}', (tester) async {
        const settings = AppSettings(
          reusableDetectors: <String, DetectorSpec>{
            'sample': ExitCodeSpec(),
          },
        );
        await tester.pumpWidget(_harness(settings: settings, locale: locale));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('DetectorEditorDialog', () {
    testWidgets('saves a new exit-code detector', (tester) async {
      String? capturedName;
      DetectorSpec? capturedSpec;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [
            L10N.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: L10N.supportedLocales,
          home: Material(
            child: DetectorEditorDialog(
              existingNames: const <String>{},
              onCommit: (name, spec) async {
                capturedName = name;
                capturedSpec = spec;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'simple');
      // Default kind is exit_code.
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(capturedName, 'simple');
      expect(capturedSpec, isA<ExitCodeSpec>());
    });

    testWidgets('refuses empty name', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [
            L10N.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: L10N.supportedLocales,
          home: Material(
            child: DetectorEditorDialog(
              existingNames: const <String>{},
              onCommit: (_, _) async {
                fail('onCommit should not fire for empty name');
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.text('Name is required'), findsOneWidget);
    });

    // Opens the editor on a real dialog route (as the settings section
    // does) so Cancel can actually pop it.
    Future<void> openOnRoute(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [
            L10N.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: L10N.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => DetectorEditorDialog(
                    existingNames: const <String>{},
                    onCommit: (_, _) async {},
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('dirty cancel prompts to discard; keep editing stays open', (
      tester,
    ) async {
      await openOnRoute(tester);

      // Dirty the form.
      await tester.enterText(find.byType(TextField).first, 'strict');
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsOneWidget);

      // "Keep editing" returns to the editor with input intact.
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsNothing);
      expect(find.byType(DetectorEditorDialog), findsOneWidget);
      expect(find.text('strict'), findsOneWidget);

      // "Discard" closes the editor.
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Discard'));
      await tester.pumpAndSettle();
      expect(find.byType(DetectorEditorDialog), findsNothing);
    });

    testWidgets('clean cancel closes without a prompt', (tester) async {
      await openOnRoute(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsNothing);
      expect(find.byType(DetectorEditorDialog), findsNothing);
    });
  });
}
