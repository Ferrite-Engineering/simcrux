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
      'setRecentProjects replaces the list and persists it as JSON',
      () async {
        await container.read(appSettingsProvider.future);
        final notifier = container.read(appSettingsProvider.notifier);
        await notifier.setRecentProjects([
          '/proj/two/simcrux.yaml',
          '/proj/one/simcrux.yaml',
        ]);

        final state = container.read(appSettingsProvider).value;
        expect(state!.recentProjectPaths, [
          '/proj/two/simcrux.yaml',
          '/proj/one/simcrux.yaml',
        ]);

        // A fresh load against the same prefs returns the same list, from
        // the JSON string the codec has always written.
        final reloaded = await const SimcruxSettingsCodec().load(prefs);
        expect(reloaded.recentProjectPaths, [
          '/proj/two/simcrux.yaml',
          '/proj/one/simcrux.yaml',
        ]);
        expect(prefs.getString('simcrux.recentProjectPaths'), isNotNull);
      },
    );

    test('setRecentProjects with the same list changes nothing', () async {
      await container.read(appSettingsProvider.future);
      final notifier = container.read(appSettingsProvider.notifier);
      await notifier.setRecentProjects(['/proj/a/simcrux.yaml']);
      final before = container.read(appSettingsProvider).value;
      await notifier.setRecentProjects(['/proj/a/simcrux.yaml']);

      expect(container.read(appSettingsProvider).value, same(before));
    });

    test('setRecentProjects with an empty list empties it', () async {
      await container.read(appSettingsProvider.future);
      final notifier = container.read(appSettingsProvider.notifier);
      await notifier.setRecentProjects(['/proj/a/simcrux.yaml']);
      await notifier.setRecentProjects(const <String>[]);

      final state = container.read(appSettingsProvider).value;
      expect(state!.recentProjectPaths, isEmpty);
      expect(
        (await const SimcruxSettingsCodec().load(prefs)).recentProjectPaths,
        isEmpty,
      );
    });
  });
}
