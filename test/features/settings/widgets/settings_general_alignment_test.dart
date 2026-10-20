// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_ide_layout/crux_ide_layout.dart' show CruxDesktopTokens;
import 'package:crux_settings_ui/crux_settings_ui.dart'
    show CruxSettingsSectionCard;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/features/settings/widgets/settings_general_section.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// The toggle rows of Settings > General start where the suite's shared
/// settings tiles do.
///
/// The toggles are bare `CruxFormRow.toggle`s, which carry no padding; the
/// shared tiles (the auto-reload tile, the slider tile) inset their own
/// content 16 dp on each side. The toggles sat about 16 dp to the left of
/// them, a misalignment nobody could see in a widget test that looked only
/// at what was on screen.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<L10N> pump(
    WidgetTester tester, {
    Locale locale = const Locale('en'),
  }) async {
    tester.view
      ..physicalSize = const Size(1600, 1200)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          locale: locale,
          theme: ThemeData(
            extensions: const <ThemeExtension<dynamic>>[CruxDesktopTokens()],
          ),
          localizationsDelegates: const [
            L10N.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: L10N.supportedLocales,
          home: const Scaffold(
            body: SingleChildScrollView(
              // The same card the Settings screen wraps every section in.
              child: CruxSettingsSectionCard(
                children: [
                  SettingsGeneralSection(
                    settings: AppSettings(),
                    showDiagnosticsToggle: true,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return lookupL10N(locale);
  }

  for (final locale in const <Locale>[
    Locale('en'),
    Locale('zh', 'CN'),
    Locale('zh'),
    Locale('ja'),
    Locale('ko'),
  ]) {
    testWidgets('every toggle label starts at the left edge of the shared '
        "tiles' labels in ${locale.toLanguageTag()}", (tester) async {
      final l10n = await pump(tester, locale: locale);

      double left(String label) {
        final finder = find.text(label);
        expect(finder, findsOneWidget, reason: label);
        return tester.getTopLeft(finder).dx;
      }

      // The two shared tiles above the toggles.
      final tileEdge = left(l10n.settingsAutoReloadLabel);
      expect(
        left(l10n.settingsLogPreviewLineCountLabel),
        closeTo(tileEdge, 0.5),
        reason: 'the shared tiles agree with each other',
      );

      for (final label in <String>[
        l10n.settingsAutoRunOnOpenLabel,
        l10n.settingsAutoCheckUpdatesLabel,
        l10n.settingsDiagnosticsEnabledLabel,
      ]) {
        expect(
          left(label),
          closeTo(tileEdge, 0.5),
          reason: '"$label" is not aligned with the shared settings tiles',
        );
      }
    });
  }
}
