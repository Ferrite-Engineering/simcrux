// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// integration_test/theme/theme_switch_test.dart
//
// Theme preset switching flips the live `MaterialApp.themeMode` dark↔light
// end-to-end through the `appSettingsProvider` → `cruxColorThemeProvider`
// bridge (SimCrux drives `themeMode = themeModeFromBrightness(cruxColorTheme)`
// exactly as NetCrux/WaveCrux do).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';

import '../helpers/app_driver.dart';

ThemeMode _liveThemeMode(WidgetTester tester) {
  final app = tester.widget<MaterialApp>(find.byType(MaterialApp).first);
  return app.themeMode ?? ThemeMode.system;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  suppressPlatformSemanticsLeak();

  testWidgets(
    'switching presets flips MaterialApp brightness',
    (tester) async {
      await bootSimcrux(tester);
      final root = rootContainer(tester);

      Future<void> setTheme(String name, ThemeMode mode) async {
        await root.read(appSettingsProvider.notifier).setActiveThemeName(name);
        await pumpUntil(tester, () => _liveThemeMode(tester) == mode);
        expect(
          _liveThemeMode(tester),
          mode,
          reason: '$name preset drives MaterialApp.themeMode $mode',
        );
      }

      await setTheme('wavecrux-dark', ThemeMode.dark);
      await setTheme('wavecrux-light', ThemeMode.light);
      await setTheme('solarized-dark', ThemeMode.dark);

      expect(tester.takeException(), isNull);
    },
  );
}
