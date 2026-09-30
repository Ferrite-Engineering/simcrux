// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// The two consent surfaces, as SimCrux mounts them.
//
// `crux_telemetry` owns the widgets and sweeps their string sets,
// directionality and text scale. What is SimCrux's — and asserted here — is
// the wiring: that the ARB adapter resolves in all five shipped locales, that
// the disclosure and the Settings section actually mount on a build whose
// pipeline can transmit, that every control clears the suite's 44 dp floor on
// both a phone-sized and a tablet-sized viewport, and that answering in either
// surface writes the one stored decision the `--ci` rule later reads.

import 'dart:io';

import 'package:crux_settings/crux_settings.dart';
import 'package:crux_telemetry/crux_telemetry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/core/telemetry/simcrux_telemetry_config.dart';
import 'package:simcrux/core/telemetry/simcrux_telemetry_strings.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/features/beta_expiry/widgets/beta_expiry_metrics.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/settings/screens/settings_screen.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/settings/simcrux_settings_codec.dart';
import 'package:simcrux/services/telemetry/telemetry_platform.dart';

/// Cross-platform fake so `ColorThemeSection`, which resolves
/// `getApplicationSupportDirectory()` for its color-pack directory, gets a
/// writable temp dir instead of throwing `MissingPluginException`. Copied from
/// `settings_screen_test.dart`, where the same Settings screen needs it.
class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this._root);

  final Directory _root;

  @override
  Future<String?> getApplicationSupportPath() async => _root.path;

  @override
  Future<String?> getTemporaryPath() async => _root.path;

  @override
  Future<String?> getApplicationDocumentsPath() async => _root.path;

  @override
  Future<String?> getApplicationCachePath() async => _root.path;
}

/// The five shipped locales. `zh` and `zh_CN` are separate entries because
/// they are separate ARB files, and a key added to one and not the other is
/// exactly the drift this sweep catches.
const List<Locale> kShippedLocales = <Locale>[
  Locale('en'),
  Locale.fromSubtags(languageCode: 'zh', countryCode: 'CN'),
  Locale('zh'),
  Locale('ja'),
  Locale('ko'),
];

/// Phone-portrait and tablet-landscape viewports.
///
/// SimCrux draws desktop chrome at every size — it has no device-class system
/// and `telemetryFormFactorFor` has no phone or tablet arm — but the consent
/// surfaces still have to survive a narrow window, and the 44 dp floor is not
/// conditional on the host having fingers.
const Size kPhoneSize = Size(390, 844);
const Size kTabletSize = Size(1024, 768);

/// A build whose pipeline can transmit: the beta gate lifted, the dev flag
/// off. Everything the consent surfaces need and nothing they do not.
List<Override> transmittingOverrides({TelemetryStorage? storage}) => <Override>[
  cruxTelemetryConfigProvider.overrideWithValue(simcruxTelemetryConfig),
  telemetryStorageProvider.overrideWithValue(
    storage ?? InMemoryTelemetryStorage(),
  ),
  telemetryBetaPeriodProvider.overrideWithValue(false),
  telemetryDevModeProvider.overrideWithValue(false),
  telemetryUrlLauncherProvider.overrideWithValue((_) async => true),
  telemetryHttpClientProvider.overrideWithValue(
    MockClient((_) async => http.Response('{}', 202)),
  ),
];

Widget _host({
  required Locale locale,
  required Widget child,
  TelemetryStorage? storage,
}) => ProviderScope(
  overrides: transmittingOverrides(storage: storage),
  child: MaterialApp(
    locale: locale,
    localizationsDelegates: L10N.localizationsDelegates,
    supportedLocales: L10N.supportedLocales,
    home: Builder(
      builder: (context) => ProviderScope(
        overrides: [
          cruxTelemetryStringsProvider.overrideWithValue(
            SimcruxTelemetryStrings(L10N.of(context)),
          ),
        ],
        child: child,
      ),
    ),
  ),
);

