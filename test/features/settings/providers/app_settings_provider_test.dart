// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_settings/crux_settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/services/settings/simcrux_settings_codec.dart';

void main() {
  group('AppSettingsNotifier', () {
    late ProviderContainer container;
    late SharedPreferences prefs;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      prefs = await SharedPreferences.getInstance();
      container = ProviderContainer(
        overrides: [
          settingsServiceProvider.overrideWithValue(
            SettingsService<AppSettings>(
              const SimcruxSettingsCodec(),
              prefsOverride: prefs,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
    });

    test('initial load returns AppSettings defaults', () async {
      final settings = await container.read(appSettingsProvider.future);
      expect(settings, const AppSettings());
    });

    test(
      'addRecentProject prepends and persists to SharedPreferences',
      () async {
        await container.read(appSettingsProvider.future);
        final notifier = container.read(appSettingsProvider.notifier);
        await notifier.addRecentProject('/proj/one/simcrux.yaml');
        await notifier.addRecentProject('/proj/two/simcrux.yaml');

        final state = container.read(appSettingsProvider).value;
        expect(state!.recentProjectPaths, [
          '/proj/two/simcrux.yaml',
          '/proj/one/simcrux.yaml',
        ]);

        // Verify persistence: a fresh load against the same prefs returns
        // the same list.
        final reloaded = await const SimcruxSettingsCodec().load(prefs);
        expect(reloaded.recentProjectPaths, [
          '/proj/two/simcrux.yaml',
          '/proj/one/simcrux.yaml',
        ]);
      },
    );

    test('addRecentProject deduplicates existing entries', () async {
      await container.read(appSettingsProvider.future);
      final notifier = container.read(appSettingsProvider.notifier);
      await notifier.addRecentProject('/proj/a/simcrux.yaml');
      await notifier.addRecentProject('/proj/b/simcrux.yaml');
      await notifier.addRecentProject('/proj/a/simcrux.yaml');

      final state = container.read(appSettingsProvider).value;
      expect(state!.recentProjectPaths, [
        '/proj/a/simcrux.yaml',
        '/proj/b/simcrux.yaml',
      ]);
    });

    test('addRecentProject caps at recentProjectsMax entries', () async {
      await container.read(appSettingsProvider.future);
      final notifier = container.read(appSettingsProvider.notifier);
      for (var i = 0; i < AppSettings.recentProjectsMax + 3; i++) {
        await notifier.addRecentProject('/proj/$i/simcrux.yaml');
      }

      final state = container.read(appSettingsProvider).value;
      expect(state!.recentProjectPaths.length, AppSettings.recentProjectsMax);
      // Most recent at index 0.
      expect(
        state.recentProjectPaths.first,
        '/proj/${AppSettings.recentProjectsMax + 2}/simcrux.yaml',
      );
    });

    test('removeRecentProject removes the entry and persists', () async {
      await container.read(appSettingsProvider.future);
      final notifier = container.read(appSettingsProvider.notifier);
      await notifier.addRecentProject('/proj/a/simcrux.yaml');
      await notifier.addRecentProject('/proj/b/simcrux.yaml');
      await notifier.removeRecentProject('/proj/a/simcrux.yaml');

      final state = container.read(appSettingsProvider).value;
      expect(state!.recentProjectPaths, ['/proj/b/simcrux.yaml']);
    });

    test('removeRecentProject is a no-op when entry is not present', () async {
      await container.read(appSettingsProvider.future);
      final notifier = container.read(appSettingsProvider.notifier);
      await notifier.addRecentProject('/proj/a/simcrux.yaml');
      await notifier.removeRecentProject('/proj/missing/simcrux.yaml');

      final state = container.read(appSettingsProvider).value;
      expect(state!.recentProjectPaths, ['/proj/a/simcrux.yaml']);
    });
  });
}
