// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:crux_io/crux_io.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/services/job_scheduler/local_job_scheduler.dart';
import 'package:simcrux/services/job_scheduler/process_reaper.dart';
import 'package:simcrux/services/simulator/simulator_not_available_exception.dart';

/// Shared base for every [SimulatorDriver] that shells out to a
/// subprocess toolchain (Icarus, GHDL, Verilator, Cocotb, and the
/// RISC-V drivers).
///
/// It owns the machinery common to every subprocess-backed driver:
///
/// - the [ProcessReaper] plumbing + `NoopProcessReaper` default so an
///   injected launcher and the production platform reaper both work;
/// - the live-process registry that [cancel] terminates;
/// - `cancel` itself (SIGTERM → SIGKILL-after-[killGrace] via the
///   reaper), identical across every subclass;
/// - binary resolution across `bundled` / `system` / `custom` sources
///   ([resolveBinary]);
/// - the `--version`-style probe ([detectVersionOf]);
/// - the `execute` stream scaffolding + stdout/stderr collection +
///   `ProcessException` → [SimulatorNotAvailableException] mapping +
///   terminal-event drain ordering ([runProcessStreaming]).
///
/// Subclasses supply only what genuinely differs: [id] / [displayName]
/// / [capabilities], [detectVersion], [compile], and [runExecute]
/// (the per-driver pre-spawn command construction, which then calls
/// [runProcessStreaming] with the driver-specific labels + a
/// terminal-event builder). The driver tests and the orchestration
/// fixtures cover both the shared base and each subclass's delta.
abstract class ProcessBackedSimulatorDriver implements SimulatorDriver {
  /// Base constructor wiring the reaper + kill-grace shared by every
  /// subclass. [launcher] is injected so tests can drive the driver
  /// against a scripted `TestProcess`; production passes a
  /// [ProcessReaper] so a runaway child is reaped as a process tree.
  ProcessBackedSimulatorDriver({
    ProcessLauncher? launcher,
    ProcessReaper? reaper,
    this.killGrace = const Duration(seconds: 5),
  }) : reaper =
           reaper ??
           NoopProcessReaper(launcher: launcher ?? defaultProcessLauncher);

  /// Process reaper the driver spawns and reaps through. Defaults to a
  /// [NoopProcessReaper] wrapping the (optional) injected launcher so
  /// the single-PID behaviour and existing tests are unchanged; the
  /// scheduler wires the platform `processReaperProvider` in production
  /// so the whole process tree is reaped.
  @protected
  final ProcessReaper reaper;

  /// Grace period between SIGTERM (initial [cancel] invocation) and the
  /// follow-on SIGKILL the reaper sends if the process is still alive.
  /// Defaults to 5 seconds; tests may shrink it.
  final Duration killGrace;

  // ── live state ─────────────────────────────────────────────────────
  final Map<String, ReapableProcess> _liveProcesses =
      <String, ReapableProcess>{};

  /// Registers [process] as the live subprocess for [testId] so a later
  /// [cancel] can terminate it. Subclasses call this after a successful
  /// spawn in their `compile` stages; [runProcessStreaming] handles it
  /// for the execute stage.
  @protected
  void trackProcess(String testId, ReapableProcess process) {
    _liveProcesses[testId] = process;
  }

  /// Removes the live-process record for [testId] (on completion or
  /// error). Idempotent.
  @protected
  void untrackProcess(String testId) {
    _liveProcesses.remove(testId);
  }

  @override
  void cancel(String testId) {
    final process = _liveProcesses[testId];
    if (process == null) return;
    // The reaper sends SIGTERM to the whole process tree and escalates
    // to SIGKILL after [killGrace] if any member ignored it, recording
    // the terminal signal on the handle.
    unawaited(reaper.terminateTree(process, grace: killGrace));
  }

