// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_license/crux_license.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/features/update/providers/observed_server_time_provider.dart';

/// The clock-tampering hardening loop, end to end on the SimCrux side:
///
///   update manifest `server_time`
///     → `observedServerTimeSinkProvider`   (bound in `simcruxUpdateOverrides`)
///     → `ObservedServerTimeStore`          (persisted, monotonic)
///     → `observedServerTimeProvider`       (bound in `simcruxUpdateOverrides`)
///     → `trustedBetaExpiryNow`             (`crux_license`)
///     → `betaExpiryStatusProvider`
///
/// The pure function lives in `crux_license` and is tested there. What is
/// SimCrux's to prove is that the *pairing* is actually wired — the failure
/// mode is a build where both halves exist, neither is connected, and rolling
/// the device clock back silently defers expiry forever.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('beta expiry — device clock rollback', () {
    final expiry = DateTime.utc(2026, 9, 15);

    test(
      'a rolled-back device clock cannot defer expiry below the watermark',
      () {
        // The user winds the clock back to well before the expiry date …
        final rolledBack = DateTime.utc(2026, 2, 10);
        // … but SimCrux has already seen a server time past it.
        final observed = DateTime.utc(2026, 9, 20);

        final trusted = trustedBetaExpiryNow(
          rolledBack,
          observedServerTime: observed,
        );

        expect(trusted, observed);
        expect(
          betaExpiryStatusFor(trusted, expiry: expiry),
          BetaExpiryStatus.expired,
          reason: 'the watermark, not the device clock, decides',
        );
      },
    );

    test(
      'without a watermark the device clock still governs (offline install)',
      () {
        final rolledBack = DateTime.utc(2026, 2, 10);
        final trusted = trustedBetaExpiryNow(rolledBack);

        expect(trusted, rolledBack);
        expect(
          betaExpiryStatusFor(trusted, expiry: expiry),
          BetaExpiryStatus.active,
          reason:
              'a never-online install has no watermark and must keep working',
        );
      },
    );

    test('a device clock ahead of the watermark still wins', () {
      final ahead = DateTime.utc(2026, 12, 20);
      final trusted = trustedBetaExpiryNow(
        ahead,
        observedServerTime: DateTime.utc(2026, 8, 20),
      );

      expect(trusted, ahead);
      expect(
        betaExpiryStatusFor(trusted, expiry: expiry),
        BetaExpiryStatus.expired,
      );
    });

    test(
      'WIRED: the persisted store feeds crux_license through the SimCrux '
      'override',
      () async {
        // Mirrors the `observedServerTimeProvider` binding in
        // `simcruxUpdateOverrides`. Asserting the *composition* here rather
        // than importing the overrides list keeps this test free of the
        // url_launcher / package_info platform channels the full list pulls
        // in — the binding itself is one line and is asserted for shape in
        // `update_overrides_test.dart`.
        final container = ProviderContainer(
          overrides: [
            observedServerTimeProvider.overrideWith(
              (ref) => ref.watch(observedServerTimeStoreProvider),
            ),
          ],
        );
        addTearDown(container.dispose);

        expect(container.read(observedServerTimeProvider), isNull);

        await container
            .read(observedServerTimeStoreProvider.notifier)
            .record(DateTime.utc(2026, 9, 20));

        expect(
          container.read(observedServerTimeProvider),
          DateTime.utc(2026, 9, 20),
          reason:
              'crux_license must see the watermark the update check recorded; '
              'without this override the hardening is inert',
        );
      },
    );

    test(
      'WIRED: a rolled-back watermark observation does not weaken expiry',
      () async {
        final container = ProviderContainer(
          overrides: [
            observedServerTimeProvider.overrideWith(
              (ref) => ref.watch(observedServerTimeStoreProvider),
            ),
          ],
        );
        addTearDown(container.dispose);

        final notifier = container.read(
          observedServerTimeStoreProvider.notifier,
        );
        await notifier.record(DateTime.utc(2026, 9, 20));
        await notifier.record(
          DateTime.utc(2026, 2, 10),
        ); // replayed stale fetch

        final trusted = trustedBetaExpiryNow(
          DateTime.utc(2026, 2, 10),
          observedServerTime: container.read(observedServerTimeProvider),
        );
        expect(
          betaExpiryStatusFor(trusted, expiry: expiry),
          BetaExpiryStatus.expired,
        );
      },
    );
  });

  group('beta expiry — build-injection contract', () {
    test('an absent BETA_EXPIRY means the build never expires', () {
      // The developer / post-beta default: no --dart-define, so kBetaExpiry is
      // null and the gate renders its child untouched.
      expect(parseBetaExpiryDate(0), isNull);
      expect(
        betaExpiryStatusFor(DateTime.utc(2030)),
        BetaExpiryStatus.notApplicable,
      );
    });

    test('an invalid BETA_EXPIRY is treated as absent, not as expired', () {
      expect(parseBetaExpiryDate(20261301), isNull); // month 13
      expect(parseBetaExpiryDate(20260230), isNull); // Feb 30
      expect(parseBetaExpiryDate(-1), isNull);
    });

    test('the warning window opens exactly at the configured day count', () {
      final expiry = DateTime.utc(2026, 9, 15);
      // 8 days out with a 7-day window → still active.
      expect(
        betaExpiryStatusFor(
          DateTime.utc(2026, 9, 7),
          expiry: expiry,
          warningDays: 7,
        ),
        BetaExpiryStatus.active,
      );
      // 7 days out → expiringSoon.
      expect(
        betaExpiryStatusFor(
          DateTime.utc(2026, 9, 8),
          expiry: expiry,
          warningDays: 7,
        ),
        BetaExpiryStatus.expiringSoon,
      );
      // The expiry date itself → expired.
      expect(
        betaExpiryStatusFor(
          DateTime.utc(2026, 9, 15),
          expiry: expiry,
          warningDays: 7,
        ),
        BetaExpiryStatus.expired,
      );
    });
  });
}
