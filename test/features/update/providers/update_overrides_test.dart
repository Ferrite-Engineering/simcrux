// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_license/crux_license.dart';
import 'package:crux_settings/crux_settings.dart';
import 'package:crux_updates/crux_updates.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/core/update/simcrux_update_config.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/update/providers/observed_server_time_provider.dart';
import 'package:simcrux/features/update/providers/update_overrides.dart';
import 'package:simcrux/services/settings/simcrux_settings_codec.dart';

/// Shape assertions on the SimCrux → `crux_updates` binding. The behaviour of
/// the update mechanism itself is covered by `update_status_machine_test.dart`;
/// what matters here is that each of the package's seams is actually bound,
/// because an unbound seam fails silently months after a release.
Future<ProviderContainer> _container() async {
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      ...simcruxUpdateOverrides,
      settingsServiceProvider.overrideWithValue(
        SettingsService<AppSettings>(
          const SimcruxSettingsCodec(),
          prefsOverride: prefs,
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// A licence tier a test can change mid-session, the way entering a key does.
class _MutableTier extends Notifier<LicenseTier> {
  @override
  LicenseTier build() => LicenseTier.openCore;

  LicenseTier get value => state;

  set value(LicenseTier tier) => state = tier;
}

final _mutableTierProvider = NotifierProvider<_MutableTier, LicenseTier>(
  _MutableTier.new,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('simcruxUpdateOverrides', () {
    test('binds the config, so the package default never throws', () async {
      final container = await _container();
      expect(
        container.read(cruxUpdateConfigProvider),
        same(simcruxUpdateConfig),
      );
    });

    test(
      'binds a URL launcher, so Update Now is never a dead button',
      () async {
        final container = await _container();
        // The package default throws on *use*, not on read, so assert identity
        // against the unbound default instead of invoking it.
        final launcher = container.read(updateUrlLauncherProvider);
        expect(launcher, isNotNull);
        final unbound = ProviderContainer().read(updateUrlLauncherProvider);
        expect(
          launcher,
          isNot(same(unbound)),
          reason: 'updateUrlLauncherProvider is still the throwing default',
        );
      },
    );

    test(
      'the auto-check gate reads the persisted setting (default on)',
      () async {
        final container = await _container();
        expect(
          await container.read(autoUpdateCheckEnabledProvider.future),
          isTrue,
        );
      },
    );

    test('turning the setting off closes the auto-check gate', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'simcrux.autoCheckForUpdates': false,
      });
      final container = await _container();
      expect(
        await container.read(autoUpdateCheckEnabledProvider.future),
        isFalse,
        reason:
            'Settings → General must actually reach '
            'autoUpdateCheckEnabledProvider',
      );
    });

    test('the server-time sink advances the persisted watermark', () async {
      final container = await _container();
      container.read(observedServerTimeSinkProvider)(
        DateTime.utc(2026, 9, 20, 8),
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        container.read(observedServerTimeStoreProvider),
        DateTime.utc(2026, 9, 20, 8),
      );
    });

    test('the watermark reaches the crux_license expiry clock', () async {
      final container = await _container();
      expect(container.read(observedServerTimeProvider), isNull);

      container.read(observedServerTimeSinkProvider)(
        DateTime.utc(2026, 9, 20, 8),
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        container.read(observedServerTimeProvider),
        DateTime.utc(2026, 9, 20, 8),
        reason:
            'without this hop the beta-expiry clock hardening is inert and a '
            'device-clock rollback defers expiry indefinitely',
      );
    });
  });

  group('updateEditionProvider binding', () {
    // Decides whether a release that changed only paid features is offered
    // (the manifest's `open_core_version`). Left unbound, the package default
    // offers every release to every seat — silently.
    ProviderContainer seat(LicenseTier tier, {bool betaPeriod = false}) {
      final container = ProviderContainer(
        overrides: <Override>[
          ...simcruxUpdateOverrides,
          betaPeriodProvider.overrideWithValue(betaPeriod),
          licenseTierProvider.overrideWithValue(tier),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('a seat without a licence is an open-core seat', () {
      expect(
        seat(LicenseTier.openCore).read(updateEditionProvider),
        UpdateEdition.openCore,
      );
    });

    test('every paid tier unlocks', () {
      for (final tier in [
        LicenseTier.edu,
        LicenseTier.pro,
        LicenseTier.enterprise,
      ]) {
        expect(
          seat(tier).read(updateEditionProvider),
          UpdateEdition.unlocked,
          reason: '$tier',
        );
      }
    });

    test('a beta period unlocks every seat, as it opens every gate', () {
      expect(
        seat(
          LicenseTier.openCore,
          betaPeriod: true,
        ).read(updateEditionProvider),
        UpdateEdition.unlocked,
      );
    });

    test('follows a licence entered mid-session', () {
      final container = ProviderContainer(
        overrides: <Override>[
          ...simcruxUpdateOverrides,
          betaPeriodProvider.overrideWithValue(false),
          licenseTierProvider.overrideWith(
            (ref) => ref.watch(_mutableTierProvider),
          ),
        ],
      );
      addTearDown(container.dispose);
      expect(container.read(updateEditionProvider), UpdateEdition.openCore);

      container.read(_mutableTierProvider.notifier).value = LicenseTier.pro;

      expect(container.read(updateEditionProvider), UpdateEdition.unlocked);
    });
  });
}