  /// Returns [extra] augmented so a GUI-launched app can still find the EDA
  /// engines an interactive shell would resolve.
  ///
  /// A macOS Finder/Dock launch inherits `launchd`'s truncated `$PATH`
  /// (missing Homebrew's `/opt/homebrew/bin` / `/usr/local/bin`), and a
  /// Windows app launched from a stale shell or an installer's "launch now"
  /// carries an older process `PATH` that can omit engines the user has
  /// since added (e.g. oss-cad-suite). Either way an `iverilog` /
  /// `verilator` spawn fails "not available" even though the engine is
  /// installed. We append the platform's [engineSearchDirs] to the child's
  /// `PATH` (which otherwise merges from this process's environment). No-op
  /// on Linux, when the dirs are already on `PATH`, and when the caller
  /// supplied an explicit `PATH` in [extra] (a user-configured PATH is
  /// authoritative and is never clobbered).
  @protected
  Map<String, String>? augmentEnvironment(Map<String, String>? extra) {
    final hasExplicitPath =
        extra?.keys.any((k) => k.toUpperCase() == 'PATH') ?? false;
    if (hasExplicitPath) return extra;
    final dirs = engineSearchDirs();
    if (dirs.isEmpty) return extra;
    final augmented = appendMissingPathDirs(
      Platform.environment['PATH'] ?? '',
      dirs,
      separator: Platform.isWindows ? ';' : ':',
      caseInsensitive: Platform.isWindows,
    );
    if (augmented == null) return extra;
    return <String, String>{...?extra, 'PATH': augmented};
  }

  /// Resolves [defaultBinary] against [config]'s source:
  ///
  /// - `bundled` / `system` → [defaultBinary] verbatim (host `$PATH`
  ///   or the bundled-binary absolute path the caller already baked in).
  /// - `custom` → either `config.customPath` itself when it already
  ///   names this binary, or `customPath/defaultBinary` when it names a
  ///   directory holding the toolchain.
  @protected
  String resolveBinary(SimulatorBinaryConfig config, String defaultBinary) {
    switch (config.source) {
      case SimulatorBinarySource.bundled:
      case SimulatorBinarySource.system:
        return defaultBinary;
      case SimulatorBinarySource.custom:
        final customPath = config.customPath;
        if (customPath == null || customPath.isEmpty) return defaultBinary;
        final base = p.basename(customPath);
        if (base == defaultBinary) return customPath;
        return p.join(customPath, defaultBinary);
    }
  }

  /// Runs `binary <versionArgs>` and returns the first non-empty output
  /// line (the toolchain's banner), or `null` when the probe fails,
  /// exits non-zero, or the binary can't be invoked. stdout and stderr
  /// are both consulted because different toolchains print the banner
  /// on different streams.
  @protected
  Future<String?> detectVersionOf(
    String binary, {
    List<String> versionArgs = const <String>['--version'],
  }) async {
    try {
      final process = await reaper.spawnGrouped(
        binary,
        versionArgs,
        environment: augmentEnvironment(null),
      );
      final stdout = await process.stdout.toList();
      final stderr = await process.stderr.toList();
      final exit = await process.exitCode;
      if (exit != 0) return null;
      final lines = <String>[
        ...stdout,
        ...stderr,
      ].where((l) => l.trim().isNotEmpty).toList(growable: false);
      if (lines.isEmpty) return null;
      return lines.first.trim();
    } on Object {
      return null;
    }
  }

  @override
  Stream<TestExecutionEvent> execute(ExecuteRequest request) {
    final controller = StreamController<TestExecutionEvent>();
    final startedAt = DateTime.now().toUtc();
    unawaited(
      // [runProcessStreaming] only guards the spawn and the streams. Anything
      // a driver throws while building its command line (a bad option value,
      // a file it cannot stage) used to escape here: the stream never ended,
      // so the scheduler waited out the test's timeout and reported `timeout`,
      // and in the standalone binary — which runs in no guarded zone — the
      // uncaught error ended the process with exit 255 mid-regression.
      runExecute(request, controller).catchError((Object error) async {
        if (controller.isClosed) return;
        controller.add(
          TestExecutionFinished(
            status: TestStatus.unknown,
            exitCode: null,
            startedAt: startedAt,
            finishedAt: DateTime.now().toUtc(),
            failureMessage: 'driver error: $error',
          ),
        );
        await controller.close();
      }),
    );
    return controller.stream;
  }

  /// Per-driver execute body: resolve the binary + build the command
  /// line + seed handling, then delegate to [runProcessStreaming].
  /// Invoked once per [execute] call with a fresh [controller].
  @protected
  Future<void> runExecute(
    ExecuteRequest request,
    StreamController<TestExecutionEvent> controller,
  );

