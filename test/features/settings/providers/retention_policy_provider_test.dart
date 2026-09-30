// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_settings/crux_settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/domain/models/retention_policy.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/settings/providers/retention_policy_provider.dart';
import 'package:simcrux/services/settings/simcrux_settings_codec.dart';

/// A container wired to a mock-backed settings service, matching how the
/// app resolves settings at runtime.
Future<ProviderContainer> _container() async {
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      settingsServiceProvider.overrideWithValue(
        SettingsService(const SimcruxSettingsCodec(), prefsOverride: prefs),
      ),
    ],
  );
  addTearDown(container.dispose);
  // Resolve the async load before anything reads the policy.
  await container.read(appSettingsProvider.future);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('retentionPolicyProvider', () {
    test('initial value is RetentionPolicy.defaultPolicy', () async {
      final container = await _container();
      expect(
        container.read(retentionPolicyProvider),
        RetentionPolicy.defaultPolicy,
      );
    });

    test('replace updates state in place', () async {
      final container = await _container();
      container
          .read(retentionPolicyProvider.notifier)
          .replace(RetentionPolicy.unlimited);
      expect(
        container.read(retentionPolicyProvider),
        RetentionPolicy.unlimited,
      );
    });

    test('update mutates individual fields', () async {
      final container = await _container();
      container.read(retentionPolicyProvider.notifier).update(maxAgeDays: 7);
      expect(container.read(retentionPolicyProvider).maxAgeDays, 7);

      container
          .read(retentionPolicyProvider.notifier)
          .update(clearMaxAge: true);
      expect(container.read(retentionPolicyProvider).maxAgeDays, isNull);
    });

    test('update can set the waveform-run limit', () async {
      final container = await _container();
      container
          .read(retentionPolicyProvider.notifier)
          .update(maxWaveformRuns: 3);
      expect(container.read(retentionPolicyProvider).maxWaveformRuns, 3);
    });

    test(
      'a replaced policy survives a restart — it used to live only in '
      'this notifier, so a user who dialled retention down got the '
      'defaults back on next launch and the sweep silently stopped',
      () async {
        const tightened = RetentionPolicy(
          maxAgeDays: 3,
          maxDataPoints: 100,
          maxWaveformRuns: 1,
        );

        final first = await _container();
        // Awaits the write rather than going through `replace`, whose
        // persistence is deliberately fire-and-forget — the assertion is
        // about what reaches disk, not the notifier's own state.
        await first
            .read(appSettingsProvider.notifier)
            .setRetentionPolicy(tightened);
        expect(first.read(retentionPolicyProvider), tightened);

        // A fresh container over the same preferences is the restart.
        final second = await _container();
        expect(second.read(retentionPolicyProvider), tightened);
      },
    );

    test('a corrupt persisted policy falls back to the default rather than '
        'refusing to start', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'simcrux.retentionPolicy': 'not json at all',
      });
      final container = await _container();
      expect(
        container.read(retentionPolicyProvider),
        RetentionPolicy.defaultPolicy,
      );
    });
  });
}
