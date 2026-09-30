// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';

import 'package:simcrux/domain/enums/hdl_language.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/job_scheduler.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/regression_request.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/job_scheduler/fake_process_runner.dart';
import 'package:simcrux/services/job_scheduler/local_job_scheduler.dart';
import 'package:simcrux/services/job_scheduler/process_reaper.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';

/// A declarative orchestration scenario: the real `simcrux.yaml`, the
/// per-test [FakeProcessBehavior] script (the `behaviors.json` analogue),
/// and the specs the scheduler runs. The golden replay snapshots the
/// per-test result rows; both `tool/generate_orchestration_fixtures.dart`
/// (which writes the corpus) and `orchestration_golden_test.dart` (which
/// verifies it) consume this so the input and the golden cannot drift.
///
/// SimCrux is a regression *manager*, not a simulator: the fixture is a
/// config + the deterministic behaviour of its (fake) simulator
/// processes, not a value vector. Driven by the in-process
/// [FakeProcessRunner], so the golden runs in milliseconds on every
/// platform with no simulator installed.
class OrchestrationScenario {
  /// Creates an [OrchestrationScenario].
  const OrchestrationScenario({
    required this.name,
    required this.simcruxYaml,
    required this.modelledSimulatorId,
    required this.behaviors,
    required this.specs,
    this.defaultTimeout = kOrchestrationDefaultTimeout,
  });

  /// Scenario directory name under `test/fixtures/orchestration/`.
  final String name;

  /// The committed `simcrux.yaml` (the real config the scenario models).
  ///
  /// This is a *loadable* `simcrux.yaml`: `orchestration_golden_test.dart`
  /// parses every committed copy through the real `ConfigLoader` and
  /// diffs the resulting specs against [specs], so the config cannot
  /// drift away from the schema (or from the scenario) unnoticed.
  final String simcruxYaml;

  /// The simulator id [simcruxYaml] declares — the simulator this
  /// scenario *models*.
  ///
  /// [specs] deliberately name the in-process `fake` driver instead:
  /// the replay must run with no simulator installed. Holding the
  /// modelled id here keeps the YAML's `defaults.simulator:` line
  /// enforced by the golden test rather than decorative.
  final String modelledSimulatorId;

  /// Per-test fake-process script, keyed by test id.
  final Map<String, FakeProcessBehavior> behaviors;

  /// The specs the scheduler runs.
  ///
  /// These mirror [simcruxYaml] and the mirror is *enforced*:
  /// `orchestration_golden_test.dart` loads the committed config through
  /// the real `ConfigLoader` and asserts the loaded specs match these on
  /// suite name, test name, `top`, seed, and per-test timeout, in order.
  ///
  /// Two fields deliberately do not round-trip, and the golden test
  /// checks each against its own source of truth instead:
  ///
  /// - [TestSpec.id]: the loader synthesizes `<suite>/<name>`, while
  ///   these use the bare name — the id becomes the per-test working
  ///   directory (and the `behaviors.json` key), and it is snapshotted
  ///   in `expected_results.ndjson`.
  /// - [TestSpec.simulatorId]: always `fake` here so the replay needs no
  ///   installed simulator; the YAML's real value is asserted against
  ///   [modelledSimulatorId].
  final List<TestSpec> specs;

  /// Default per-test timeout when a spec does not pin its own.
  final Duration defaultTimeout;

  /// The `behaviors.json` payload for this scenario (human-reviewable
  /// source of truth for what each fake simulator does).
  String get behaviorsJson {
    const encoder = JsonEncoder.withIndent('  ');
    return '${encoder.convert(<String, Object?>{
      'scenario': name,
      'tests': <String, Object?>{
        for (final entry in behaviors.entries) entry.key: <String, Object?>{
            'exitCode': entry.value.exitCode,
            'delayMs': entry.value.delay.inMilliseconds,
            'ignoresSigterm': entry.value.ignoresSigterm,
            'spawnsChildren': entry.value.spawnsChildren,
            if (entry.value.stdout.isNotEmpty) 'stdout': entry.value.stdout,
            if (entry.value.stderr.isNotEmpty) 'stderr': entry.value.stderr,
          },
      },
    })}\n';
  }
}

/// Minimal single-spawn [SimulatorDriver] that routes spawn + cancel
/// through the injected [ProcessReaper] — the production wiring — so a
/// scenario replay exercises the scheduler + reaper against the
/// [FakeProcessRunner] with no real simulator.
class OrchestrationFixtureDriver implements SimulatorDriver {
  /// Creates an [OrchestrationFixtureDriver].
  OrchestrationFixtureDriver({
    required this.reaper,
    this.killGrace = const Duration(milliseconds: 15),
  });

  /// The reaper the driver spawns and reaps through.
  final ProcessReaper reaper;

  /// Grace window before SIGKILL escalation.
  final Duration killGrace;

  final Map<String, ReapableProcess> _live = <String, ReapableProcess>{};

