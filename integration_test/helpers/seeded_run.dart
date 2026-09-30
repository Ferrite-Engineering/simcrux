// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// integration_test/helpers/seeded_run.dart
//
// The seeded-result-store harness primitive: drives the REAL
// orchestration pipeline — ConfigLoader → LocalJobScheduler →
// PassFailDetectorRegistry → InMemoryResultStore (+ TrendStore) — against a
// scripted in-process SimulatorDriver, so integration journeys can exercise
// the dashboard / inspector / trend surfaces against a completed run without
// invoking real simulators or spawning any OS process (the
// `no_real_process_spawn_in_unit_tests_test.dart` discipline; nothing here
// touches `Process.start` at all).
//
// Usage shape:
//
// ```dart
// final project = await writeSeededProject(tests: [
//   SeededTest('smoke', 'alu_pass', const [ScriptedOutcome.pass()]),
//   SeededTest('smoke', 'alu_fail', const [ScriptedOutcome.fail()]),
// ]);
// final driver = ScriptedDriver(project.outcomesByTestName);
// await bootSimcrux(tester,
//     args: [project.configPath],
//     extraOverrides: [seededDriverRegistryOverride(driver)]);
// final tab = tabContainerFor(tester);
// await pumpUntilRunFinished(tester, tab);
// ```

import 'dart:async';
import 'dart:io';

import 'package:crux_workspace/crux_workspace.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/hdl_language.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/dashboard/providers/regression_runner.dart';
import 'package:simcrux/features/workspace/providers/container_managers.dart';
import 'package:simcrux/services/job_scheduler/job_scheduler_provider.dart';
import 'package:simcrux/services/result_store/in_memory_result_store.dart';
import 'package:simcrux/services/result_store/result_store_provider.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';

import 'app_driver.dart';

/// One scripted per-run outcome for a seeded test.
class ScriptedOutcome {
  /// Creates a [ScriptedOutcome]. [pass] drives the exit code (0/1) that
  /// the real `exit_code` pass/fail detector classifies.
  const ScriptedOutcome({
    required this.pass,
    this.stdoutLines = const <String>[],
    this.stderrLines = const <String>[],
    this.runtime = const Duration(milliseconds: 12),
  });

  /// A passing run with a conventional log tail.
  const ScriptedOutcome.passed({List<String>? stdoutLines})
    : this(
        pass: true,
        stdoutLines: stdoutLines ?? const ['seeded: TEST PASSED'],
      );

  /// A failing run with a conventional error line on stderr.
  const ScriptedOutcome.failed({List<String>? stderrLines})
    : this(
        pass: false,
        stdoutLines: const ['seeded: running'],
        stderrLines: stderrLines ?? const ['seeded: ERROR intentional failure'],
      );

  /// Whether this run exits 0 (pass) or 1 (fail).
  final bool pass;

  /// Log lines streamed on stdout before the run finishes.
  final List<String> stdoutLines;

  /// Log lines streamed on stderr before the run finishes.
  final List<String> stderrLines;

  /// Reported wall-clock runtime (finishedAt - startedAt).
  final Duration runtime;
}

/// One seeded test declaration: suite, name, and the per-run outcome
/// script (run N uses `outcomes[min(N, length-1)]` — the last outcome
/// repeats, so a single-element script is "always this outcome" and a
/// multi-element script varies across re-runs, e.g. flakiness).
class SeededTest {
  /// Creates a [SeededTest].
  ///
  /// [seeds] and [parameterSweeps] declare a parameterization sweep on
  /// this test exactly as a user's `simcrux.yaml` would (`seeds: [1, 2]`
  /// / `parameters: { WIDTH: ["8", "16"] }`). The real `ConfigLoader` +
  /// `TestSpecExpander` fan the template out into one concrete child per
  /// (seed × parameter-combination); every child keeps this [name], so
  /// the [ScriptedDriver]'s per-name [outcomes] script applies to every
  /// expansion of it. Leave both null (the default) for a plain,
  /// un-expanded test — the emitted YAML is then byte-identical to the
  /// pre-sweep helper.
  const SeededTest(
    this.suite,
    this.name,
    this.outcomes, {
    this.seeds,
    this.parameterSweeps,
  });

  /// Suite name (yaml suite key).
  final String suite;

  /// Test name (unique across the seeded project).
  final String name;

