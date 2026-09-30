// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// Opening a config arms the tab; it does not run it — see the notes above
/// `main`.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/features/config/providers/config_loader_provider.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/dashboard/providers/regression_runner.dart';
import 'package:simcrux/services/config/config_loader.dart';
import 'package:simcrux/services/result_store/result_store_provider.dart';

import '../../../support/answered_telemetry.dart';

/// Opening a regression config used to start the whole regression, with no
/// user action. **That is unintended:** opening a
/// file must not launch two hundred tests, and in a real setup it also checks
/// out simulator licences on a misclick. The behaviour now sits behind
/// `AppSettings.autoRunOnOpen`, default **off**; opening a config leaves the
/// tab *armed* — config published, dashboard and watcher live, scheduler idle.
///
/// These pin both directions at the seam the decision lives at,
/// `RegressionRunner.startFromConfigPath(autoStart:)`. That the *open* path
/// passes the user's preference rather than a constant is
/// `regression_tab_content.dart`'s job; the setting's persistence is pinned in
/// `test/services/settings/simcrux_settings_codec_test.dart`.
const _yaml = '''
version: "1"

defaults:
  simulator: icarus
  timeout: 300s
  pass_fail:
    type: exit_code

suites:
  smoke:
    sources:
      - tb/t1.v
      - tb/t2.v
    tests:
      - name: t1
        top: tb_t1
      - name: t2
        top: tb_t2
''';

void main() {
  ProviderContainer newContainer() {
    final container = ProviderContainer(
      overrides: [
        ...answeredTelemetryOverrides(),
        configLoaderProvider.overrideWithValue(
          ConfigLoader(readFile: (_) async => _yaml),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('opening a config with autoRunOnOpen off', () {
    test('publishes the config so the tab is armed', () async {
      final container = newContainer();

      await container
          .read(regressionRunnerProvider.notifier)
          .startFromConfigPath('/p/simcrux.yaml', autoStart: false);

      final config = container.read(activeConfigProvider);
      expect(config, isNotNull);
      expect(config!.suites.single.tests, hasLength(2));
    });

    test('starts no run', () async {
      final container = newContainer();

      await container
          .read(regressionRunnerProvider.notifier)
          .startFromConfigPath('/p/simcrux.yaml', autoStart: false);

      expect(
        container.read(regressionRunnerProvider).value,
        isNull,
        reason: 'No run state means no run — the tab is armed, not running.',
      );
      expect(
        container.read(resultStoreProvider),
        isNull,
        reason:
            'A published result store is the observable trace of a submitted '
            'run; opening a file must leave none.',
      );
    });

    test('clears a previous load error', () async {
      final container = newContainer();
      container
          .read(configLoadErrorProvider.notifier)
          .record(
            const ConfigLoadError(path: '/p/old.yaml', message: 'boom'),
          );

      await container
          .read(regressionRunnerProvider.notifier)
          .startFromConfigPath('/p/simcrux.yaml', autoStart: false);

      expect(container.read(configLoadErrorProvider), isNull);
    });

    test('still reports a config that will not parse', () async {
      // Arming is not an excuse to swallow a broken file: the tab has to be
      // able to render "couldn't load <path>" whether or not a run follows.
      final container = ProviderContainer(
        overrides: [
          ...answeredTelemetryOverrides(),
          configLoaderProvider.overrideWithValue(
            ConfigLoader(readFile: (_) async => '{{ not yaml'),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(regressionRunnerProvider.notifier)
          .startFromConfigPath('/p/broken.yaml', autoStart: false);

      expect(container.read(regressionRunnerProvider), isA<AsyncError<void>>());
      expect(container.read(configLoadErrorProvider), isNotNull);
      expect(
        container.read(configLoadErrorProvider)!.path,
        '/p/broken.yaml',
      );
    });
  });

  group('opening a config with autoRunOnOpen on', () {
    // `autoStart` defaults to true, so the opted-in path is the plain call.
    test('publishes the config and submits a run', () async {
      final container = newContainer();

      await container
          .read(regressionRunnerProvider.notifier)
          .startFromConfigPath('/p/simcrux.yaml');

      expect(container.read(activeConfigProvider), isNotNull);
      expect(
        container.read(regressionRunnerProvider).value,
        isNotNull,
        reason: 'Opting in must still start the regression.',
      );
      expect(container.read(resultStoreProvider), isNotNull);

      await container.read(regressionRunnerProvider.notifier).cancel();
    });

    test('an explicit autoStart: false is what turns it off', () async {
      final container = newContainer();

      await container
          .read(regressionRunnerProvider.notifier)
          .startFromConfigPath('/p/simcrux.yaml', autoStart: false);

      expect(container.read(regressionRunnerProvider).value, isNull);
    });
  });

  group('a tab closed while the config load is in flight', () {
    // The load is awaited, so the notifier can be disposed underneath it —
    // closing the tab right after an auto-reload fired, or during a slow read
    // off a network share. Both legs of `startFromConfigPath` touch `ref`
    // after that await (the error-banner clear and the state assignment on the
    // way out; the error record and `AsyncError` on the way out of the catch),
    // and either throws "Cannot use the Ref … after it has been disposed" on a
    // dead element. The work is moot once the tab is gone, so it is dropped.
    ProviderContainer blockedOn(Future<String> gate) {
      final container = ProviderContainer(
        overrides: [
          ...answeredTelemetryOverrides(),
          configLoaderProvider.overrideWithValue(
            ConfigLoader(readFile: (_) async => gate),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test(
      'a load that succeeds after disposal is dropped, not thrown',
      () async {
        final gate = Completer<String>();
        final container = blockedOn(gate.future);

        final pending = container
            .read(regressionRunnerProvider.notifier)
            .startFromConfigPath('/p/simcrux.yaml', autoStart: false);
        container.dispose();
        gate.complete(_yaml);

        await expectLater(pending, completes);
      },
    );

    test('a load that fails after disposal is dropped, not thrown', () async {
      final gate = Completer<String>();
      final container = blockedOn(gate.future);

      final pending = container
          .read(regressionRunnerProvider.notifier)
          .startFromConfigPath('/p/simcrux.yaml', autoStart: false);
      container.dispose();
      gate.completeError(const FileSystemException('gone'));

      await expectLater(pending, completes);
    });
  });

  group('arm', () {
    test('publishes the config without a run', () async {
      final container = newContainer();
      final config = await ConfigLoader(
        readFile: (_) async => _yaml,
      ).load('/p/simcrux.yaml');

      container.read(regressionRunnerProvider.notifier).arm(config);

      expect(container.read(activeConfigProvider), same(config));
      expect(container.read(regressionRunnerProvider).value, isNull);
      expect(container.read(resultStoreProvider), isNull);
    });
  });
}