  @override
  String get id => 'fake';

  @override
  String get displayName => 'Fake (orchestration fixture)';

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
  Stream<TestExecutionEvent> execute(ExecuteRequest request) {
    final controller = StreamController<TestExecutionEvent>();
    unawaited(_run(request, controller));
    return controller.stream;
  }

  Future<void> _run(
    ExecuteRequest request,
    StreamController<TestExecutionEvent> controller,
  ) async {
    final startedAt = DateTime.now().toUtc();
    final process = await reaper.spawnGrouped(
      'sim',
      const <String>[],
      workingDirectory: request.workingDirectory,
    );
    _live[request.test.id] = process;
    final outDone = Completer<void>();
    final errDone = Completer<void>();
    final outSub = process.stdout.listen(
      (line) => controller.add(
        TestLogLine(line: line, fromStderr: false, timestamp: startedAt),
      ),
      onDone: outDone.complete,
    );
    final errSub = process.stderr.listen(
      (line) => controller.add(
        TestLogLine(line: line, fromStderr: true, timestamp: startedAt),
      ),
      onDone: errDone.complete,
    );
    final exit = await process.exitCode;
    await Future.wait<void>([outDone.future, errDone.future]);
    await outSub.cancel();
    await errSub.cancel();
    _live.remove(request.test.id);
    controller.add(
      TestExecutionFinished(
        status: exit == 0 ? TestStatus.pass : TestStatus.fail,
        exitCode: exit,
        startedAt: startedAt,
        finishedAt: DateTime.now().toUtc(),
        killSignal: process.killSignal,
      ),
    );
    await controller.close();
  }

  @override
  void cancel(String testId) {
    final process = _live[testId];
    if (process == null) return;
    unawaited(reaper.terminateTree(process, grace: killGrace));
  }
}

/// Replays [scenario] through a real [LocalJobScheduler] + the
/// [FakeProcessRunner], returning the per-test golden rows in scheduler
/// emission order. Runs at concurrency 1 so the emission order — and
/// therefore the golden — is deterministic across machines.
Future<List<Map<String, Object?>>> replayOrchestrationScenario(
  OrchestrationScenario scenario, {
  required String runRoot,
}) async {
  final fake = FakeProcessRunner(
    resolveBehavior: (request) {
      final dir = request.workingDirectory ?? '';
      final key = dir.split(RegExp(r'[\\/]')).last;
      return scenario.behaviors[key] ?? const FakeProcessBehavior();
    },
  );
  final driver = OrchestrationFixtureDriver(reaper: fake);
  final scheduler = LocalJobScheduler(
    driverRegistry: SimulatorDriverRegistry({driver.id: driver}),
    config: RegressionConfig(
      projectFilePath: '/fixture/simcrux.yaml',
      schemaVersion: '1',
      suites: const [],
      simulatorBinaries: const {},
    ),
    runRoot: runRoot,
  );
  final events = await scheduler
      .submit(
        RegressionRequest(
          runId: 'golden',
          tests: scenario.specs,
          defaultTimeout: scenario.defaultTimeout,
        ),
      )
      .toList();
  return events
      .whereType<TestFinished>()
      .map((e) => _goldenRow(e.result))
      .toList();
}

Map<String, Object?> _goldenRow(TestResult result) => <String, Object?>{
  'testId': result.testId,
  'status': result.status.name,
  'exitCode': result.exitCode,
  'durationMsBucketed': _bucket(result.status, result.runtime),
  'killSignal': result.killSignal?.wireName,
};

/// Buckets the outcome so the golden is stable across machines and CI
/// load. The fake processes are near-instant, so their measured wall-clock
/// runtime is dominated by scheduler/OS overhead — a sub-second threshold
/// (the former `<100` / `<1s` split) flips between buckets purely on runner
/// load (observed: a happy-path test measuring `<100` on Linux/macOS but
/// `<1s` on a loaded Windows runner, failing the golden). The only timing
/// distinction the corpus actually encodes — and the only one that is
/// machine-stable — is whether a test completed before its timeout or hit
/// it. Raw milliseconds are never snapshotted.
String _bucket(TestStatus status, Duration runtime) {
  if (status == TestStatus.timeout) return '>=timeout';
  return '<timeout';
}

/// Serializes golden [rows] to NDJSON (one JSON object per line), the
/// committed `expected_results.ndjson` format.
String orchestrationNdjson(List<Map<String, Object?>> rows) =>
    '${rows.map(jsonEncode).join('\n')}\n';

/// Per-test timeout every scenario's `defaults.timeout:` declares, and
/// the value [_spec] pins when a test does not override it.
///
/// The scheduler treats `Duration.zero` as "fall back to the request's
/// `defaultTimeout`", which is this same value — so pinning it
/// explicitly is behaviourally identical, and it lets the committed
/// `simcrux.yaml` state the budget instead of leaving it implicit
/// (the config schema has no "unset" duration to round-trip).
const Duration kOrchestrationDefaultTimeout = Duration(milliseconds: 60);