  /// Per-run outcome script.
  final List<ScriptedOutcome> outcomes;

  /// Optional seed sweep (`seeds: [1, 2, 3]` in YAML). Null means no
  /// seed axis. Each value becomes one expanded child with that seed.
  final List<int>? seeds;

  /// Optional parameter sweep axes (`parameters: { KEY: [a, b] }` in
  /// YAML). Null/empty means no parameter axis. Multi-value entries fan
  /// out across their cartesian product; single-value entries collapse
  /// to a scalar binding (matching the loader's normalization).
  final Map<String, List<String>>? parameterSweeps;
}

/// A seeded on-disk project: a real `simcrux.yaml` (parsed by the real
/// `ConfigLoader`) plus the outcome script for the scripted driver.
class SeededProject {
  SeededProject._(this.dir, this.configPath, this.outcomesByTestName);

  /// Temp directory holding the project. Deleted via [dispose].
  final Directory dir;

  /// Absolute path of the seeded `simcrux.yaml`.
  final String configPath;

  /// Outcome script keyed by test name, for [ScriptedDriver].
  final Map<String, List<ScriptedOutcome>> outcomesByTestName;

  /// Removes the temp project directory (best-effort).
  Future<void> dispose() async {
    try {
      if (dir.existsSync()) await dir.delete(recursive: true);
    } on Object {
      // Best-effort cleanup.
    }
  }
}

/// Writes a real seeded project into a temp directory: a `simcrux.yaml`
/// declaring [tests] (defaults: simulator `icarus`, `exit_code`
/// pass/fail, waveform never) plus a dummy HDL source so the config
/// parses exactly like a user project. Registers cleanup via
/// [addTearDown].
Future<SeededProject> writeSeededProject({
  required List<SeededTest> tests,
}) async {
  final dir = await Directory.systemTemp.createTemp('simcrux_seeded_');
  File(p.join(dir.path, 'tb.v')).writeAsStringSync(
    '// Dummy source for the seeded integration project; the scripted\n'
    '// driver never reads it — it exists so the config parses like a\n'
    '// real user project.\n'
    'module tb; endmodule\n',
  );

  final bySuite = <String, List<SeededTest>>{};
  for (final t in tests) {
    bySuite.putIfAbsent(t.suite, () => <SeededTest>[]).add(t);
  }
  final yaml = StringBuffer()
    ..writeln("version: '1'")
    ..writeln()
    ..writeln('defaults:')
    ..writeln('  simulator: icarus')
    ..writeln('  pass_fail:')
    ..writeln('    type: exit_code')
    ..writeln('  waveform:')
    ..writeln('    capture: never')
    ..writeln()
    ..writeln('suites:');
  for (final entry in bySuite.entries) {
    yaml
      ..writeln('  ${entry.key}:')
      ..writeln('    description: Seeded integration suite.')
      ..writeln('    tests:');
    for (final t in entry.value) {
      yaml
        ..writeln('      - name: ${t.name}')
        ..writeln('        top: tb')
        ..writeln('        sources:')
        ..writeln('          - tb.v');
      final seeds = t.seeds;
      if (seeds != null && seeds.isNotEmpty) {
        yaml.writeln('        seeds: [${seeds.join(', ')}]');
      }
      final sweeps = t.parameterSweeps;
      if (sweeps != null && sweeps.isNotEmpty) {
        yaml.writeln('        parameters:');
        for (final axis in sweeps.entries) {
          final values = axis.value.map((v) => '"$v"').join(', ');
          yaml.writeln('          ${axis.key}: [$values]');
        }
      }
    }
  }
  final configPath = p.join(dir.path, 'simcrux.yaml');
  File(configPath).writeAsStringSync(yaml.toString());

  final project = SeededProject._(dir, configPath, {
    for (final t in tests) t.name: t.outcomes,
  });
  addTearDown(project.dispose);
  return project;
}

/// In-process [SimulatorDriver] that replays a per-test outcome script
/// instead of spawning a simulator. Registered under the id `icarus`
/// so seeded configs resolve through the stock driver-lookup path.
class ScriptedDriver implements SimulatorDriver {
  /// Creates a [ScriptedDriver] replaying [outcomesByTestName].
  ScriptedDriver(this.outcomesByTestName);

  /// Outcome script keyed by `TestSpec.name`.
  final Map<String, List<ScriptedOutcome>> outcomesByTestName;

