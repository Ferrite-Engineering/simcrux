// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_settings/crux_settings.dart';
import 'package:crux_theme/crux_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/core/theme/simcrux_color_theme_bootstrap.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/settings/widgets/color_theme_section.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/settings/simcrux_settings_codec.dart';

Future<Widget> _wrap(
  Directory packDir, {
  Locale locale = const Locale('en'),
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
      // The production bridge: preset activation persists to
      // AppSettings.core.activeThemeName / core.themeOverrides.
      simcruxCruxColorThemeOverride,
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
      home: Scaffold(
        body: SingleChildScrollView(
          child: ColorThemeSection(
            packDirectoryResolver: () async => packDir,
            pickPackDocument: () async => null,
            savePackDocument: (_) async => null,
          ),
        ),
      ),
    ),
  );
}

void main() {
  late Directory packDir;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    packDir = Directory.systemTemp.createTempSync('color_theme_section_test');
  });

  tearDown(() {
    if (packDir.existsSync()) packDir.deleteSync(recursive: true);
  });

  group('ColorThemeSection', () {
    testWidgets('renders the preset picker and theme pack browser', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1100, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(await _wrap(packDir));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(PresetPicker), findsOneWidget);
      expect(find.byType(ThemePackBrowser), findsOneWidget);
      // Every built-in preset gets a card.
      expect(
        find.byType(PresetCard),
        findsNWidgets(builtinPresets().length),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('activating a preset updates the theme provider and persists', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1100, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(await _wrap(packDir));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final container = ProviderScope.containerOf(
        tester.element(find.byType(ColorThemeSection)),
      );
      // Let the settings AsyncNotifier hydrate so persistence works.
      await container.read(appSettingsProvider.future);
      await tester.pump();

      // The seeded/default theme is crux-dark; activate another.
      expect(container.read(cruxColorThemeProvider).id, 'crux-dark');
      final lightCard = find.byWidgetPredicate(
        (w) => w is PresetCard && w.theme.id == 'crux-light',
      );
      expect(lightCard, findsOneWidget);
      await tester.ensureVisible(lightCard);
      await tester.tap(lightCard);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(container.read(cruxColorThemeProvider).id, 'crux-light');
      expect(
        container.read(appSettingsProvider).value?.core.activeThemeName,
        'crux-light',
      );
    });

    testWidgets('locale sweep renders without exceptions', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      for (final locale in const [
        Locale('en'),
        Locale('zh', 'CN'),
        Locale('zh'),
        Locale('ja'),
        Locale('ko'),
      ]) {
        await tester.pumpWidget(await _wrap(packDir, locale: locale));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull, reason: '$locale');
      }
    });
  });
}