/// The suite name every scenario's `simcrux.yaml` declares.
const String _suiteName = 'suite';

TestSpec _spec(String id, {int? seed, Duration? timeout}) => TestSpec(
  id: id,
  name: id,
  suiteName: _suiteName,
  simulatorId: 'fake',
  top: 'tb',
  seed: seed,
  timeout: timeout ?? kOrchestrationDefaultTimeout,
);

/// The committed orchestration corpus. Each scenario writes a
/// `simcrux.yaml`, a `behaviors.json`, and an `expected_results.ndjson`
/// under `<scenario>/generated/`.
List<OrchestrationScenario> orchestrationScenarios() => <OrchestrationScenario>[
  OrchestrationScenario(
    name: 'happy_path_8tests',
    simcruxYaml: _happyYaml,
    modelledSimulatorId: 'icarus',
    behaviors: <String, FakeProcessBehavior>{
      'uart_loopback': const FakeProcessBehavior(
        exitCode: 1,
        stderr: <String>['UVM_ERROR : 3 errors'],
      ),
    },
    specs: <TestSpec>[
      for (var i = 0; i < 8; i++) _spec('alu_$i', seed: i),
      _spec('uart_loopback'),
    ],
  ),
  OrchestrationScenario(
    name: 'timeout_then_sigkill',
    simcruxYaml: _timeoutYaml,
    modelledSimulatorId: 'icarus',
    behaviors: <String, FakeProcessBehavior>{
      'alu_mul': const FakeProcessBehavior(
        delay: Duration(days: 1),
        ignoresSigterm: true,
      ),
      'uart_loopback': const FakeProcessBehavior(
        exitCode: 1,
        stderr: <String>['UVM_ERROR : 3 errors'],
      ),
    },
    specs: <TestSpec>[
      _spec('alu_add'),
      _spec('uart_loopback'),
      _spec('alu_mul', timeout: const Duration(milliseconds: 40)),
    ],
  ),
  OrchestrationScenario(
    name: 'cocotb_tree_reap',
    simcruxYaml: _cocotbYaml,
    modelledSimulatorId: 'cocotb',
    behaviors: <String, FakeProcessBehavior>{
      'cocotb_dff': const FakeProcessBehavior(
        delay: Duration(days: 1),
        spawnsChildren: 2,
      ),
    },
    specs: <TestSpec>[
      _spec('cocotb_dff', timeout: const Duration(milliseconds: 40)),
    ],
  ),
];

// The three committed configs below are real, loadable `simcrux.yaml`
// documents — schema `version: '1'`, `defaults:` / `suites:` blocks,
// `pass_fail: { type: ... }`, per-test `top:` — not sketches of one.
// `orchestration_golden_test.dart` runs each committed copy through the
// real ConfigLoader and diffs the loaded specs against the scenario's
// `specs`, so any edit here that the loader rejects, or that stops
// matching the specs the scheduler runs, fails the suite.

const String _happyYaml = '''
# happy_path_8tests/generated/simcrux.yaml
version: '1'

defaults:
  simulator: icarus
  timeout: 60ms
  pass_fail:
    type: exit_code

suites:
  suite:
    description: Eight seeded ALU tests plus one failing UART loopback.
    tests:
      - { name: alu_0, top: tb, seed: 0 }
      - { name: alu_1, top: tb, seed: 1 }
      - { name: alu_2, top: tb, seed: 2 }
      - { name: alu_3, top: tb, seed: 3 }
      - { name: alu_4, top: tb, seed: 4 }
      - { name: alu_5, top: tb, seed: 5 }
      - { name: alu_6, top: tb, seed: 6 }
      - { name: alu_7, top: tb, seed: 7 }
      - { name: uart_loopback, top: tb }   # exits 1 with a UVM_ERROR summary
''';

const String _timeoutYaml = '''
# timeout_then_sigkill/generated/simcrux.yaml
version: '1'

defaults:
  simulator: icarus
  timeout: 60ms
  pass_fail:
    type: exit_code

suites:
  suite:
    description: Timeout escalation — SIGTERM ignored, SIGKILL required.
    tests:
      - { name: alu_add, top: tb }
      - { name: uart_loopback, top: tb }   # exits 1 with a UVM_ERROR summary
      - { name: alu_mul, top: tb, timeout: 40ms }   # sleeps past timeout, ignores SIGTERM
''';

const String _cocotbYaml = '''
# cocotb_tree_reap/generated/simcrux.yaml
version: '1'

defaults:
  simulator: cocotb
  timeout: 60ms
  pass_fail:
    type: exit_code

suites:
  suite:
    description: Process-tree reaping for a cocotb run that outlives its timeout.
    tests:
      - { name: cocotb_dff, top: tb, timeout: 40ms }   # make -> python -> vvp grandchildren
''';
