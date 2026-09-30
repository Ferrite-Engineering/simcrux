// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/features/update/providers/observed_server_time_provider.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('ObservedServerTimeStore', () {
    test('starts null when nothing has ever been observed', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(observedServerTimeStoreProvider), isNull);
      // Let the async load settle; it must not invent a value.
      await Future<void>.delayed(Duration.zero);
      expect(container.read(observedServerTimeStoreProvider), isNull);
    });

    test('records the first observation', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(observedServerTimeStoreProvider); // materialize

      final t = DateTime.utc(2026, 9, 1, 12, 30);
      await container.read(observedServerTimeStoreProvider.notifier).record(t);

      expect(container.read(observedServerTimeStoreProvider), t);
    });

    test('advances on a later observation', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(observedServerTimeStoreProvider.notifier);

      await notifier.record(DateTime.utc(2026, 9, 1, 1));
      await notifier.record(DateTime.utc(2026, 9, 5));

      expect(
        container.read(observedServerTimeStoreProvider),
        DateTime.utc(2026, 9, 5),
      );
    });

    test(
      'MONOTONIC: an earlier observation never rolls the value back',
      () async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final notifier = container.read(
          observedServerTimeStoreProvider.notifier,
        );

        await notifier.record(DateTime.utc(2026, 9, 5));
        // A stale cached manifest, a CDN replay, or a mis-set server.
        await notifier.record(DateTime.utc(2026, 2, 10));

        expect(
          container.read(observedServerTimeStoreProvider),
          DateTime.utc(2026, 9, 5),
          reason: 'the watermark must only ever advance',
        );
      },
    );

    test('an identical observation is a no-op', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(observedServerTimeStoreProvider.notifier);

      final t = DateTime.utc(2026, 9, 5);
      await notifier.record(t);
      await notifier.record(t);

      expect(container.read(observedServerTimeStoreProvider), t);
    });

    test('persists the observation under the documented prefs key', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container
          .read(observedServerTimeStoreProvider.notifier)
          .record(DateTime.utc(2026, 9, 5, 6, 7, 8));

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(kObservedServerTimePrefsKey),
        DateTime.utc(2026, 9, 5, 6, 7, 8).toIso8601String(),
      );
    });

    test(
      'reloads the persisted watermark on a fresh (offline) launch',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          kObservedServerTimePrefsKey: DateTime.utc(
            2026,
            9,
            5,
          ).toIso8601String(),
        });

        final container = ProviderContainer();
        addTearDown(container.dispose);
        container.read(observedServerTimeStoreProvider); // triggers the load

        // The load is async; the state advances once it resolves.
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(
          container.read(observedServerTimeStoreProvider),
          DateTime.utc(2026, 9, 5),
          reason:
              'an offline launch must still benefit from the last observed '
              'server time',
        );
      },
    );

    test('a corrupt persisted value is ignored rather than fatal', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        kObservedServerTimePrefsKey: 'not-a-timestamp',
      });

      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(observedServerTimeStoreProvider);
      await Future<void>.delayed(Duration.zero);

      expect(container.read(observedServerTimeStoreProvider), isNull);
    });

    test('a post-dispose record does not throw', () async {
      final container = ProviderContainer();
      final notifier = container.read(observedServerTimeStoreProvider.notifier);
      container.dispose();

      await expectLater(
        notifier.record(DateTime.utc(2026, 9, 5)),
        completes,
      );
    });
  });
}
