// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// THE `--ci` RULE.
//
// A headless SimCrux run transmits only when the GUI on the same machine has
// stored an affirmative consent. `unset` transmits nothing and never prompts:
// a CI job must never block on a dialog, nor be treated as consenting by
// silence.
//
// The three end-to-end cases the rule implies are at the bottom of this
// file and drive the real `bootstrap(args: ['--ci', …])` path, because the
// thing being asserted is a property of that path and not of a helper. The
// matrix above them exercises the gate directly, where every cell is cheap.

import 'dart:io' as io;

import 'package:crux_telemetry/crux_telemetry.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/app.dart';
import 'package:simcrux/core/telemetry/simcrux_telemetry_config.dart';
import 'package:simcrux/domain/enums/hdl_language.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/services/job_scheduler/job_scheduler_provider.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';
import 'package:simcrux/services/telemetry/headless_telemetry.dart';

import '../../support/recording_telemetry_service.dart';

/// A container shaped like the transient one `bootstrap`'s headless branches
/// build, seeded with a stored consent value.
ProviderContainer headlessContainer({
  TelemetryConsentState? stored,
  bool beta = false,
  bool dev = false,
  List<Override> extra = const [],
}) {
  final container = ProviderContainer(
    overrides: [
      cruxTelemetryConfigProvider.overrideWithValue(simcruxTelemetryConfig),
      telemetryStorageProvider.overrideWithValue(
        InMemoryTelemetryStorage(<String, String>{
          if (stored != null) kTelemetryConsentKey: stored.name,
        }),
      ),
      telemetryBetaPeriodProvider.overrideWithValue(beta),
      telemetryDevModeProvider.overrideWithValue(dev),
      telemetryHttpClientProvider.overrideWithValue(
        MockClient((_) async => http.Response('{}', 202)),
      ),
      ...extra,
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the headless gate', () {
    test('an unanswered installation transmits nothing', () async {
      // Silence is not consent, and the one place a "collect unless told
      // otherwise" default would be least visible is a machine whose user
      // never opened the app.
      final container = headlessContainer();
      expect(await headlessTelemetryAllowed(container), isFalse);
      expect(
        await resolveHeadlessTelemetry(container),
        isA<NoopTelemetryService>(),
      );
    });

    test('an explicit `disabled` transmits nothing', () async {
      final container = headlessContainer(
        stored: TelemetryConsentState.disabled,
      );
      expect(await headlessTelemetryAllowed(container), isFalse);
    });

    test('an explicit `enabled` transmits', () async {
      final container = headlessContainer(
        stored: TelemetryConsentState.enabled,
      );
      expect(await headlessTelemetryAllowed(container), isTrue);
      expect(
        await resolveHeadlessTelemetry(container),
        isA<LiveTelemetryService>(),
      );
    });

    test('the beta gate still wins over a stored `enabled`', () async {
      // The dark launch is not a consent question. A beta build transmits
      // nothing from any path, headless included.
      final container = headlessContainer(
        stored: TelemetryConsentState.enabled,
        beta: true,
      );
      expect(await headlessTelemetryAllowed(container), isFalse);
    });

    test('TELEMETRY_DEV does NOT make `unset` count as consent here', () async {
      // This is where the headless gate deliberately diverges from
      // `telemetryEnabledProvider`, which treats `unset` as enabled under the
      // dev flag so a developer can verify the pipeline without touching the
      // UI. On a headless path there is no UI to have skipped, and no one to
      // have skipped it — so `unset` stays a hard no.
      final container = headlessContainer(beta: true, dev: true);
      // Once the store has settled — the GUI gate promotes `unset` under the
      // dev flag only after the persisted value has been read back, since
      // before that a stored refusal wears the same value.
      await container.read(telemetryConsentReadyProvider.future);
      expect(container.read(telemetryEnabledProvider), isTrue);
      expect(await headlessTelemetryAllowed(container), isFalse);
    });

    test(
      'TELEMETRY_DEV in headless still routes to the dev endpoint',
      () async {
        // What the dev flag *does* still do on this path: select the dataset.
        // A consenting `TELEMETRY_DEV` build posts to staging exactly as a GUI
        // one does, so end-to-end verification covers `--ci` too.
        final container = headlessContainer(
          stored: TelemetryConsentState.enabled,
          beta: true,
          dev: true,
        );
        expect(await headlessTelemetryAllowed(container), isTrue);
        expect(
          container.read(telemetryEndpointProvider).toString(),
          'https://telemetry.edacrux.app/dev/v1/events',
        );
        expect(
          headlessContainer(
            stored: TelemetryConsentState.enabled,
          ).read(telemetryEndpointProvider).toString(),
          'https://telemetry.edacrux.app/v1/events',
          reason: 'without the dev flag the same consent posts to production',
        );
      },
    );

    test('the consent read waits for the store to load', () async {
      // The regression this guards: `TelemetryConsentStore` publishes `unset`
      // synchronously and loads asynchronously. A GUI reads it again next
      // frame; a CLI process has no next frame. Reading without awaiting
      // `telemetryConsentReadyProvider` would report `unset` on every headless
      // run — a consent rule that always answered "no" looks exactly like one
      // that works.
      final container = headlessContainer(
        stored: TelemetryConsentState.enabled,
      );
      expect(
        container.read(telemetryConsentStoreProvider),
        TelemetryConsentState.unset,
        reason: 'the synchronous read is the trap this test exists for',
      );
      expect(await headlessTelemetryAllowed(container), isTrue);
    });
  });

  group('`simcrux --ci` end to end', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test(
      'with consent `unset`: zero HTTP requests leave the process',
      () async {
        final requests = <http.BaseRequest>[];
        final configPath = await _writeConfig();
        final saved = io.exitCode;
        addTearDown(() => io.exitCode = saved);

        await bootstrap(
          args: ['--ci', configPath],
          extraOverrides: [
            ..._scriptedDriver,
            // Beta off and dev off: the *only* thing standing between this run
            // and the network is the stored consent.
            telemetryBetaPeriodProvider.overrideWithValue(false),
            telemetryDevModeProvider.overrideWithValue(false),
            telemetryHttpClientProvider.overrideWithValue(
              MockClient((request) async {
                requests.add(request);
                return http.Response('{}', 202);
              }),
            ),
          ],
        );

        expect(
          requests,
          isEmpty,
          reason:
              'an unanswered machine must issue no ingest request at all — not '
              'an empty one, not a probe. The live service is never even '
              'constructed, which is what also guarantees no dialog and no '
              'six-hour timer.',
        );
      },
    );

    test('with consent `enabled`: the run queues its counters', () async {
      // SharedPreferences is what the GUI wrote its answer into, and it is
      // what the headless path reads — the same key, through the same adapter.
      // That is the whole mechanism: `--ci` reads the GUI's decision rather
      // than making one of its own.
      SharedPreferences.setMockInitialValues(<String, Object>{
        kTelemetryConsentKey: TelemetryConsentState.enabled.name,
      });
      final recorder = RecordingTelemetryService();
      final configPath = await _writeConfig();
      final saved = io.exitCode;
      addTearDown(() => io.exitCode = saved);

      await bootstrap(
        args: ['--ci', configPath],
        extraOverrides: [
          ..._scriptedDriver,
          // No storage override: `simcruxTelemetryOverrides` already binds
          // `SimcruxTelemetryStorage`, and that is the point — the value read
          // here is the one the seeded `SharedPreferences` above holds, which
          // is where the GUI writes. (Riverpod asserts on a duplicate override
          // in one container, so re-binding it would fail loudly rather than
          // shadow it.)
          telemetryBetaPeriodProvider.overrideWithValue(false),
          telemetryDevModeProvider.overrideWithValue(false),
          telemetryServiceProvider.overrideWithValue(recorder),
        ],
      );

      final completed = recorder.named('regression.completed');
      expect(completed, hasLength(1));
      expect(completed.single.properties['trigger'], 'ci');
      expect(completed.single.properties['simulator'], 'icarus');
      expect(completed.single.properties['tests'], 1);
      expect(completed.single.properties['failed'], 1);
      expect(
        recorder.named('detector.matched').single.properties['kind'],
        'exit_code',
      );
    });
  });
}

