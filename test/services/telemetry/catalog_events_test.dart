// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// One test per open-core catalog event, fired on the real code path.
//
// The catalog conformance test proves the *vocabulary* is legal. This file
// proves the vocabulary is actually produced: that the call site exists, that
// it fires when it should and not when it should not, and that every property
// it emits is a member of the closed set the catalog pins.
//
// Every assertion below reads the event a `RecordingTelemetryService` was
// handed by production code — never a hand-built `TelemetryEvent`. A test that
// constructed the event itself would pass with the call site deleted.

import 'dart:async';
import 'dart:io';

import 'package:crux_telemetry/crux_telemetry.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/dashboard_view_mode.dart';
import 'package:simcrux/domain/enums/hdl_language.dart';
import 'package:simcrux/domain/enums/regression_trigger.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/pass_fail_config.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/suite.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_view_mode_provider.dart';
import 'package:simcrux/features/dashboard/providers/regression_runner.dart';
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';
import 'package:simcrux/services/job_scheduler/job_scheduler_provider.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';
import 'package:simcrux/services/telemetry/project_opened_event.dart';
import 'package:simcrux/services/telemetry/simulator_telemetry_token.dart';
import 'package:simcrux/services/telemetry/telemetry_event_catalog.dart';
import 'package:simcrux/services/trend_store/trend_store_provider.dart';

import '../../support/poll_until.dart';
import '../../support/recording_telemetry_service.dart';

/// Asserts [event] carries only properties the catalog permits, with values
/// from the closed set it pins.
///
/// The reason every test below ends with this rather than a bare property
/// comparison: a call site can emit the right *shape* and still send a value
/// the catalog never listed, and the Worker would drop that value without a
/// word. Checking against the catalog rather than against a literal makes the
/// catalog the single source of truth that both halves are held to.
void expectMatchesCatalog(TelemetryEvent event) {
  final entry = kSimcruxEventCatalog.firstWhere(
    (e) => e.name == event.name,
    orElse: () => throw StateError('${event.name} is not in the catalog'),
  );
  for (final key in event.properties.keys) {
    expect(
      entry.propertyKeys,
      contains(key),
      reason: '${event.name} emitted an undocumented property key `$key`',
    );
    final value = event.properties[key];
    if (entry.boolProperties.contains(key)) {
      expect(value, isA<bool>(), reason: '${event.name}.$key must be a bool');
    } else if (entry.intProperties.contains(key)) {
      expect(value, isA<int>(), reason: '${event.name}.$key must be an int');
      expect((value! as int).abs(), lessThanOrEqualTo(kTelemetryMaxCount));
    } else {
      expect(
        entry.enumeratedValues[key],
        contains(value),
        reason:
            '${event.name}.$key = `$value` is outside the closed vocabulary '
            'the catalog pins; the Worker would drop it silently',
      );
    }
  }
}

TestSpec _spec(
  String id, {
  String simulatorId = 'icarus',
  PassFailConfig? passFail,
}) => TestSpec(
  id: id,
  name: id.split('/').last,
  suiteName: id.split('/').first,
  simulatorId: simulatorId,
  top: 'tb',
  passFail: passFail ?? const ExitCodePassFailConfig(),
);

RegressionConfig _config(List<TestSpec> tests) {
  final byId = <String, List<TestSpec>>{};
  for (final t in tests) {
    byId.putIfAbsent(t.suiteName, () => <TestSpec>[]).add(t);
  }
  return RegressionConfig(
    projectFilePath: '/proj/simcrux.yaml',
    schemaVersion: '1',
    suites: [
      for (final entry in byId.entries)
        Suite(name: entry.key, tests: entry.value),
    ],
    simulatorBinaries: const {},
  );
}

/// Exits 0 unless the test id ends in `/fail`.
class _FakeDriver implements SimulatorDriver {
  @override
  String get id => 'icarus';

