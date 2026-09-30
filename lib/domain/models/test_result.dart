// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';
import 'package:simcrux/domain/enums/kill_signal.dart';
import 'package:simcrux/domain/enums/test_status.dart';

/// The result of a single test execution.
///
/// Recorded by the `ResultStore` after a `SimulatorDriver.execute`
/// stream completes (or is cancelled / times out). Persistence to
/// SQLite for the trend store is handled out-of-band by the
/// `TrendStore` consumer of these records.
@immutable
class TestResult {
  /// Creates a [TestResult].
  TestResult({
    required this.testId,
    required this.runId,
    required this.status,
    required this.startedAt,
    required this.finishedAt,
    this.exitCode,
    this.stdoutPath,
    this.stderrPath,
    this.waveformPath,
    this.failureMessage,
    Map<String, String>? metrics,
    this.executionSeed,
    Map<String, String>? boundParameters,
    this.parentSpecId,
    this.killSignal,
    this.didExecute = true,
  }) : metrics = Map<String, String>.unmodifiable(metrics ?? const {}),
       boundParameters = boundParameters == null
           ? null
           : Map<String, String>.unmodifiable(boundParameters),
       assert(
         !finishedAt.isBefore(startedAt),
         'finishedAt must be >= startedAt',
       );

  /// The `TestSpec.id` this result belongs to.
  final String testId;

  /// The parent `TestRun.id` (UUID, generated when `JobScheduler.submit`
  /// is called). One `TestRun` aggregates many `TestResult`s.
  final String runId;

  /// Classification produced by `PassFailDetector`. See
  /// [TestStatus] for the full list.
  final TestStatus status;

  /// When the simulator process was launched (UTC).
  final DateTime startedAt;

  /// When the result was finalized (UTC). `finishedAt - startedAt` is
  /// the wall-clock runtime.
  final DateTime finishedAt;

  /// Simulator process exit code. Null when the run was cancelled
  /// before completion or when the driver doesn't surface an exit
  /// code (e.g. some Cocotb backends report status via XML only).
  final int? exitCode;

  /// Absolute path to the captured stdout log, when retained. The
  /// scheduler may delete logs for successful runs per the
  /// project-level retention policy.
  final String? stdoutPath;

  /// Absolute path to the captured stderr log, when retained.
  final String? stderrPath;

  /// Absolute path to the captured waveform dump, when [WaveformPolicy]
  /// resulted in a capture. Null otherwise.
  final String? waveformPath;

  /// Short human-readable failure summary suitable for the dashboard
  /// row (e.g. "Expected 0x42, got 0x41 at tb.sv:128"). Filled by the
  /// pass/fail detector when it has enough context.
  final String? failureMessage;

  /// Free-form key/value metrics emitted by the simulator or
  /// reported by the user testbench (e.g. coverage points, cycle
  /// counts). Values are strings to keep the persistence layer
  /// simple; consumers parse as needed.
  final Map<String, String> metrics;

  /// The randomization seed the simulator actually used for this
  /// execution.
  ///
  /// When [TestSpec.seed] was non-null at submission time, this echoes
  /// the same value. When the spec's seed was null, the driver (or the
  /// simulator itself) derived a seed — typically from the system
  /// clock — and the driver records it here so the run can still be
  /// reproduced.
  ///
  /// Null when no seed was used or when the driver could not surface
  /// the seed it ran with (some legacy testbench harnesses do not
  /// echo the seed they consumed).
  ///
  /// The Pro overlay's `FlakyRetryPolicy` reads this when a
  /// flaky test is being retried: the first retry attempts a
  /// deterministic replay with the same seed; subsequent retries roll
  /// new seeds to gather varied evidence.
  final int? executionSeed;

  /// The cartesian-product parameter slice this result was produced
  /// from, mirroring `TestSpec.parameters` at execution time.
  ///
  /// Populated by the scheduler from the originating [TestSpec] so
  /// that the persistent result store retains the parameter binding
  /// context even after the in-memory `TestSpec` is gone. Pro re-run
  /// workflows read this to re-issue a test with the exact slice it
  /// originally ran with — without re-parsing the synthesized
  /// [testId].
  ///
  /// Null when the originating spec was unparameterized.
  final Map<String, String>? boundParameters;

  /// On results produced from an expanded child spec, the [TestSpec.id]
  /// of the un-expanded template that produced the spec. Mirrors
  /// `TestSpec.parentSpecId` so the Pro "Re-run all in this parameter
  /// group" workflow can group results by their template id without
  /// touching the in-memory spec list.
  ///
  /// Null on results from unparameterized specs.
  final String? parentSpecId;

