// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

@TestOn('vm')
library;

import 'package:crux_settings/crux_settings.dart';
import 'package:crux_theme/crux_theme.dart';
import 'package:flutter/material.dart' show Brightness, Color;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/core/theme/simcrux_color_theme_bootstrap.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/services/settings/simcrux_settings_codec.dart';

/// Builds a container whose settings hydrate from [seed].
Future<ProviderContainer> _containerWith(Map<String, Object> seed) async {
  SharedPreferences.setMockInitialValues(seed);
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      settingsServiceProvider.overrideWithValue(
        SettingsService<AppSettings>(
          const SimcruxSettingsCodec(),
          prefsOverride: prefs,
        ),
      ),
      simcruxCruxColorThemeOverride,
    ],
  );
  await container.read(appSettingsProvider.future);
  return container;
}

void main() {
  group('SimcruxCruxColorThemeNotifier', () {
    test('seeds the suite-default preset before settings hydrate', () {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final container = ProviderContainer(
        overrides: [simcruxCruxColorThemeOverride],
      );
      addTearDown(container.dispose);
      expect(container.read(cruxColorThemeProvider).id, cruxDarkPresetId);
    });

    test('resolves a persisted current-generation preset id', () async {
      final container = await _containerWith(<String, Object>{});
      addTearDown(container.dispose);
      await container
          .read(appSettingsProvider.notifier)
          .setActiveThemeName(cruxLightPresetId);
      expect(container.read(cruxColorThemeProvider).id, cruxLightPresetId);
    });

    test("migrates a beta user's retired wavecrux-* preset id", () async {
      // The `wavecrux-dark` / `wavecrux-light` ids shipped through the
      // public beta as the shared suite default, so they are persisted
      // in every beta user's settings. Reading them through
      // `builtinPresetById` (which applies the legacy alias map) is what
      // keeps their saved theme instead of silently reverting to dark.
      final container = await _containerWith(<String, Object>{});
      addTearDown(container.dispose);
      await container
          .read(appSettingsProvider.notifier)
          .setActiveThemeName('wavecrux-light');
      expect(container.read(cruxColorThemeProvider).id, cruxLightPresetId);
    });

    test('falls back to the seed for an unrecognised preset id', () async {
      final container = await _containerWith(<String, Object>{});
      addTearDown(container.dispose);
      await container
          .read(appSettingsProvider.notifier)
          .setActiveThemeName('some-uninstalled-pack');
      expect(container.read(cruxColorThemeProvider).id, cruxDarkPresetId);
    });

    group('theme packs', () {
      // Settings persist only the active theme's id. A pack's tokens live in
      // its installed file, so a notifier that only knows built-in presets
      // resolves a pack's id to the seed preset: straight after activation,
      // when the settings write rebuilds it, and again on every launch.
      CruxColorTheme packTheme() => CruxColorTheme(
        id: 'house-style',
        displayName: 'House Style',
        brightness: Brightness.light,
        tokens: const {
          'chrome': {'background': Color(0xFFFAF0E6)},
        },
      );

      ThemePack installedPack() => ThemePack(
        id: 'house-style',
        displayName: 'House Style',
        brightness: Brightness.light,
        tokens: packTheme().tokens,
      );

      test(
        'an activated pack stays active after its choice is saved',
        () async {
          final container = await _containerWith(<String, Object>{});
          addTearDown(container.dispose);

          container.read(cruxColorThemeProvider.notifier).activate(packTheme());
          await pumpEventQueue();

          expect(
            container.read(appSettingsProvider).value?.core.activeThemeName,
            'house-style',
          );
          final active = container.read(cruxColorThemeProvider);
          expect(active.id, 'house-style');
          expect(
            active.color('chrome', 'background')?.toARGB32(),
            0xFFFAF0E6,
          );
        },
      );

      test('choosing a preset afterwards leaves the pack', () async {
        final container = await _containerWith(<String, Object>{});
        addTearDown(container.dispose);

        container.read(cruxColorThemeProvider.notifier)
          ..activate(packTheme())
          ..activate(builtinPresetById(cruxLightPresetId)!);
        await pumpEventQueue();

        expect(container.read(cruxColorThemeProvider).id, cruxLightPresetId);
      });

      test('the next launch restores the saved pack from the installed '
          'store', () async {
        final first = await _containerWith(<String, Object>{});
        first.read(cruxColorThemeProvider.notifier).activate(packTheme());
        await pumpEventQueue();
        first.dispose();

        // A relaunch: a fresh container over the same stored preferences.
        final prefs = await SharedPreferences.getInstance();
        final relaunched = ProviderContainer(
          overrides: [
            settingsServiceProvider.overrideWithValue(
              SettingsService<AppSettings>(
                const SimcruxSettingsCodec(),
                prefsOverride: prefs,
              ),
            ),
            simcruxCruxColorThemeOverride,
          ],
        );
        addTearDown(relaunched.dispose);
        final store = InMemoryThemePackStore(initialPacks: [installedPack()]);

        await restoreActiveThemePack(
          relaunched,
          storeResolver: () async => store,
        );
        await pumpEventQueue();

        final active = relaunched.read(cruxColorThemeProvider);
        expect(active.id, 'house-style');
        expect(
          active.color('chrome', 'background')?.toARGB32(),
          0xFFFAF0E6,
        );
      });

      test('a saved pack that has been uninstalled leaves the default '
          'theme', () async {
        final container = await _containerWith(<String, Object>{});
        addTearDown(container.dispose);
        await container
            .read(appSettingsProvider.notifier)
            .setActiveThemeName('house-style');

        await restoreActiveThemePack(
          container,
          storeResolver: () async => InMemoryThemePackStore(),
        );

        expect(container.read(cruxColorThemeProvider).id, cruxDarkPresetId);
      });

      test('a built-in preset is not looked up in the store', () async {
        final container = await _containerWith(<String, Object>{});
        addTearDown(container.dispose);
        var resolved = false;

        await restoreActiveThemePack(
          container,
          storeResolver: () async {
            resolved = true;
            return InMemoryThemePackStore();
          },
        );

        expect(resolved, isFalse);
      });
    });

    test('high-contrast-dark resolves without throwing', () async {
      // SimCrux registers no `PresetTokenOverlay`, and this preset's
      // only tokens were WaveCrux canvas tokens that moved out to a
      // product-registered overlay — so it composes to an EMPTY token
      // table here. Known, accepted gap: it must degrade to the default
      // Material surface, never crash.
      final container = await _containerWith(<String, Object>{});
      addTearDown(container.dispose);
      await container
          .read(appSettingsProvider.notifier)
          .setActiveThemeName('high-contrast-dark');
      final theme = container.read(cruxColorThemeProvider);
      expect(theme.id, 'high-contrast-dark');
      expect(theme.tokens, isEmpty);
    });
  });
}