  /// Spawns [executable] with [args], streams its stdout/stderr as
  /// [TestLogLine] events (after invoking the optional [onLine] side
  /// effect per line, e.g. bounded capture for summary parsing), drains
  /// both streams before the terminal event, and emits the
  /// [TestExecutionFinished] that [buildFinished] returns.
  ///
  /// Failure handling is identical to the per-driver code it replaces:
  ///
  /// - a `ProcessException` at spawn adds a
  ///   [SimulatorNotAvailableException] error carrying
  ///   [unavailableBinaryLabel] and a terminal `unknown`
  ///   [TestExecutionFinished] whose message is [unavailableMessage],
  ///   then closes;
  /// - any other error after spawn adds a `driver error:` terminal
  ///   `unknown` event and closes.
  ///
  /// The live-process registry is maintained around the run so [cancel]
  /// can terminate an in-flight execution.
  ///
  /// [workingDirectoryOverride] spawns the process somewhere other than
  /// the test's working directory. Used by the `riscv_formal`
  /// driver, which must run `sby` from the directory holding the `.sby`
  /// file — riscv-formal's generated jobs reference their sources
  /// relative to it — while `sby -d` still writes every artifact into the
  /// test's working directory, so the counterexample VCD lands where the
  /// scheduler's retain-on-failure rule protects it. Every other driver
  /// omits it and keeps the existing behavior exactly.
  @protected
  Future<void> runProcessStreaming({
    required ExecuteRequest request,
    required String executable,
    required List<String> args,
    required DateTime startedAt,
    required StreamController<TestExecutionEvent> controller,
    required String unavailableBinaryLabel,
    required String unavailableMessage,
    required Future<TestExecutionFinished> Function(
      int? exitCode,
      ReapableProcess process,
    )
    buildFinished,
    Map<String, String>? environment,
    void Function(String line, {required bool fromStderr})? onLine,
    String? workingDirectoryOverride,
  }) async {
    ReapableProcess? process;
    int? exitCode;
    try {
      try {
        process = await reaper.spawnGrouped(
          executable,
          args,
          environment: augmentEnvironment(environment),
          workingDirectory:
              workingDirectoryOverride ?? request.workingDirectory,
        );
      } on ProcessException catch (e) {
        controller
          ..addError(
            SimulatorNotAvailableException(
              simulatorId: id,
              binary: unavailableBinaryLabel,
              source: request.binaryConfig.source,
              cause: e,
            ),
          )
          ..add(
            TestExecutionFinished(
              status: TestStatus.unknown,
              exitCode: null,
              startedAt: startedAt,
              finishedAt: DateTime.now().toUtc(),
              failureMessage: unavailableMessage,
            ),
          );
        await controller.close();
        return;
      }
      trackProcess(request.test.id, process);

      final stdoutDone = Completer<void>();
      final stderrDone = Completer<void>();
      final stdoutSub = process.stdout.listen(
        (line) {
          onLine?.call(line, fromStderr: false);
          controller.add(
            TestLogLine(
              line: line,
              fromStderr: false,
              timestamp: DateTime.now().toUtc(),
            ),
          );
        },
        onDone: () {
          if (!stdoutDone.isCompleted) stdoutDone.complete();
        },
        // A decoder/transform error on the pipe would otherwise never
        // complete `stdoutDone`, hanging the drain below until the
        // scheduler's per-test timeout fires. Surface the error as a
        // stderr log line and release the drain.
        onError: (Object error) {
          onLine?.call('stdout stream error: $error', fromStderr: true);
          if (!stdoutDone.isCompleted) stdoutDone.complete();
        },
      );
      final stderrSub = process.stderr.listen(
        (line) {
          onLine?.call(line, fromStderr: true);
          controller.add(
            TestLogLine(
              line: line,
              fromStderr: true,
              timestamp: DateTime.now().toUtc(),
            ),
          );
        },
        onDone: () {
          if (!stderrDone.isCompleted) stderrDone.complete();
        },
        onError: (Object error) {
          onLine?.call('stderr stream error: $error', fromStderr: true);
          if (!stderrDone.isCompleted) stderrDone.complete();
        },
      );
      try {
        exitCode = await process.exitCode;
        // Drain stdout / stderr before reporting the terminal event, so
        // log lines and the TestExecutionFinished event arrive on the
        // stream in the correct order.
        await Future.wait<void>([stdoutDone.future, stderrDone.future]);
      } finally {
        await stdoutSub.cancel();
        await stderrSub.cancel();
        untrackProcess(request.test.id);
      }
    } on Object catch (e) {
      controller.add(
        TestExecutionFinished(
          status: TestStatus.unknown,
          exitCode: exitCode,
          startedAt: startedAt,
          finishedAt: DateTime.now().toUtc(),
          failureMessage: 'driver error: $e',
        ),
      );
      await controller.close();
      return;
    }

    final finished = await buildFinished(exitCode, process);
    controller.add(finished);
    await controller.close();
  }
}
