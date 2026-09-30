// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_license/crux_license.dart' show kBetaPeriod;
import 'package:crux_telemetry/crux_telemetry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/core/telemetry/simcrux_telemetry_config.dart';
import 'package:simcrux/core/telemetry/simcrux_telemetry_storage.dart';
import 'package:simcrux/core/telemetry/simcrux_telemetry_strings.dart';
import 'package:simcrux/features/settings/screens/settings_screen.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

import '../../support/recording_telemetry_service.dart';

/// SimCrux's half of the telemetry dark-launch guarantee.
///
/// The 12-cell `beta × dev × consent` gating matrix and the traffic-level
/// beta-inert test live in `crux_telemetry` — they exercise the gate itself,
/// which is shared. What cannot move, and is asserted here, is that **this
/// build** is wired so the gate actually holds:
///
///  * the real `kBetaPeriod` / `kTelemetryDev` constants this release ships
///    with leave the decision to consent, and a beta build, pinned
///    explicitly, still resolves to the no-op service through SimCrux's own
///    configuration;
///  * neither consent surface mounts in a beta build's UI;
///  * the envelope SimCrux assembles is one the ingestion Worker accepts.
///
/// Note what is **absent** and why. WaveCrux carries a third case here — that
/// `app.dart`'s mobile `betaPeriodProvider` override (a store-badging decision
/// under App Store Review Guideline 2.2) must not activate telemetry. SimCrux
/// ships no mobile targets and `lib/app.dart` overrides `betaPeriodProvider`
/// nowhere, so there is no such override to regress against. The protection
/// still exists structurally: `telemetryBetaPeriodProvider` reads the
/// `kBetaPeriod` constant rather than `betaPeriodProvider`, which is asserted
/// by `crux_telemetry`'s own suite. If SimCrux ever grows a mobile target and
/// with it a badging override, the WaveCrux case is the one to copy in.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  /// The root container `bootstrap` builds, minus the network.
  ProviderContainer simcruxContainer({List<Override> extra = const []}) {
    final container = ProviderContainer(
      overrides: [
        cruxTelemetryConfigProvider.overrideWithValue(simcruxTelemetryConfig),
        telemetryStorageProvider.overrideWithValue(
          const SimcruxTelemetryStorage(),
        ),
        telemetryHttpClientProvider.overrideWithValue(
          MockClient((_) async => http.Response('{}', 202)),
        ),
        ...extra,
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('the shipping build is past the beta: consent decides', () async {
    // The flip that activated telemetry is this constant, and nothing else.
    expect(kBetaPeriod, isFalse);
    expect(kTelemetryDev, isFalse);

    final container = simcruxContainer();
    expect(container.read(telemetryBetaPeriodProvider), isFalse);

    // Nobody has answered: once the stored answer has been read, nothing is
    // collected.
    await container.read(telemetryConsentReadyProvider.future);
    expect(container.read(telemetryEnabledProvider), isFalse);
    expect(
      container.read(telemetryServiceProvider),
      isA<NoopTelemetryService>(),
    );

    // An explicit yes opens the gate, which no beta build allowed.
    container.read(telemetryConsentStoreProvider.notifier).state =
        TelemetryConsentState.enabled;
    expect(container.read(telemetryEnabledProvider), isTrue);
    expect(
      container.read(telemetryServiceProvider),
      isNot(isA<NoopTelemetryService>()),
    );
  });

  group("THE BETA-INERT TEST — SimCrux's side of the dark launch", () {
    // The beta is pinned, not defaulted: `kBetaPeriod` is false now, and
    // this group is what a beta build does with SimCrux's wiring.
    test('a beta build resolves the no-op service', () {
      final container = simcruxContainer(
        extra: [telemetryBetaPeriodProvider.overrideWithValue(true)],
      );
      expect(container.read(telemetryEnabledProvider), isFalse);
      expect(
        container.read(telemetryServiceProvider),
        isA<NoopTelemetryService>(),
      );
    });

    test('an explicit `enabled` consent does not override the beta gate', () {
      final container = simcruxContainer(
        extra: [telemetryBetaPeriodProvider.overrideWithValue(true)],
      );
      container.read(telemetryConsentStoreProvider.notifier).state =
          TelemetryConsentState.enabled;

      expect(container.read(telemetryEnabledProvider), isFalse);
      expect(
        container.read(telemetryServiceProvider),
        isA<NoopTelemetryService>(),
      );
    });

    testWidgets(
      'during beta with no dev flag, neither consent surface mounts',
      (tester) async {
        // The dark launch covers the UI too. A beta build must not show the
        // first-launch disclosure or the Settings → Privacy toggle: there is
        // nothing to consent to, and asking would advertise collection this
        // build is structurally incapable of doing.
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              cruxTelemetryConfigProvider.overrideWithValue(
                simcruxTelemetryConfig,
              ),
              telemetryStorageProvider.overrideWithValue(
                const SimcruxTelemetryStorage(),
              ),
              telemetryBetaPeriodProvider.overrideWithValue(true),
              telemetryDevModeProvider.overrideWithValue(false),
              telemetryHttpClientProvider.overrideWithValue(
                MockClient((_) async => http.Response('{}', 202)),
              ),
            ],
            child: MaterialApp(
              localizationsDelegates: L10N.localizationsDelegates,
              supportedLocales: L10N.supportedLocales,
              home: Builder(
                builder: (context) => ProviderScope(
                  overrides: [
                    cruxTelemetryStringsProvider.overrideWithValue(
                      SimcruxTelemetryStrings(L10N.of(context)),
                    ),
                  ],
                  child: const TelemetryConsentGate(child: SettingsScreen()),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(TelemetryConsentDisclosure), findsNothing);
        expect(find.text('Privacy'), findsNothing);
        expect(find.byKey(const Key('settingsTelemetrySwitch')), findsNothing);
      },
    );
  });

  group("SimCrux's envelope wiring", () {
    test('reports the simcrux slug and a Worker-legal envelope', () async {
      // The product slug is the one field `crux_telemetry` cannot supply, and
      // a slug the Worker does not know rejects every batch SimCrux ever
      // sends with a 400 the client never sees.
      final container = simcruxContainer(
        extra: [telemetryAppVersionProvider.overrideWith((_) async => '0.6.0')],
      );

      final envelope = await container.read(
        telemetryEnvelopeResolverProvider,
      )();

      expect(envelope, isNotNull);
      expect(envelope!.product, 'simcrux');
      expect(envelope.userAgent, 'SimCrux/0.6.0');
      expect(kTelemetryOperatingSystems, contains(envelope.os));
      expect(kTelemetryFormFactors, contains(envelope.formFactor));
      expect(kTelemetryLicenseTiers, contains(envelope.licenseTier));
      expect(
        kTelemetryInstallationIdPattern.hasMatch(envelope.installationId),
        isTrue,
      );
    });

    test(
      'the installation id persists under the suite-fixed prefs key',
      () async {
        final id = await simcruxContainer().read(
          telemetryInstallationIdProvider.future,
        );

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('telemetry.installationId'), id);
        expect(kTelemetryInstallationIdKey, 'telemetry.installationId');
      },
    );

    test('the consent decision persists under the suite-fixed prefs key', () {
      // The key `--ci` reads. It is fixed by the suite spec precisely so the
      // headless path and the GUI cannot drift onto two different keys, which
      // would silently make every `--ci` run read `unset`.
      expect(kTelemetryConsentKey, 'telemetry.consent');
    });

    test('the endpoint is the production suite ingest', () {
      // Not a dev build, so not the staging dataset. The path selects the
      // dataset; nothing SimCrux sends can move it.
      expect(
        simcruxContainer().read(telemetryEndpointProvider).toString(),
        'https://telemetry.edacrux.app/v1/events',
      );
    });
  });

  group('the seam itself', () {
    test('can be overridden with a recording fake', () {
      final recorder = RecordingTelemetryService();
      final container = ProviderContainer(
        overrides: [telemetryServiceProvider.overrideWithValue(recorder)],
      );
      addTearDown(container.dispose);

      container
          .read(telemetryServiceProvider)
          .record(TelemetryEvent('regression.cancelled'));

      expect(recorder.events, hasLength(1));
      expect(recorder.events.first.name, 'regression.cancelled');
    });
  });
}