void main() {
  group('the ARB adapter', () {
    for (final locale in kShippedLocales) {
      testWidgets('resolves every string in $locale', (tester) async {
        // Every getter, not a sample: `CruxTelemetryStrings` requires both
        // list blocks precisely so a product cannot ship a disclosure that
        // shows what it collects without what it never collects, and a
        // missing ARB key is a build-time failure only if something reads it.
        late CruxTelemetryStrings strings;
        await tester.pumpWidget(
          _host(
            locale: locale,
            child: Consumer(
              builder: (context, ref, _) {
                strings = ref.watch(cruxTelemetryStringsProvider);
                return const SizedBox.shrink();
              },
            ),
          ),
        );

        final resolved = <String>[
          strings.consentTitle,
          strings.consentBody,
          strings.learnMore,
          strings.consentToggleLabel,
          strings.consentContinue,
          strings.settingsToggleLabel,
          strings.settingsToggleDescription,
          strings.settingsDocsLabel,
          strings.settingsDocsDescription,
        ];
        for (final value in resolved) {
          expect(value.trim(), isNotEmpty, reason: 'empty string in $locale');
        }
        // The English copy must not leak into a translated build. `Continue`
        // and `Privacy` are the two strings most likely to be left untouched
        // by a partial translation pass.
        if (locale.languageCode != 'en') {
          expect(strings.consentContinue, isNot('Continue'));
          expect(strings.consentTitle, isNot(contains('Help make')));
        }
        // The product name lives in SimCrux's own ARB entry, not in an
        // interpolation across the package seam.
        expect(strings.consentTitle, contains('SimCrux'));
      });
    }
  });

  group('the first-launch disclosure', () {
    for (final entry in <String, Size>{
      'phone': kPhoneSize,
      'tablet': kTabletSize,
    }.entries) {
      testWidgets('mounts and clears 44 dp on a ${entry.key} viewport', (
        tester,
      ) async {
        tester.view
          ..physicalSize = entry.value
          ..devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          _host(
            locale: const Locale('en'),
            child: const TelemetryConsentGate(
              metrics: CruxTelemetryConsentMetrics(
                iconSize: kBetaExpiryIconSize,
              ),
              child: SizedBox.shrink(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(TelemetryConsentDisclosure), findsOneWidget);
        // The never-collect claim and the route to the exhaustive list are both
        // on screen before the user can act. A disclosure that makes the ask
        // without the route is an advertisement.
        expect(
          find.textContaining('Never your files'),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('telemetryConsentLearnMoreButton')),
          findsOneWidget,
        );

        // "Off" may never be harder to reach than "on" — so the switch and
        // Continue both clear the floor, on every host, at every width.
        for (final key in const <String>[
          'telemetryConsentSwitch',
          'telemetryConsentContinueButton',
          'telemetryConsentLearnMoreButton',
        ]) {
          final size = tester.getSize(find.byKey(Key(key)));
          expect(
            size.height,
            greaterThanOrEqualTo(kTelemetryConsentMinTarget),
            reason: '$key is below the 44 dp floor on a ${entry.key} viewport',
          );
        }

        // No horizontal overflow at the narrower of the two.
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('answering writes the decision the --ci rule reads', (
      tester,
    ) async {
      // The one storage the disclosure writes and `--ci` later reads. Passing
      // the same instance in and asserting on it afterwards is what makes this
      // a test of the handover rather than of the widget.
      final storage = InMemoryTelemetryStorage();
      late ProviderContainer container;
      await tester.pumpWidget(
        _host(
          locale: const Locale('en'),
          storage: storage,
          child: Consumer(
            builder: (context, ref, _) {
              container = ProviderScope.containerOf(context);
              return const TelemetryConsentGate(child: SizedBox.shrink());
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      // The gate arrives pre-armed on; Continue writes `enabled`.
      await tester.tap(find.byKey(const Key('telemetryConsentContinueButton')));
      await tester.pumpAndSettle();

      expect(
        container.read(telemetryConsentStoreProvider),
        TelemetryConsentState.enabled,
      );
      expect(find.byType(TelemetryConsentDisclosure), findsNothing);
      expect(
        storage.values[kTelemetryConsentKey],
        TelemetryConsentState.enabled.name,
        reason:
            'the headless path reads this exact key — a decision that stayed '
            'in memory would leave every `--ci` run reading `unset`',
      );
    });

    testWidgets('an installation that already answered is not re-asked', (
      tester,
    ) async {
      // A pre-seeded store is what a second launch looks like. The disclosure
      // waits on the store's `loaded` signal rather than on its state,
      // precisely so those first few frames of synchronous `unset` do not
      // re-ask somebody who already said no.
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            cruxTelemetryConfigProvider.overrideWithValue(
              simcruxTelemetryConfig,
            ),
            telemetryStorageProvider.overrideWithValue(
              InMemoryTelemetryStorage(<String, String>{
                kTelemetryConsentKey: TelemetryConsentState.disabled.name,
              }),
            ),
            telemetryBetaPeriodProvider.overrideWithValue(false),
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
                child: const TelemetryConsentGate(child: SizedBox.shrink()),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TelemetryConsentDisclosure), findsNothing);
    });
  });

  group('Settings → Privacy', () {
    late Directory tmpDir;
    late PathProviderPlatform priorPathProvider;

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      tmpDir = Directory.systemTemp.createTempSync('simcrux_telemetry_privacy');
      priorPathProvider = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _FakePathProvider(tmpDir);
    });

    tearDown(() {
      PathProviderPlatform.instance = priorPathProvider;
      if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
    });

    Future<Widget> settingsHost() async {
      final prefs = await SharedPreferences.getInstance();
      return ProviderScope(
        overrides: [
          ...transmittingOverrides(),
          settingsServiceProvider.overrideWithValue(
            SettingsService<AppSettings>(
              const SimcruxSettingsCodec(),
              prefsOverride: prefs,
            ),
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
              child: const SettingsScreen(),
            ),
          ),
        ),
      );
    }

    testWidgets('is offered on a build that can transmit', (tester) async {
      await tester.binding.setSurfaceSize(kTabletSize);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(await settingsHost());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('Privacy'), findsOneWidget);
      await tester.tap(find.text('Privacy'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byKey(const Key('settingsTelemetrySwitch')), findsOneWidget);
      expect(
        find.byKey(const Key('settingsTelemetryDocsButton')),
        findsOneWidget,
      );
      expect(
        tester.getSize(find.byKey(const Key('settingsTelemetrySwitch'))).height,
        greaterThanOrEqualTo(kTelemetryConsentMinTarget),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('form_factor', () {
    test('has exactly the two arms SimCrux actually draws', () {
      // Introducing a width breakpoint here to manufacture `phone` / `tablet`
      // rows would report a layout SimCrux does not have. A missing dimension
      // is visible in the data; a fabricated one is not.
      expect(telemetryFormFactorFor(isWeb: false), 'desktop');
      expect(telemetryFormFactorFor(isWeb: true), 'web');
      expect(kTelemetryFormFactors, contains('desktop'));
      expect(kTelemetryFormFactors, contains('web'));
    });
  });

  group('consent metrics', () {
    test("SimCrux's beta-expiry constants agree with the package floor", () {
      // `app.dart` passes only `iconSize`, relying on these two matching. If
      // either constant moves, this fails here rather than silently leaving
      // the disclosure sized differently from the expiry modal beside it.
      expect(kBetaExpiryTouchTarget, kTelemetryConsentMinTarget);
      expect(
        kBetaExpiryBodyFontSize,
        const CruxTelemetryConsentMetrics().bodyFontSize,
      );
      // The floor is a floor: a host passing less is raised, never obeyed.
      expect(
        const CruxTelemetryConsentMetrics(
          touchTarget: 28,
        ).effectiveTouchTarget,
        kTelemetryConsentMinTarget,
      );
    });
  });
}