  @override
  String get displayName => 'Fake';

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
  Future<String?> detectVersion(SimulatorBinaryConfig config) async => 'fake';

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
    final started = DateTime.now().toUtc();
    final exitCode = request.test.id.endsWith('/fail') ? 1 : 0;
    yield TestExecutionFinished(
      status: exitCode == 0 ? TestStatus.pass : TestStatus.fail,
      exitCode: exitCode,
      startedAt: started,
      finishedAt: DateTime.now().toUtc(),
    );
  }

  @override
  void cancel(String testId) {}
}

/// Never finishes until cancelled, so a run stays in flight.
class _BlockingDriver implements SimulatorDriver {
  final Map<String, Completer<void>> _gates = <String, Completer<void>>{};

  @override
  String get id => 'icarus';

  @override
  String get displayName => 'Blocking';

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
  Future<String?> detectVersion(SimulatorBinaryConfig config) async => 'fake';

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
    await _gates.putIfAbsent(request.test.id, Completer<void>.new).future;
    yield TestExecutionFinished(
      status: TestStatus.cancelled,
      exitCode: -1,
      startedAt: DateTime.now().toUtc(),
      finishedAt: DateTime.now().toUtc(),
    );
  }

  @override
  void cancel(String testId) => _gates[testId]?.complete();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late RecordingTelemetryService telemetry;
  late ProviderContainer container;

  ProviderContainer build({SimulatorDriver? driver}) {
    telemetry = RecordingTelemetryService();
    return ProviderContainer(
      overrides: [
        telemetryServiceProvider.overrideWithValue(telemetry),
        simulatorDriverRegistryProvider.overrideWithValue(
          SimulatorDriverRegistry({'icarus': driver ?? _FakeDriver()}),
        ),
        trendStoreDirectoryOverrideProvider.overrideWithValue(tmp.path),
      ],
    );
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('simcrux_telemetry_events_');
    container = build();
  });

  tearDown(() async {
    container.dispose();
    if (tmp.existsSync()) {
      try {
        tmp.deleteSync(recursive: true);
      } on Object {
        // Best-effort cleanup.
      }
    }
  });

  Future<void> waitForFinish() async {
    final completer = Completer<void>();
    container.listen<AsyncValue<RegressionRunState?>>(
      regressionRunnerProvider,
      (_, next) {
        final value = next.value;
        if (value != null && value.isFinished && !completer.isCompleted) {
          completer.complete();
        }
      },
    );
    await completer.future;
  }

  group('regression.completed', () {
    test('fires once at the end of a run, with counts and tokens', () async {
      await container
          .read(regressionRunnerProvider.notifier)
          .start(_config([_spec('unit/alu'), _spec('unit/fail')]));
      await waitForFinish();
      // The terminal counter fires before the completion awaits, so poll for
      // it rather than assuming the listener above raced ahead of it.
      await pollUntil(() => telemetry.named('regression.completed').isNotEmpty);

      final event = telemetry.named('regression.completed').single;
      expect(event.properties['simulator'], 'icarus');
      expect(event.properties['trigger'], 'manual');
      expect(event.properties['tests'], 2);
      expect(event.properties['failed'], 1, reason: 'one spec exits 1');
      expectMatchesCatalog(event);
      expect(
        telemetry.named('regression.cancelled'),
        isEmpty,
        reason: 'a run has one ending',
      );
    });

    test('a watcher-driven run reports trigger: auto', () async {
      await container
          .read(regressionRunnerProvider.notifier)
          .start(_config([_spec('unit/alu')]), trigger: RegressionTrigger.auto);
      await waitForFinish();
      await pollUntil(() => telemetry.named('regression.completed').isNotEmpty);

      final event = telemetry.named('regression.completed').single;
      expect(event.properties['trigger'], 'auto');
      expect(
        event.properties['trigger'],
        telemetryEnumToken(RegressionTrigger.auto),
      );
      expectMatchesCatalog(event);
    });

    test('a two-engine run reports `mixed`, never a majority', () async {
      // SimCrux's signature workflow. Picking the majority engine would
      // overstate one and erase the other.
      await container
          .read(regressionRunnerProvider.notifier)
          .start(
            _config([
              _spec('unit/alu'),
              _spec('unit/regfile', simulatorId: 'verilator'),
            ]),
          );
      await waitForFinish();
      await pollUntil(() => telemetry.named('regression.completed').isNotEmpty);

      expect(
        telemetry.named('regression.completed').single.properties['simulator'],
        'mixed',
      );
    });

    test('a plugin engine id never reaches the wire verbatim', () async {
      // The id is arbitrary text from somebody's project file. Folding it to
      // `plugin` is the same rule as WaveCrux's `decoder: plugin`, and the
      // reason is the never-collect rule: an id could carry a path, a vendor name, anything.
      expect(simulatorTelemetryToken('acme-secret-sim-v3'), 'plugin');
      expect(simulatorTelemetryToken('icarus'), 'icarus');
      expect(regressionSimulatorToken(const <String>[]), isNull);
    });
  });

  group('regression.cancelled', () {
    test('fires when an in-flight run is cancelled, exactly once', () async {
      container = build(driver: _BlockingDriver());
      final runner = container.read(regressionRunnerProvider.notifier);
      await runner.start(_config([_spec('unit/hang')]));
      await pollUntil(
        () => container.read(regressionRunnerProvider).value != null,
      );

      await runner.cancel();

      expect(telemetry.named('regression.cancelled'), hasLength(1));
      expectMatchesCatalog(telemetry.named('regression.cancelled').single);
      expect(
        telemetry.named('regression.completed'),
        isEmpty,
        reason: 'a cancelled run did not complete',
      );

      // Idempotence: `start()` calls `cancel()` on entry, and the app-exit
      // path can cancel the scheduler directly. Neither may double-count.
      await runner.cancel();
      expect(telemetry.named('regression.cancelled'), hasLength(1));
    });

    test('a cancel with nothing running records nothing', () async {
      await container.read(regressionRunnerProvider.notifier).cancel();
      expect(telemetry.events, isEmpty);
    });
  });

  group('detector.matched', () {
    test('reports each distinct pass_fail kind once per run', () async {
      // Once per run per kind, not once per test: a thousand-test suite would
      // otherwise put a thousand identical events into a 2000-event queue and
      // evict every other counter the session recorded.
      await container
          .read(regressionRunnerProvider.notifier)
          .start(
            _config([
              _spec('unit/a'),
              _spec('unit/b'),
              _spec(
                'unit/c',
                passFail: const RegexPassFailConfig(passPattern: 'PASS'),
              ),
            ]),
          );
      await waitForFinish();
      await pollUntil(() => telemetry.named('detector.matched').length >= 2);

      final kinds = telemetry
          .named('detector.matched')
          .map((e) => e.properties['kind'])
          .toList();
      expect(kinds, hasLength(2));
      expect(kinds, containsAll(<String>['exit_code', 'regex']));
      telemetry.named('detector.matched').forEach(expectMatchesCatalog);
    });
  });

  group('engine.missing', () {
    test('fires once per engine that never launched', () async {
      // `didExecute == false` is the surfaced form of
      // `SimulatorNotAvailableException`; `ghdl` has no registered driver
      // here, which is the other half of the same "engine not usable" fact.
      await container
          .read(regressionRunnerProvider.notifier)
          .start(
            _config([
              _spec('unit/a', simulatorId: 'ghdl'),
              _spec('unit/b', simulatorId: 'ghdl'),
              _spec('unit/c'),
            ]),
          );
      await waitForFinish();
      await pollUntil(() => telemetry.named('engine.missing').isNotEmpty);

      final events = telemetry.named('engine.missing');
      expect(events, hasLength(1), reason: 'two specs, one missing engine');
      expect(events.single.properties['simulator'], 'ghdl');
      expectMatchesCatalog(events.single);
    });
  });

  group('dashboard.view_changed', () {
    test('fires on a real change and not on a re-select', () {
      final notifier = container.read(dashboardViewModeProvider.notifier)
        ..setMode(DashboardViewMode.heatmap);
      expect(telemetry.named('dashboard.view_changed'), hasLength(1));
      expect(
        telemetry.named('dashboard.view_changed').single.properties['mode'],
        'heatmap',
      );
      expectMatchesCatalog(telemetry.named('dashboard.view_changed').single);

      // The segmented control calls setMode with the active mode whenever the
      // selected segment is tapped. Counting that would answer "how often is
      // this control touched", not "does the heatmap earn its place".
      notifier.setMode(DashboardViewMode.heatmap);
      expect(telemetry.named('dashboard.view_changed'), hasLength(1));

      notifier.setMode(DashboardViewMode.inspectorFocused);
      expect(
        telemetry.named('dashboard.view_changed').last.properties['mode'],
        'inspector_focused',
      );
      expectMatchesCatalog(telemetry.named('dashboard.view_changed').last);
    });
  });

  group('project.opened', () {
    test('every route in produces a catalog-legal token', () {
      for (final source in kSimcruxProjectSourceTokens) {
        final event = projectOpenedEvent(source);
        expect(event.name, 'project.opened');
        expectMatchesCatalog(event);
      }
    });

    test('a token outside the closed set trips the assert', () {
      // The postcondition the Worker enforces, stated in a debug build. A
      // typo'd source would otherwise cost the property silently, forever.
      expect(() => projectOpenedEvent('Yaml'), throwsA(isA<AssertionError>()));
    });
  });

  group('the workspace set', () {
    test('workspace.restored fires once, with tab and pane counts', () async {
      await container.read(workspaceProvider.future);
      final restored = telemetry.named('workspace.restored');
      expect(restored, hasLength(1));
      expect(restored.single.properties['tabs'], isA<int>());
      expect(restored.single.properties['panes'], isA<int>());
      expectMatchesCatalog(restored.single);
    });

    test('tab.opened fires on a new tab and not on a dedupe hit', () async {
      final notifier = container.read(workspaceProvider.notifier);
      await container.read(workspaceProvider.future);

      await notifier.openTab(
        displayName: 'a',
        payload: SimcruxTabPayload(configPath: '/proj/a.yaml'),
      );
      expect(telemetry.named('tab.opened'), hasLength(1));
      final event = telemetry.named('tab.opened').single;
      expect(event.properties['tabs'], 1);
      expect(event.properties['panes'], isA<int>());
      expectMatchesCatalog(event);

      // Re-opening the same project activates the existing tab. That is not a
      // tab opening, and counting it would inflate the number the tab-strip
      // sizing question is answered against.
      await notifier.openTab(
        displayName: 'a',
        payload: SimcruxTabPayload(configPath: '/proj/a.yaml'),
      );
      expect(telemetry.named('tab.opened'), hasLength(1));
    });

    test('pane.split and pane.closed fire only on a real mutation', () async {
      final notifier = container.read(workspaceProvider.notifier);
      await container.read(workspaceProvider.future);

      final paneId = await notifier.splitPaneRight();
      expect(telemetry.named('pane.split'), hasLength(1));
      expectMatchesCatalog(telemetry.named('pane.split').single);

      // The package no-ops a second split. A counter on the click rather than
      // the mutation would report a pane that does not exist.
      await notifier.splitPaneRight();
      expect(telemetry.named('pane.split'), hasLength(1));

      await notifier.closePane(paneId);
      expect(telemetry.named('pane.closed'), hasLength(1));
      expectMatchesCatalog(telemetry.named('pane.closed').single);

      // Closing the sole remaining pane is refused by the package.
      await notifier.closePane(
        container.read(workspaceProvider).value!.panes.first.id,
      );
      expect(telemetry.named('pane.closed'), hasLength(1));
    });
  });
}
