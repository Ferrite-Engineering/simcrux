// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';
import 'package:simcrux/domain/enums/hdl_language.dart';
import 'package:simcrux/domain/enums/kill_signal.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/bounded_log_capture.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/test_spec.dart';

/// Wrap one HDL simulator (Icarus, Verilator, GHDL, Cocotb, vendor).
///
/// Each driver translates SimCrux's neutral `TestSpec` into the
/// invocation pattern that simulator expects. Adding a new simulator
/// is implementing this interface and registering it in
/// `SimulatorDriverRegistry`. The interface itself is stable; a
/// plugin-contributed driver (`xsim`, `questa`) implements it the same
/// way the built-in drivers do.
abstract class SimulatorDriver {
  /// Stable id. Appears in `TestSpec.simulatorId` and in the result
  /// records persisted to SQLite. Use lowercase ASCII (e.g.
  /// `icarus`, `verilator`, `ghdl`, `cocotb`).
  String get id;

  /// Human-readable name for the dashboard's simulator filter chip.
  String get displayName;

  /// Capabilities this simulator declares.
  SimulatorCapabilities get capabilities;

  /// Detect the installed simulator's version string. Returns null
  /// when the binary is not present, not executable, or the
  /// version-probe command failed. Implementations should be
  /// non-throwing.
  Future<String?> detectVersion(SimulatorBinaryConfig config);

  /// Compile the test's design + testbench. May be a no-op for
  /// simulators that compile-and-run in one step (e.g. some Cocotb
  /// backends). Returns a [CompileResult] regardless so the
  /// scheduler can surface compile warnings before execute.
  Future<CompileResult> compile(CompileRequest request);

  /// Execute a compiled test. Emits a stream of
  /// [TestExecutionEvent]s; the stream closes when the test
  /// completes, times out, or is cancelled.
  Stream<TestExecutionEvent> execute(ExecuteRequest request);

  /// Cancel an in-flight `compile` or `execute` for [testId]. The
  /// driver is responsible for escalating SIGTERM → SIGKILL on a
  /// short delay, matching the scheduler's overall cancellation
  /// policy.
  void cancel(String testId);
}

/// Static capability descriptor for a simulator. The dashboard's
/// simulator selector and the config validator both consult these.
@immutable
class SimulatorCapabilities {
  /// Creates a [SimulatorCapabilities].
  SimulatorCapabilities({
    required Set<HdlLanguage> supportedLanguages,
    required this.supportsVcd,
    required this.supportsFst,
    required this.supportsCocotb,
    required this.requiresSeparateCompileStep,
    required this.emitsStructuredOutput,
  }) : supportedLanguages = Set<HdlLanguage>.unmodifiable(supportedLanguages);

  /// HDL languages this simulator can compile.
  final Set<HdlLanguage> supportedLanguages;

  /// Whether the simulator can emit `.vcd`.
  final bool supportsVcd;

  /// Whether the simulator can emit `.fst`.
  final bool supportsFst;

  /// Whether the simulator can host a Cocotb testbench.
  final bool supportsCocotb;

  /// True for simulators with a distinct compile step (Icarus,
  /// Verilator). False for simulators that compile-and-run in one
  /// command.
  final bool requiresSeparateCompileStep;

  /// True when the simulator (or its testbench runner) emits a
  /// structured per-test report (e.g. Cocotb's JUnit XML). The
  /// driver can short-circuit the line-based pass/fail detector when
  /// this is true.
  final bool emitsStructuredOutput;
}

/// What the scheduler hands to `SimulatorDriver.compile`.
@immutable
class CompileRequest {
  /// Creates a [CompileRequest].
  const CompileRequest({
    required this.test,
    required this.workingDirectory,
    required this.binaryConfig,
    this.stdoutCapture,
    this.stderrCapture,
  });

  /// The fully flattened test spec.
  final TestSpec test;

  /// Working directory the driver may write to (and the simulator
  /// will be invoked from).
  final String workingDirectory;

  /// How to locate the simulator binary.
  final SimulatorBinaryConfig binaryConfig;

  /// Bounded sink the driver streams compile-stage stdout lines into,
  /// line by line as they arrive, so a chatty compile step cannot grow
  /// an unbounded in-driver buffer before [CompileResult.stdout] is
  /// materialized. The scheduler passes its per-attempt capture here;
  /// when null (direct driver invocations, tests) the driver falls
  /// back to a private [BoundedLogCapture] with the default ceiling.
  final BoundedLogCapture? stdoutCapture;

  /// Bounded sink for compile-stage stderr lines; see [stdoutCapture].
  final BoundedLogCapture? stderrCapture;
}

/// Outcome of a compile pass. The simulator-specific compiled
/// artifact (e.g. Icarus's `.vvp`, Verilator's executable path) is
/// carried opaque-string so the matching `execute` invocation can
/// consume it without leaking simulator details up to the scheduler.
@immutable
class CompileResult {
  /// Creates a [CompileResult].
  const CompileResult({
    required this.success,
    required this.artifactPath,
    required this.stdout,
    required this.stderr,
  });

  /// True when the compile pass produced an artifact and the
  /// simulator's compile-stage exit code was zero.
  final bool success;