  /// The terminal signal the process reaper delivered when this test was
  /// cancelled or timed out, or null when the process exited on its own
  /// (every clean pass/fail). `SIGTERM` means the process honoured the
  /// graceful request; `SIGKILL` means it ignored SIGTERM and had to be
  /// force-killed after the grace window. Persisted into the streaming
  /// `results.ndjson` so the recorded outcome encodes the kill *path*.
  final KillSignal? killSignal;

  /// Whether the simulator actually ran for this result.
  ///
  /// `false` for runs that never launched the toolchain — the binary
  /// was not found ([SimulatorNotAvailableException]) or no driver was
  /// registered. Such "broken infra" outcomes are still surfaced in the
  /// dashboard (as a [TestStatus.fail] / [TestStatus.unknown] row so the
  /// user sees a signal), but they are excluded from the trend store and
  /// therefore from the flakiness window — a missing `iverilog` is not a
  /// flaky test. Defaults to `true` (every genuinely executed run).
  final bool didExecute;

  /// Wall-clock runtime (`finishedAt - startedAt`).
  Duration get runtime => finishedAt.difference(startedAt);

  /// Returns a copy with the given fields replaced.
  ///
  /// Pass `clearBoundParameters: true` to produce a copy with
  /// `boundParameters = null`; pass `clearParentSpecId: true` for the
  /// matching parent-id field. The standard `copyWith` null-means-
  /// keep-existing convention applies otherwise.
  TestResult copyWith({
    String? testId,
    String? runId,
    TestStatus? status,
    DateTime? startedAt,
    DateTime? finishedAt,
    int? exitCode,
    String? stdoutPath,
    String? stderrPath,
    String? waveformPath,
    String? failureMessage,
    Map<String, String>? metrics,
    int? executionSeed,
    Map<String, String>? boundParameters,
    String? parentSpecId,
    KillSignal? killSignal,
    bool? didExecute,
    bool clearBoundParameters = false,
    bool clearParentSpecId = false,
  }) {
    return TestResult(
      testId: testId ?? this.testId,
      runId: runId ?? this.runId,
      status: status ?? this.status,
      startedAt: startedAt ?? this.startedAt,
      finishedAt: finishedAt ?? this.finishedAt,
      exitCode: exitCode ?? this.exitCode,
      stdoutPath: stdoutPath ?? this.stdoutPath,
      stderrPath: stderrPath ?? this.stderrPath,
      waveformPath: waveformPath ?? this.waveformPath,
      failureMessage: failureMessage ?? this.failureMessage,
      metrics: metrics ?? this.metrics,
      executionSeed: executionSeed ?? this.executionSeed,
      boundParameters: clearBoundParameters
          ? null
          : (boundParameters ?? this.boundParameters),
      parentSpecId: clearParentSpecId
          ? null
          : (parentSpecId ?? this.parentSpecId),
      killSignal: killSignal ?? this.killSignal,
      didExecute: didExecute ?? this.didExecute,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! TestResult) return false;
    if (other.testId != testId) return false;
    if (other.runId != runId) return false;
    if (other.status != status) return false;
    if (other.startedAt != startedAt) return false;
    if (other.finishedAt != finishedAt) return false;
    if (other.exitCode != exitCode) return false;
    if (other.stdoutPath != stdoutPath) return false;
    if (other.stderrPath != stderrPath) return false;
    if (other.waveformPath != waveformPath) return false;
    if (other.failureMessage != failureMessage) return false;
    if (other.metrics.length != metrics.length) return false;
    for (final entry in metrics.entries) {
      if (other.metrics[entry.key] != entry.value) return false;
    }
    if (other.executionSeed != executionSeed) return false;
    if (!_nullableMapEq(other.boundParameters, boundParameters)) return false;
    if (other.parentSpecId != parentSpecId) return false;
    if (other.killSignal != killSignal) return false;
    if (other.didExecute != didExecute) return false;
    return true;
  }

  @override
  int get hashCode => Object.hash(
    testId,
    runId,
    status,
    startedAt,
    finishedAt,
    exitCode,
    stdoutPath,
    stderrPath,
    waveformPath,
    failureMessage,
    Object.hashAllUnordered(
      metrics.entries.map((e) => Object.hash(e.key, e.value)),
    ),
    executionSeed,
    boundParameters == null
        ? null
        : Object.hashAllUnordered(
            boundParameters!.entries.map((e) => Object.hash(e.key, e.value)),
          ),
    parentSpecId,
    killSignal,
    didExecute,
  );
}

bool _nullableMapEq<K, V>(Map<K, V>? a, Map<K, V>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}