  /// Per-test invocation counter — run N of a test consumes script
  /// entry `min(N, script.length - 1)`.
  final Map<String, int> invocations = <String, int>{};

  @override
  String get id => 'icarus';

  @override
  String get displayName => 'Scripted (seeded integration)';

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
  Future<String?> detectVersion(SimulatorBinaryConfig config) async =>
      'scripted';

  @override
  Future<CompileResult> compile(CompileRequest request) async =>
      const CompileResult(
        success: true,
        artifactPath: 'seeded',
        stdout: '',
        stderr: '',
      );

  @override
  Stream<TestExecutionEvent> execute(ExecuteRequest request) async* {
    final name = request.test.name;
    final script = outcomesByTestName[name];
    if (script == null || script.isEmpty) {
      throw StateError('ScriptedDriver: no outcome scripted for `$name`');
    }
    final run = invocations[name] ?? 0;
    invocations[name] = run + 1;
    final outcome = script[run < script.length ? run : script.length - 1];

    final startedAt = DateTime.now().toUtc();
    for (final line in outcome.stdoutLines) {
      yield TestLogLine(line: line, fromStderr: false, timestamp: startedAt);
    }
    for (final line in outcome.stderrLines) {
      yield TestLogLine(line: line, fromStderr: true, timestamp: startedAt);
    }
    yield TestExecutionFinished(
      status: outcome.pass ? TestStatus.pass : TestStatus.fail,
      exitCode: outcome.pass ? 0 : 1,
      startedAt: startedAt,
      finishedAt: startedAt.add(outcome.runtime),
    );
  }

  @override
  void cancel(String testId) {}
}

/// Root-container override that replaces the production driver registry
/// with one carrying only [driver]. Per-tab containers delegate to the
/// root for `simulatorDriverRegistryProvider`, so every tab's scheduler
/// resolves the scripted driver.
Override seededDriverRegistryOverride(ScriptedDriver driver) =>
    simulatorDriverRegistryProvider.overrideWithValue(
      SimulatorDriverRegistry({driver.id: driver}),
    );

/// The per-tab [ProviderContainer] for [tabId] (defaults to the single
/// open tab), via the live app's `WorkspaceContainerManagers`.
ProviderContainer tabContainerFor(WidgetTester tester, {TabId? tabId}) {
  final root = rootContainer(tester);
  final managers = root.read(workspaceContainerManagersProvider);
  final id = tabId ?? liveWorkspace(tester).tabs.single.id;
  return managers.tabs.containerFor(id);
}

/// Starts the armed tab's regression, the way the Run action does.
///
/// Opening a config only *arms* a tab — `autoRunOnOpen` is off by
/// default by design (opening a file must not launch two
/// hundred tests and check out simulator licences on a misclick), so
/// the CLI bootstrap loads the config and stops. This drives the
/// second, deliberate half: wait for the tab to finish arming, then
/// call the same `RegressionRunner.start` the toolbar's Run button
/// calls.
Future<void> startSeededRun(
  WidgetTester tester,
  ProviderContainer tab, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final armed = await pumpUntil(
    tester,
    () => tab.read(activeConfigProvider) != null,
    timeout: timeout,
  );
  expect(
    armed,
    isTrue,
    reason: 'seeded config did not arm the tab in $timeout',
  );
  final config = tab.read(activeConfigProvider)!;
  unawaited(tab.read(regressionRunnerProvider.notifier).start(config));
  await tester.pump();
}

/// Waits (bounded) until [tab]'s regression run reports finished AND the
/// per-tab result store holds [expectedResults] terminal results.
Future<void> pumpUntilRunFinished(
  WidgetTester tester,
  ProviderContainer tab, {
  required int expectedResults,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final finished = await pumpUntil(
    tester,
    () => tab.read(regressionRunnerProvider).value?.isFinished ?? false,
    timeout: timeout,
  );
  expect(finished, isTrue, reason: 'seeded run did not finish in $timeout');
  final populated = await pumpUntil(tester, () {
    final store = tab.read(resultStoreProvider);
    return store is InMemoryResultStore &&
        store.recordedCount >= expectedResults;
  }, timeout: timeout);
  expect(
    populated,
    isTrue,
    reason: 'result store did not reach $expectedResults results in $timeout',
  );
}