/// The scripted driver from `app_ci_driver_injection_test.dart`, registered as
/// `icarus` so the run resolves without a toolchain on the host.
final List<Override> _scriptedDriver = <Override>[
  simulatorDriverRegistryProvider.overrideWithValue(
    SimulatorDriverRegistry({'icarus': _FixedOutcomeDriver()}),
  ),
];

class _FixedOutcomeDriver implements SimulatorDriver {
  @override
  String get id => 'icarus';

  @override
  String get displayName => 'Fixed (telemetry --ci test)';

  @override
  SimulatorCapabilities get capabilities => SimulatorCapabilities(
    supportedLanguages: const {HdlLanguage.verilog},
    supportsVcd: false,
    supportsFst: false,
    supportsCocotb: false,
    requiresSeparateCompileStep: false,
    emitsStructuredOutput: false,
  );

  @override
  Future<String?> detectVersion(SimulatorBinaryConfig config) async => 'fixed';

  @override
  Future<CompileResult> compile(CompileRequest request) async =>
      const CompileResult(
        success: true,
        artifactPath: 'noop',
        stdout: '',
        stderr: '',
      );

  @override
  Stream<TestExecutionEvent> execute(ExecuteRequest request) async* {
    final now = DateTime.now().toUtc();
    yield TestExecutionFinished(
      status: TestStatus.fail,
      exitCode: 1,
      startedAt: now,
      finishedAt: now.add(const Duration(milliseconds: 1)),
    );
  }

  @override
  void cancel(String testId) {}
}

Future<String> _writeConfig() async {
  final dir = await io.Directory.systemTemp.createTemp('simcrux_ci_telemetry_');
  addTearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });
  io.File('${dir.path}/tb.v').writeAsStringSync('module tb; endmodule\n');
  io.File('${dir.path}/simcrux.yaml').writeAsStringSync(
    "version: '1'\n"
    '\n'
    'defaults:\n'
    '  simulator: icarus\n'
    '  pass_fail:\n'
    '    type: exit_code\n'
    '  waveform:\n'
    '    capture: never\n'
    '\n'
    'suites:\n'
    '  smoke:\n'
    '    description: telemetry ci seam\n'
    '    tests:\n'
    '      - name: alu\n'
    '        top: tb\n'
    '        sources:\n'
    '          - tb.v\n',
  );
  return '${dir.path}/simcrux.yaml';
}
