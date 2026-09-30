// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

import 'package:crux_app_info/crux_app_info.dart';
import 'package:crux_updates/crux_updates.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/core/update/simcrux_update_config.dart';
import 'package:simcrux/features/update/providers/observed_server_time_provider.dart';

/// Drives the real `crux_updates` provider graph against a scripted manifest
/// response, wired exactly as SimCrux wires it. This is the state-machine
/// contract test: launch check, periodic gating, the auto-check toggle, the
/// manual override, failure handling, and the `server_time` watermark.
///
/// `simcruxUpdateOverrides` itself is not reused here because two of its
/// bindings reach platform plugins (`PackageInfo.fromPlatform`, `launchUrl`);
/// the *pairing* those overrides express is asserted separately in
/// `beta_expiry_clock_tampering_test.dart`.
const _runningVersion = '1.0.0';

String _manifest({
  String version = '2.0.0',
  bool mandatory = false,
  String? minSupported,
  String? serverTime,
}) => jsonEncode({
  'latest': {
    'version': version,
    'channel': 'stable',
    'mandatory': mandatory,
    'min_supported_version': ?minSupported,
    'server_time': ?serverTime,
  },
});

ProviderContainer _container({
  required http.Client client,
  bool autoCheckEnabled = true,
  List<Override> extra = const [],
}) {
  final container = ProviderContainer(
    overrides: [
      cruxUpdateConfigProvider.overrideWithValue(simcruxUpdateConfig),
      updateBuildInfoProvider.overrideWith(
        (ref) async => const ApplicationBuildInfo(
          version: _runningVersion,
          buildNumber: '1',
          gitShortSha: 'deadbee',
          os: 'macOS 15.0',
          architecture: 'arm64',
          flutterSdkVersion: '3.44.2',
          dartSdkVersion: '3.12.2',
        ),
      ),
      autoUpdateCheckEnabledProvider.overrideWith(
        (ref) async => autoCheckEnabled,
      ),
      updateHttpClientProvider.overrideWithValue(client),
      observedServerTimeSinkProvider.overrideWith(
        (ref) =>
            (t) => ref.read(observedServerTimeStoreProvider.notifier).record(t),
      ),
      ...extra,
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Lets the launch check (build-info future → fetch → state publish) settle.
Future<void> _settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Materializes `updateStatusProvider` (which fires the launch check on
/// creation), lets it settle, and returns the resulting status.
Future<UpdateStatus> _launchAndSettle(ProviderContainer container) async {
  container.read(updateStatusProvider);
  await _settle();
  return await container.read(updateStatusProvider);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // `flutter_test` reports `defaultTargetPlatform == android`, and
    // `updateCheckServiceProvider` deliberately substitutes
    // `NoopUpdateCheckService` on iOS/Android unless `checkOnMobile` is set —
    // so without this the whole suite would assert against a stubbed-out
    // service. SimCrux only ever runs on desktop/web; pin the platform to
    // match.
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  });

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  group('update status state machine', () {
    test('LAUNCH: a newer manifest version surfaces as available', () async {
      final container = _container(
        client: MockClient((_) async => http.Response(_manifest(), 200)),
      );
      final status = await _launchAndSettle(container);
      expect(status, isA<UpdateStatusAvailable>());
      expect((status as UpdateStatusAvailable).info.version, '2.0.0');
    });

    test('LAUNCH: the same version resolves to current', () async {
      final container = _container(
        client: MockClient(
          (_) async => http.Response(_manifest(version: _runningVersion), 200),
        ),
      );
      expect(await _launchAndSettle(container), isA<UpdateStatusCurrent>());
    });

    test('TOGGLE OFF suppresses the launch (scheduled) check', () async {
      var requests = 0;
      final container = _container(
        autoCheckEnabled: false,
        client: MockClient((_) async {
          requests++;
          return http.Response(_manifest(), 200);
        }),
      );
      final status = await _launchAndSettle(container);

      expect(requests, 0, reason: 'auto-check disabled must issue no fetch');
      expect(status, isA<UpdateStatusCurrent>());
    });

    test('TOGGLE OFF also suppresses an explicit scheduled re-check', () async {
      var requests = 0;
      final container = _container(
        autoCheckEnabled: false,
        client: MockClient((_) async {
          requests++;
          return http.Response(_manifest(), 200);
        }),
      );
      await container.read(updateStatusProvider.notifier).runScheduledCheck();
      await _settle();

      expect(requests, 0);
    });

    test('MANUAL: checkNow runs even with auto-check disabled', () async {
      var requests = 0;
      final container = _container(
        autoCheckEnabled: false,
        client: MockClient((_) async {
          requests++;
          return http.Response(_manifest(), 200);
        }),
      );
      await container.read(updateStatusProvider.notifier).checkNow();
      await _settle();

      expect(requests, 1, reason: 'a manual check always runs');
      expect(
        container.read(updateStatusProvider),
        isA<UpdateStatusAvailable>(),
      );
    });

    test(
      'a failed fetch resolves to error, never a thrown exception',
      () async {
        final container = _container(
          client: MockClient((_) async => http.Response('nope', 500)),
        );
        await container.read(updateStatusProvider.notifier).checkNow();
        await _settle();

        expect(container.read(updateStatusProvider), isA<UpdateStatusError>());
      },
    );

    test('a malformed manifest resolves to error, not a crash', () async {
      final container = _container(
        client: MockClient((_) async => http.Response('{ not json', 200)),
      );
      await container.read(updateStatusProvider.notifier).checkNow();
      await _settle();

      expect(container.read(updateStatusProvider), isA<UpdateStatusError>());
    });

    test('a build below min_supported_version is forced mandatory', () async {
      final container = _container(
        client: MockClient(
          (_) async => http.Response(
            _manifest(minSupported: '1.5.0'),
            200,
          ),
        ),
      );
      await container.read(updateStatusProvider.notifier).checkNow();
      await _settle();

      final status = container.read(updateStatusProvider);
      expect(status, isA<UpdateStatusAvailable>());
      expect(
        (status as UpdateStatusAvailable).info.mandatory,
        isTrue,
        reason: 'a build below the floor is no longer supported',
      );
    });

    test('server_time is recorded into the persisted watermark', () async {
      final container = _container(
        client: MockClient(
          (_) async => http.Response(
            _manifest(serverTime: '2026-09-15T12:00:00Z'),
            200,
          ),
        ),
      );
      await container.read(updateStatusProvider.notifier).checkNow();
      await _settle();

      expect(
        container.read(observedServerTimeStoreProvider),
        DateTime.utc(2026, 9, 15, 12),
      );
    });

    test(
      'server_time is recorded even when the running build is already current',
      () async {
        final container = _container(
          client: MockClient(
            (_) async => http.Response(
              _manifest(
                version: _runningVersion,
                serverTime: '2026-09-15T12:00:00Z',
              ),
              200,
            ),
          ),
        );
        await container.read(updateStatusProvider.notifier).checkNow();
        await _settle();

        expect(
          container.read(updateStatusProvider),
          isA<UpdateStatusCurrent>(),
        );
        expect(
          container.read(observedServerTimeStoreProvider),
          DateTime.utc(2026, 9, 15, 12),
          reason:
              'the watermark must advance on every successful fetch, not '
              'only when an update exists — beta expiry depends on it',
        );
      },
    );

    test('the manifest fetch targets the SimCrux endpoint', () async {
      Uri? requested;
      final container = _container(
        client: MockClient((request) async {
          requested = request.url;
          return http.Response(_manifest(), 200);
        }),
      );
      await container.read(updateStatusProvider.notifier).checkNow();
      await _settle();

      expect(requested, simcruxUpdateConfig.manifestUri);
    });

    test(
      'the fetch sends no payload beyond a product/version User-Agent',
      () async {
        http.BaseRequest? seen;
        final container = _container(
          client: MockClient((request) async {
            seen = request;
            return http.Response(_manifest(), 200);
          }),
        );
        await container.read(updateStatusProvider.notifier).checkNow();
        await _settle();

        expect(seen?.method, 'GET');
        expect(seen?.contentLength ?? 0, 0);
        final ua = seen?.headers['User-Agent'] ?? seen?.headers['user-agent'];
        expect(ua, contains('SimCrux'));
        expect(ua, contains(_runningVersion));
      },
    );
  });
}
