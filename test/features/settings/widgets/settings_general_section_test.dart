// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_settings/crux_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/settings/widgets/settings_general_section.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/settings/simcrux_settings_codec.dart';

Future<Widget> _wrap({
  Locale locale = const Locale('en'),
  bool showDiagnosticsToggle = false,
}) async {
  final prefs = await SharedPreferences.getInstance();
  return ProviderScope(
    overrides: [
      settingsServiceProvider.overrideWithValue(
        SettingsService<AppSettings>(
          const SimcruxSettingsCodec(),
          prefsOverride: prefs,
        ),
      ),
    ],
    child: MaterialApp(
      locale: locale,
      localizationsDelegates: const [
        L10N.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: L10N.supportedLocales,
      // The Settings screen scrolls its category content; the section itself
      // is a plain Column taller than the 800x600 test surface once every
      // toggle is shown.
      home: Scaffold(
        body: SingleChildScrollView(
          child: SettingsGeneralSection(
            settings: const AppSettings(),
            showDiagnosticsToggle: showDiagnosticsToggle,
          ),
        ),
      ),
    ),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('SettingsGeneralSection', () {
    testWidgets('renders the auto-reload and log-preview knobs', (
      tester,
    ) async {
      await tester.pumpWidget(await _wrap());
      await tester.pump();

      final l10n = L10N.of(tester.element(find.byType(Scaffold)));
      expect(find.text(l10n.settingsAutoReloadLabel), findsOneWidget);
      expect(
        find.text(l10n.settingsLogPreviewLineCountLabel),
        findsOneWidget,
      );
      // The suite-shared segmented control (prompt / auto / off in the
      // canonical order) replaced the old dropdown — the only app of the
      // four that presented the enum that way.
      expect(find.text(l10n.settingsAutoReloadPrompt), findsOneWidget);
      expect(find.byType(SegmentedButton<AutoReloadMode>), findsOneWidget);
      expect(find.byType(DropdownButton<AutoReloadMode>), findsNothing);
      expect(find.byType(Slider), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('selecting an auto-reload mode updates the backing provider', (
      tester,
    ) async {
      await tester.pumpWidget(await _wrap());
      await tester.pump();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(SettingsGeneralSection)),
      );
      // Let the AsyncNotifier hydrate so mutators see a loaded value.
      await container.read(appSettingsProvider.future);
      await tester.pump();

      final l10n = L10N.of(tester.element(find.byType(Scaffold)));
      // Segmented control: tap the segment directly (no menu to open).
      await tester.tap(find.text(l10n.settingsAutoReloadAuto));
      await tester.pumpAndSettle();

      expect(
        container.read(appSettingsProvider).value?.autoReloadMode,
        AutoReloadMode.auto,
      );
    });

    testWidgets('dragging the slider updates the log-preview line count', (
      tester,
    ) async {
      await tester.pumpWidget(await _wrap());
      await tester.pump();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(SettingsGeneralSection)),
      );
      await container.read(appSettingsProvider.future);
      await tester.pump();

      final before = const AppSettings().inspectorLogPreviewLineCount;
      await tester.drag(find.byType(Slider), const Offset(200, 0));
      await tester.pump();

      final after = container
          .read(appSettingsProvider)
          .value
          ?.inspectorLogPreviewLineCount;
      expect(after, isNotNull);
      expect(after, isNot(before));
    });

    testWidgets('renders the auto-update-check toggle, on by default', (
      tester,
    ) async {
      await tester.pumpWidget(await _wrap());
      await tester.pump();

      final l10n = L10N.of(tester.element(find.byType(Scaffold)));
      expect(find.text(l10n.settingsAutoCheckUpdatesLabel), findsOneWidget);
      expect(
        find.text(l10n.settingsAutoCheckUpdatesDescription),
        findsOneWidget,
      );

      final tile = tester.widget<SwitchListTile>(
        find.byKey(const Key('settings.autoCheckForUpdates')),
      );
      expect(tile.value, isTrue);
    });

    testWidgets('renders the auto-run-on-open toggle, OFF by default', (
      tester,
    ) async {
      await tester.pumpWidget(await _wrap());
      await tester.pump();

      final l10n = L10N.of(tester.element(find.byType(Scaffold)));
      expect(find.text(l10n.settingsAutoRunOnOpenLabel), findsOneWidget);
      expect(find.text(l10n.settingsAutoRunOnOpenDescription), findsOneWidget);

      final tile = tester.widget<SwitchListTile>(
        find.byKey(const Key('settings.autoRunOnOpen')),
      );
      expect(
        tile.value,
        isFalse,
        reason:
            'Opening a config must not start the run unless the user opted '
            'in.',
      );
    });

    testWidgets('the auto-run-on-open toggle clears the 44 dp floor', (
      tester,
    ) async {
      await tester.pumpWidget(await _wrap());
      await tester.pump();

      final size = tester.getSize(
        find.byKey(const Key('settings.autoRunOnOpen')),
      );
      expect(size.height, greaterThanOrEqualTo(44.0));
    });

    testWidgets('toggling auto-run-on-open persists the new value', (
      tester,
    ) async {
      await tester.pumpWidget(await _wrap());
      await tester.pump();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(SettingsGeneralSection)),
      );
      await container.read(appSettingsProvider.future);
      await tester.pump();

      await tester.tap(find.byKey(const Key('settings.autoRunOnOpen')));
      await tester.pumpAndSettle();

      expect(
        container.read(appSettingsProvider).value?.autoRunOnOpen,
        isTrue,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('simcrux.autoRunOnOpen'), isTrue);
    });

    testWidgets('the auto-update-check toggle clears the 44 dp floor', (
      tester,
    ) async {
      await tester.pumpWidget(await _wrap());
      await tester.pump();

      final size = tester.getSize(
        find.byKey(const Key('settings.autoCheckForUpdates')),
      );
      expect(size.height, greaterThanOrEqualTo(44.0));
    });

    testWidgets('toggling auto-update-check persists the new value', (
      tester,
    ) async {
      await tester.pumpWidget(await _wrap());
      await tester.pump();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(SettingsGeneralSection)),
      );
      await container.read(appSettingsProvider.future);
      await tester.pump();

      await tester.tap(find.byKey(const Key('settings.autoCheckForUpdates')));
      await tester.pumpAndSettle();

      expect(
        container.read(appSettingsProvider).value?.autoCheckForUpdates,
        isFalse,
        reason: 'the toggle must reach AppSettingsNotifier',
      );

      // And back on again.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('simcrux.autoCheckForUpdates'), isFalse);
    });

    testWidgets('the diagnostics opt-in is hidden where it would be inert', (
      tester,
    ) async {
      // Debug and profile builds force the diagnostics surfaces on, so the
      // switch shows only in release builds (the constructor default).
      await tester.pumpWidget(await _wrap());
      await tester.pump();
      expect(
        find.byKey(const Key('settings.diagnosticsEnabled')),
        findsNothing,
      );
    });

    testWidgets('toggling the diagnostics opt-in persists it', (tester) async {
      // Without this switch a release build had no way to enable Tab
      // Diagnostics: the action stayed greyed out behind a setting nothing
      // could set.
      await tester.pumpWidget(await _wrap(showDiagnosticsToggle: true));
      await tester.pump();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(SettingsGeneralSection)),
      );
      await container.read(appSettingsProvider.future);
      await tester.pump();

      final l10n = L10N.of(tester.element(find.byType(Scaffold)));
      expect(find.text(l10n.settingsDiagnosticsEnabledLabel), findsOneWidget);
      final finder = find.byKey(const Key('settings.diagnosticsEnabled'));
      expect(tester.widget<SwitchListTile>(finder).value, isFalse);
      expect(tester.getSize(finder).height, greaterThanOrEqualTo(44.0));

      await tester.ensureVisible(finder);
      await tester.tap(finder);
      await tester.pumpAndSettle();

      expect(
        container.read(appSettingsProvider).value?.diagnosticsEnabled,
        isTrue,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('settings.diagnosticsEnabled'), isTrue);
    });

    testWidgets('locale sweep renders without exceptions', (tester) async {
      for (final locale in const [
        Locale('en'),
        Locale('zh', 'CN'),
        Locale('zh'),
        Locale('ja'),
        Locale('ko'),
      ]) {
        await tester.pumpWidget(
          await _wrap(locale: locale, showDiagnosticsToggle: true),
        );
        await tester.pump();
        expect(tester.takeException(), isNull, reason: '$locale');
      }
    });
  });
}
