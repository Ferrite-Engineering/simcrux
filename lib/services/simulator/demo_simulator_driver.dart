// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:simcrux/domain/enums/hdl_language.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';

/// A built-in **no-op / echo** simulator driver used to populate the
/// desktop dashboard without a real toolchain.
///
/// It spawns no process: [compile] is a no-op success and [execute]
/// synthesizes a deterministic terminal result after a tiny synthetic
/// delay, so opening a `simcrux.yaml` whose tests declare
/// `simulator: demo` fills the dashboard with N fast fake rows —
/// enough to demo and exercise dashboard-at-scale virtualization
/// without iverilog / verilator / ghdl / cocotb installed.
///
/// It is **hidden by default**: [DemoSimulatorDriver] is only wired into
/// [SimulatorDriverRegistry] when `demoRunnerEnabledProvider` resolves
/// true (the `SIMCRUX_DEMO_RUNNER` environment gate). Normal users never
/// see a `demo` simulator in the diagnostics probe or filter chips.
///
/// Determinism: pass/fail and the reported runtime are derived from the
/// test id, so the same project produces the same demo dashboard every
/// run — useful for screenshots and widget tests. Roughly one test in
/// seven is reported as a failure so the demo shows a realistic mix of
/// statuses rather than an all-green board.
class DemoSimulatorDriver implements SimulatorDriver {
  /// Creates a [DemoSimulatorDriver].
  const DemoSimulatorDriver();

  /// The reserved simulator id projects opt into via `simulator: demo`.
  static const String kId = 'demo';

  @override
  String get id => kId;

  @override
  String get displayName => 'Demo (no-op runner)';

  @override
  SimulatorCapabilities get capabilities => SimulatorCapabilities(
    supportedLanguages: const {
      HdlLanguage.verilog,
      HdlLanguage.systemVerilog,
      HdlLanguage.vhdl,
    },
    supportsVcd: false,
    supportsFst: false,
    supportsCocotb: false,
    requiresSeparateCompileStep: false,
    emitsStructuredOutput: false,
  );

  @override
  Future<String?> detectVersion(SimulatorBinaryConfig config) async =>
      'demo (built-in no-op runner)';

  @override
  Future<CompileResult> compile(CompileRequest request) async =>
      const CompileResult(
        success: true,
        artifactPath: 'demo',
        stdout: '',
        stderr: '',
      );

  @override
  Stream<TestExecutionEvent> execute(ExecuteRequest request) async* {
    final startedAt = DateTime.now().toUtc();
    final seed = request.test.seed ?? request.test.id.hashCode & 0x7fffffff;
    // Deterministic outcome + runtime from the test id so the fake
    // dashboard is stable across runs. ~1/7 tests "fail" so the board
    // shows a realistic mix rather than all-pass.
    final bucket = request.test.id.hashCode & 0x7fffffff;
    final fails = bucket % 7 == 0;
    final fakeMillis = 5 + bucket % 45;

    yield TestLogLine(
      line: 'demo: running ${request.test.id} (no-op runner, seed $seed)',
      fromStderr: false,
      timestamp: DateTime.now().toUtc(),
    );
    // A short synthetic delay so results stream in over time (as they
    // would from a real run) rather than landing in a single frame.
    await Future<void>.delayed(Duration(milliseconds: fakeMillis));
    if (fails) {
      yield TestLogLine(
        line: 'demo: assertion failed (synthetic)',
        fromStderr: true,
        timestamp: DateTime.now().toUtc(),
      );
    }
    yield TestExecutionFinished(
      status: fails ? TestStatus.fail : TestStatus.pass,
      exitCode: fails ? 1 : 0,
      startedAt: startedAt,
      finishedAt: startedAt.add(Duration(milliseconds: fakeMillis)),
      effectiveSeed: seed,
    );
  }

  @override
  void cancel(String testId) {
    // Nothing to cancel — the driver owns no process or timer that
    // outlives the awaited delay in [execute].
  }
}