  /// Path to the compiled artifact (driver-specific), or null on
  /// failure.
  final String? artifactPath;

  /// Captured stdout from the compile pass.
  final String stdout;

  /// Captured stderr from the compile pass.
  final String stderr;
}

/// What the scheduler hands to `SimulatorDriver.execute`.
@immutable
class ExecuteRequest {
  /// Creates an [ExecuteRequest].
  const ExecuteRequest({
    required this.test,
    required this.workingDirectory,
    required this.compileResult,
    required this.binaryConfig,
  });

  /// The fully flattened test spec.
  final TestSpec test;

  /// Working directory the simulator runs in.
  final String workingDirectory;

  /// The compile result this execute is paired with (null when the
  /// driver's `capabilities.requiresSeparateCompileStep` is false and
  /// the scheduler skipped compile).
  final CompileResult? compileResult;

  /// How to locate the simulator binary.
  final SimulatorBinaryConfig binaryConfig;
}

/// Streamed event from `SimulatorDriver.execute`.
///
/// Sealed-style hierarchy with three variants:
///
/// - [TestLogLine]: a captured stdout / stderr line.
/// - [TestStatusChange]: an intermediate status hint (e.g. the test
///   transitioned from `running` to `pass` partway through, before
///   the final report).
/// - [TestExecutionFinished]: the terminal event carrying the final
///   exit code, runtime, and any captured artifact paths.
@immutable
sealed class TestExecutionEvent {
  /// Const default constructor.
  const TestExecutionEvent();
}

/// A captured log line.
@immutable
class TestLogLine extends TestExecutionEvent {
  /// Creates a [TestLogLine].
  const TestLogLine({
    required this.line,
    required this.fromStderr,
    required this.timestamp,
  });

  /// The raw line, without trailing newline.
  final String line;

  /// True if the line originated on stderr; false for stdout.
  final bool fromStderr;

  /// When the line was captured (UTC).
  final DateTime timestamp;
}

/// An intermediate status change. Optional — drivers that only
/// report a final status emit [TestExecutionFinished] without ever
/// emitting this variant.
@immutable
class TestStatusChange extends TestExecutionEvent {
  /// Creates a [TestStatusChange].
  const TestStatusChange({required this.status});

  /// The new (still potentially non-final) status.
  final TestStatus status;
}

/// Terminal event. The driver always emits exactly one of these per
/// `execute` stream (even on cancellation — the scheduler keys off
/// this event for cleanup).
@immutable
class TestExecutionFinished extends TestExecutionEvent {
  /// Creates a [TestExecutionFinished].
  TestExecutionFinished({
    required this.status,
    required this.exitCode,
    required this.startedAt,
    required this.finishedAt,
    this.waveformPath,
    this.stdoutPath,
    this.stderrPath,
    this.failureMessage,
    this.killSignal,
    this.effectiveSeed,
    Map<String, String>? metrics,
  }) : metrics = Map<String, String>.unmodifiable(metrics ?? const {});

  /// Final status reported by the driver. The `PassFailDetector` may
  /// reclassify based on the log stream; this is the driver's
  /// best-guess (e.g. `pass` for exit-code-0 simulators).
  final TestStatus status;

  /// Simulator process exit code, or null if not available (cancelled
  /// runs, structured-output backends).
  final int? exitCode;

  /// When the process was launched (UTC).
  final DateTime startedAt;

  /// When the driver finalized the run (UTC).
  final DateTime finishedAt;

  /// Path to a captured waveform, if [TestSpec.waveform] resulted in
  /// a capture.
  final String? waveformPath;

  /// Path to the persisted stdout log, when retained.
  final String? stdoutPath;

  /// Path to the persisted stderr log, when retained.
  final String? stderrPath;

  /// Short human-readable failure summary, when the driver can
  /// supply one.
  final String? failureMessage;

  /// The terminal signal the process reaper delivered to this test's
  /// process tree, or null when the process exited on its own (the
  /// common case). Set by the driver when a cancel / timeout routed
  /// through `ProcessReaper.terminateTree`; encodes the *kill path*
  /// (SIGTERM honoured vs. SIGKILL escalation) for the recorded result.
  final KillSignal? killSignal;

  /// The randomization seed the driver **actually ran with** — the
  /// requested [TestSpec.seed] when one was pinned, or the value the
  /// driver derived (typically clock-based) when none was. Null only when
  /// the driver could not surface the seed it used. The scheduler records
  /// this on [TestResult.executionSeed] so a run can be reproduced and a
  /// flaky retry can deterministically replay the *effective* seed rather
  /// than the (possibly null) requested one — closing the documented
  /// determinism gap.
  final int? effectiveSeed;

  /// Driver-emitted free-form key/value metrics that the scheduler
  /// forwards to [TestResult.metrics]. Used by drivers whose wrapped
  /// runner produces structured per-run metadata (e.g. the
  /// `CocotbDriver` surfaces per-testcase pass/fail counts and
  /// SIM TIME values; the UVM detector path adds UVM_FATAL /
  /// UVM_ERROR / UVM_WARNING / UVM_INFO counters). Empty for drivers
  /// that have nothing structured to surface.
  final Map<String, String> metrics;
}
