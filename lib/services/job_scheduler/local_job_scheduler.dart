// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crux_io/crux_io.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/kill_signal.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/enums/waveform_capture_policy.dart';
import 'package:simcrux/domain/interfaces/job_scheduler.dart';
import 'package:simcrux/domain/interfaces/retry_policy.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/bounded_log_capture.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/regression_request.dart';
import 'package:simcrux/domain/models/resource_lock.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/job_scheduler/dump_retention.dart';
import 'package:simcrux/services/job_scheduler/resource_lock_table.dart';
import 'package:simcrux/services/job_scheduler/semaphore.dart';
import 'package:simcrux/services/job_scheduler/waveform_archive.dart';
import 'package:simcrux/services/pass_fail_detector/pass_fail_detector_registry.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';
import 'package:simcrux/services/simulator/simulator_not_available_exception.dart';

/// Process-spawning hook. Production wires this to `Process.start`
/// (`dart:io`); tests inject a fake [TestProcess] that emits a
/// scripted exit code and log stream without touching the OS.
typedef ProcessLauncher =
    Future<TestProcess> Function(
      String executable,
      List<String> args, {
      Map<String, String>? environment,
      String? workingDirectory,
    });

/// Minimal `Process` shape exposed to scheduler/driver code so the
/// hot path is testable without spawning real subprocesses. Thin
/// wrapper around `dart:io`'s `Process` for production use.
abstract class TestProcess {
  /// Stream of stdout lines (no trailing newline).
  Stream<String> get stdout;

  /// Stream of stderr lines (no trailing newline).
  Stream<String> get stderr;

  /// Future that completes with the process exit code.
  Future<int> get exitCode;

  /// Signal the process to terminate. Drivers send SIGTERM first and
  /// (after a grace period inside the driver) escalate to SIGKILL.
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]);
}

/// `Process.start`'s shape, as far as [defaultProcessLauncher] uses it.
typedef ProcessStarter =
    Future<Process> Function(
      String executable,
      List<String> args, {
      Map<String, String>? environment,
      String? workingDirectory,
    });

/// Default [ProcessLauncher] backed by `dart:io`'s `Process.start`.
///
/// The executable is resolved through `crux_io` before the spawn
/// ([SpawnHost.requireExecutable]). On Windows a bare `iverilog` or
/// `verilator` is otherwise searched for in the directory SimCrux was
/// launched from before `PATH`, and a user launches SimCrux from inside the
/// repository whose tests it runs, so a same-named binary committed there
/// would run in place of the engine. [environment] is the child's own
/// environment, so an engine found only through the `PATH` a driver appends
/// still resolves. An engine found nowhere throws the `ProcessException` a
/// missing binary throws, which the drivers already report as "not
/// available", with nothing spawned. Off Windows the resolution is the
/// identity.
///
/// [host] and [start] are injectable so a test can prove the Windows branch
/// on any machine; both default to the live process.
Future<TestProcess> defaultProcessLauncher(
  String executable,
  List<String> args, {
  Map<String, String>? environment,
  String? workingDirectory,
  SpawnHost? host,
  ProcessStarter start = Process.start,
}) async {
  final resolved = (host ?? SpawnHost.current()).requireExecutable(
    executable,
    childEnvironment: environment,
  );
  final process = await start(
    resolved,
    args,
    environment: environment,
    workingDirectory: workingDirectory,
  );
  return _DartIoTestProcess(process);
}

class _DartIoTestProcess implements TestProcess {
  _DartIoTestProcess(this._process);

  final Process _process;

  @override
  Stream<String> get stdout => _process.stdout
      .transform(const SystemEncoding().decoder)
      .transform(const LineSplitter());

  @override
  Stream<String> get stderr => _process.stderr
      .transform(const SystemEncoding().decoder)
      .transform(const LineSplitter());

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) =>
      _process.kill(signal);
}

/// Open-core [JobScheduler] implementation: a semaphore-bounded local
/// driver dispatcher.
///
/// For each [TestSpec], the scheduler:
///
/// 1. Acquires the global concurrency semaphore + any declared
///    resource locks.
/// 2. Allocates a per-test working directory under
///    `{runRoot}/runs/{runId}/{testIdSafe}/`.
/// 3. Looks up the matching [SimulatorDriver] for the test's
///    `simulatorId` and the [SimulatorBinaryConfig] from the project
///    config; invokes `driver.compile` (when the driver declares it
///    requires a separate compile step), then `driver.execute`.
/// 4. Forwards driver events as [RegressionEvent]s on the run's
///    stream, capturing stdout / stderr buffers for the pass/fail
///    classifier.
/// 5. Re-classifies the driver's best-guess [TestStatus] through the
///    configured [PassFailDetectorRegistry] using each test's own
///    [TestSpec.passFail].
/// 6. Enforces the per-test timeout — fires `driver.cancel(testId)`
///    (the driver sends SIGTERM and internally escalates to SIGKILL
///    after its own grace period).
/// 7. On success, removes the test's working directory; on failure,
///    retains it so the user can inspect logs and reproduce the run.
class LocalJobScheduler implements JobScheduler {
  /// Creates a [LocalJobScheduler] driven by [driverRegistry].
  ///
  /// [config] supplies the per-simulator [SimulatorBinaryConfig]s
  /// that drivers consult to locate their binaries (bundled, system,
  /// or custom). [runRoot] is the base directory under which
  /// per-test working directories are created — defaults to a
  /// system temp directory when null. [retainSuccessfulWorkDirs] is
  /// off by default so the on-disk footprint stays small for clean
  /// regression runs; failing tests' work dirs are always retained.
  LocalJobScheduler({
    required this.driverRegistry,
    required this.config,
    String? runRoot,
    this.passFailRegistry = const PassFailDetectorRegistry(),
    this.retainSuccessfulWorkDirs = false,
    this.retryPolicy = const NoopRetryPolicy(),
    this.maxRetryCeiling = kDefaultMaxRetryCeiling,
    this.maxCapturedLogLines = BoundedLogCapture.kDefaultMaxCapturedLogLines,
    this.dumpRetentionPolicy = DumpRetentionPolicy.unbounded,
    this.passingWaveformArchive,
    this.passingWaveformRetentionPolicy = DumpRetentionPolicy.unbounded,
  }) : runRoot = runRoot ?? Directory.systemTemp.path;

  /// Scheduler-side hard ceiling on retry attempts per test.
  ///
  /// A misbehaving [RetryPolicy] cannot drive the scheduler into an
  /// infinite loop because the per-test execution path also enforces
  /// `attemptsSoFar <= maxRetryCeiling`. The default matches the
  /// typical Pro `FlakinessConfig.autoRetryAttempts` budget plus a
  /// safety margin.
  static const int kDefaultMaxRetryCeiling = 5;

  /// The registry of available simulator drivers.
  final SimulatorDriverRegistry driverRegistry;

  /// The project configuration the run is scheduled against.
  final RegressionConfig config;

  /// Used to classify the driver's best-guess status into the final
  /// [TestStatus] using each [TestSpec.passFail] strategy.
  final PassFailDetectorRegistry passFailRegistry;

  /// If true, work directories from passing tests are retained on
  /// disk alongside failing-test directories. Defaults to false.
  final bool retainSuccessfulWorkDirs;

  /// Base directory under which per-test working directories are
  /// allocated. Defaults to the system temp directory when the
  /// constructor's `runRoot` is null.
  final String runRoot;

  /// Active retry policy. Open-core ships [NoopRetryPolicy]; the Pro
  /// overlay injects `FlakyRetryPolicy` via `retryPolicyProvider`.
  final RetryPolicy retryPolicy;

  /// Hard scheduler-side ceiling on per-test attempt count
  /// (1 = original + 0 retries; 2 = original + 1 retry; …). Even if
  /// [retryPolicy] returns true beyond this many attempts the
  /// scheduler stops retrying. Provides a guard against buggy policies
  /// that would otherwise loop indefinitely.
  final int maxRetryCeiling;

  /// Per-test captured-log ceiling fed to [BoundedLogCapture]. Bounds the
  /// in-memory stdout/stderr the pass/fail detector classifies against so
  /// a chatty UVM testbench cannot grow the working set without limit.
  /// The most recent lines are retained (head-dropped).
  final int maxCapturedLogLines;

  /// Retention policy applied to the run's per-test working directories
  /// (and their waveform dumps) after the run completes. Defaults to
  /// [DumpRetentionPolicy.unbounded] (historical behaviour: retain every
  /// failure dir). The `jobSchedulerProvider` wires the
  /// `dumpRetentionPolicyProvider` policy in production so retained dumps
  /// are bounded.
  final DumpRetentionPolicy dumpRetentionPolicy;

  /// Durable archive for the waveform dumps of *passing* tests.
  ///
  /// A passing test's work dir (and its dump) is deleted the moment it
  /// finishes, which would leave "Debug in WaveCrux" and the inspector's
  /// waveform view handing off a path into an already-deleted temp directory.
  /// When set, a passing test's dump is relocated into this archive before the
  /// work dir is swept, and the recorded `waveformPath` points at the durable
  /// copy. Null (the default, and in tests) means no relocation: a passing
  /// test's dump is deleted with its work dir and the path is not recorded.
  final WaveformArchive? passingWaveformArchive;

  /// Retention policy applied to [passingWaveformArchive] after each run.
  ///
  /// Deliberately a **separate** budget from [dumpRetentionPolicy]: archived
  /// passing waveforms and retained failing-test work dirs must never evict
  /// one another. Defaults to [DumpRetentionPolicy.unbounded]; the
  /// `jobSchedulerProvider` wires a bounded pool policy in production.
  final DumpRetentionPolicy passingWaveformRetentionPolicy;

  /// Number of terminal run statuses retained by [statusOf] after the
  /// run's mutable state has been released. Bounds the scheduler's
  /// steady-state footprint: a long-lived scheduler serving repeated
  /// runs cannot accumulate event sinks, driver handles, and lock maps
  /// forever, but recently-finished runs still answer `statusOf`.
  static const int kRetainedFinishedRuns = 32;

  // ── live state ──────────────────────────────────────────────────────
  final Map<String, _RunState> _runs = <String, _RunState>{};

  /// Terminal snapshots of released runs, insertion-ordered so the
  /// oldest is evicted first once [kRetainedFinishedRuns] is exceeded.
  final Map<String, RegressionStatus> _finishedRuns =
      <String, RegressionStatus>{};

  @override
  Map<String, ResourceLock> get heldLocks {
    final result = <String, ResourceLock>{};
    for (final run in _runs.values) {
      result.addAll(run.heldLocks);
    }
    return Map<String, ResourceLock>.unmodifiable(result);
  }

  /// Drops [state]'s mutable per-run state (event sink, live-driver
  /// handles, held locks, lock waiters) once the run has emitted
  /// [RegressionFinished], retaining only its terminal
  /// [RegressionStatus] for [statusOf].
  void _releaseRun(_RunState state) {
    final runId = state.request.runId;
    _runs.remove(runId);
    _finishedRuns[runId] = RegressionStatus(
      runId: runId,
      totalTests: state.totalTests,
      completedTests: state.completedCount,
      runningTests: 0,
      isFinished: true,
    );
    while (_finishedRuns.length > kRetainedFinishedRuns) {
      _finishedRuns.remove(_finishedRuns.keys.first);
    }
  }

  @override
  RegressionStatus statusOf(String runId) {
    final run = _runs[runId];
    if (run == null) {
      final finished = _finishedRuns[runId];
      if (finished != null) return finished;
      return RegressionStatus(
        runId: runId,
        totalTests: 0,
        completedTests: 0,
        runningTests: 0,
        isFinished: true,
      );
    }
    return RegressionStatus(
      runId: runId,
      totalTests: run.totalTests,
      completedTests: run.completedCount,
      runningTests: run.runningCount,
      isFinished: run.isFinished,
    );
  }

  @override
  Stream<RegressionEvent> submit(RegressionRequest request) {
    final controller = StreamController<RegressionEvent>();
    final state = _RunState(
      request: request,
      semaphore: Semaphore(
        request.concurrency < 1 ? 1 : request.concurrency,
      ),
      eventSink: controller,
    );
    _runs[request.runId] = state;
    controller
      ..onListen = () {
        unawaited(_executeRun(state));
      }
      ..onCancel = () async {
        await _cancel(state);
      };
    return controller.stream;
  }

  @override
  Future<void> cancel(String runId) async {
    final state = _runs[runId];
    if (state == null) return;
    await _cancel(state);
  }

  // ── implementation ──────────────────────────────────────────────────

  Future<void> _executeRun(_RunState state) async {
    // Give a preparable retry policy the chance to warm any async state
    // its synchronous `shouldRetry` decisions read from (the Pro
    // `FlakyRetryPolicy` bulk-loads flaky-detection scores here) before the
    // first test — and therefore the first failure — is dispatched.
    // Best-effort: a priming failure degrades to the policy's cold-cache
    // behavior (conservative "no retry") rather than aborting the run.
    final policy = retryPolicy;
    if (policy is PreparableRetryPolicy) {
      try {
        await (policy as PreparableRetryPolicy).prepareForRun(
          state.request.tests,
        );
      } on Object {
        // Swallow: retry priming is an optimization, not a run gate.
      }
    }
    final futures = <Future<void>>[];
    for (final spec in state.request.tests) {
      futures.add(_runOne(state, spec));
    }
    await Future.wait(futures);
    // Bound the retained per-test working dirs + waveform dumps:
    // keep the most recent N failures under a total-byte ceiling so the
    // retained set cannot fill the disk across months of nightly runs.
    //
    // The prune is deliberately **cross-run** — it ranks every retained
    // directory under `<runRoot>/runs/`, not just the run that just
    // finished. Pruning only the current run enforced the cap per run,
    // which times unboundedly many nightly runs is no cap at all: the
    // exact growth the policy exists to stop.
    //
    // Off-isolate: the recursive walk + stat per file + recursive
    // deletes are seconds of blocking IO on a large tree, so the prune
    // runs via Isolate.run — awaited here so RegressionFinished still
    // means "retention has been enforced", without freezing the UI.
    if (!dumpRetentionPolicy.isUnbounded) {
      // Exclude every *other* in-flight run's directory from the cross-run
      // prune: another tab's live run must never have its work dir ranked
      // and deleted under the running simulator by the byte ceiling. The
      // run that just finished (this `state`) is still in `_runs` here — it
      // is deliberately prunable, so it is not excluded.
      final inFlight = _runs.keys
          .where((id) => id != state.request.runId)
          .toSet();
      // Guard the await: the off-isolate walk can throw a FileSystemException
      // when two tabs prune the same tree near-simultaneously. Unguarded, that
      // exception skips markFinished / RegressionFinished / eventSink.close,
      // wedging the run in "running" forever. Retention is best-effort; run
      // completion is not.
      try {
        await pruneRetainedDumpsAcrossRunsAsync(
          runsRootFor(runRoot),
          dumpRetentionPolicy,
          excludeRunIds: inFlight,
        );
      } on Object {
        // Swallow: a failed prune leaves extra dumps on disk (bounded next
        // run); it must never block this run from reporting finished.
      }
    }
    // Bound the passing-waveform archive with its OWN budget, kept separate
    // from the failing-work-dir retention above so archived passing waveforms
    // and failing-test dirs never evict one another. Best-effort, off-isolate,
    // and — like the retention prune — never allowed to block run completion.
    final archive = passingWaveformArchive;
    if (archive != null && !passingWaveformRetentionPolicy.isUnbounded) {
      try {
        await archive.prune(passingWaveformRetentionPolicy);
      } on Object {
        // Swallow: a failed archive prune leaves extra waveforms on disk
        // (bounded next run); run completion must not depend on it.
      }
    }
    state.markFinished();
    state.eventSink.add(
      RegressionFinished(
        runId: state.request.runId,
        cancelled: state.cancelled,
      ),
    );
    await state.eventSink.close();
    // Release the run's mutable state now that it is terminal. Held
    // before this point because `heldLocks` and `statusOf` read it
    // live; after it, only the terminal status is worth retaining.
    _releaseRun(state);
  }

  Future<void> _runOne(_RunState state, TestSpec spec) async {
    // Acquire concurrency permit first so two contending tests cannot
    // both occupy permits while waiting on each other for a shared
    // resource lock.
    await state.semaphore.acquire();
    if (state.cancelled) {
      state.semaphore.release();
      state.completedCount++;
      return;
    }

    final lockHandles = <Future<void>>[];
    for (final lock in spec.resources) {
      lockHandles.add(state.acquireResourceLock(lock));
    }
    await Future.wait(lockHandles);
    if (state.cancelled) {
      state.releaseResourceLocks(spec.resources);
      state.semaphore.release();
      state.completedCount++;
      return;
    }

    state.runningCount++;
    state.eventSink.add(
      TestStarted(runId: state.request.runId, testId: spec.id),
    );

    // Per-test attempt loop. The semaphore + resource locks are held
    // across retries because a flaky retry should reuse the same
    // hardware / simulator-license slot that was just acquired.
    var attemptSpec = spec;
    var attemptsSoFar = 0;
    late TestResult result;
    while (true) {
      attemptsSoFar++;
      result = await _executeAttempt(state, attemptSpec);
      final classified = result.status;
      // Cancellation, success-equivalents, and the hard ceiling all
      // short-circuit the retry consultation.
      if (state.cancelled) break;
      if (classified == TestStatus.pass ||
          classified == TestStatus.vacuous ||
          classified == TestStatus.cover) {
        break;
      }
      if (attemptsSoFar >= maxRetryCeiling) break;
      final maxAttempts = maxRetryCeiling;
      final shouldRetry = retryPolicy.shouldRetry(
        spec: attemptSpec,
        lastResult: result,
        attemptsSoFar: attemptsSoFar,
        maxAttempts: maxAttempts,
      );
      if (!shouldRetry) break;
      final nextSeed = retryPolicy.nextSeedFor(
        spec: attemptSpec,
        lastResult: result,
        attemptsSoFar: attemptsSoFar,
      );
      // Pin the seed for the next attempt (deterministic replay on
      // first retry; varied seed on subsequent retries). If the policy
      // returns null, retain the spec's existing seed.
      attemptSpec = nextSeed == null
          ? attemptSpec
          : attemptSpec.copyWith(seed: nextSeed);
    }

    state.eventSink.add(
      TestFinished(runId: state.request.runId, result: result),
    );

    state.runningCount--;
    state.completedCount++;
    state.releaseResourceLocks(spec.resources);
    state.semaphore.release();
  }

  /// Runs one attempt of [spec] (compile + execute + classify) and
  /// returns the per-attempt [TestResult] without emitting it to the
  /// event sink. Called once for the original run and once per retry
  /// by [_runOne].
  Future<TestResult> _executeAttempt(_RunState state, TestSpec spec) async {
    final startedAt = DateTime.now().toUtc();
    final timeout = spec.timeout != Duration.zero
        ? spec.timeout
        : state.request.defaultTimeout;

    String? workDir;
    var status = TestStatus.unknown;
    // Cleared when the run never launched the toolchain (no driver, or the
    // binary was not found). Such infra/launch failures are surfaced in the
    // dashboard but excluded from the trend store / flakiness window.
    var didExecute = true;
    int? exitCode;
    String? waveformPath;
    String? failureMessage;
    KillSignal? killSignal;
    int? effectiveSeed;
    var metrics = const <String, String>{};
    // Bounded, head-dropping ring: a chatty UVM testbench cannot
    // grow an unbounded capture string before the detector runs.
    final stdoutBuf = BoundedLogCapture(maxLines: maxCapturedLogLines);
    final stderrBuf = BoundedLogCapture(maxLines: maxCapturedLogLines);

    try {
      // Resolve through the async path so
      // plugin-contributed drivers are considered alongside built-ins.
      // Built-ins win on name collision (precedence enforced inside
      // `SimulatorDriverRegistry.resolveDriverFor`).
      final driver = await driverRegistry.resolveDriverFor(spec.simulatorId);
      if (driver == null) {
        failureMessage =
            'No simulator driver registered for `${spec.simulatorId}`.';
        status = TestStatus.unknown;
        didExecute = false;
      } else {
        workDir = _allocateWorkDir(state.request.runId, spec.id);
        final binaryConfig =
            config.simulatorBinaries[spec.simulatorId] ??
            SimulatorBinaryConfig(simulatorId: spec.simulatorId);

        // Compile pass (drivers may report it is a no-op). The
        // attempt's bounded captures are handed straight to the driver
        // so compile output is ring-bounded as it streams — not after
        // the driver has already materialized an unbounded string.
        if (driver.capabilities.requiresSeparateCompileStep) {
          // Register the live test before the compile pass so a cancel or
          // AppExit arriving mid-compile routes driver.cancel(testId) to the
          // driver's tracked compile process. Without this the compile stage
          // is invisible to _cancel (which only iterates liveTests), so a
          // long Verilator/GHDL compile would otherwise survive cancel and
          // orphan on quit. _runExecute re-registers idempotently for the
          // execute stage.
          state.registerLiveTest(spec.id, driver);
          // Bound the compile pass with the same timeout budget the execute
          // stage uses: a wedged or runaway compiler must not run forever
          // (the execute-stage timer at :703 covered execute only). On
          // timeout, reap the compile process and fall through as a
          // compile-stage timeout.
          var compileTimedOut = false;
          final CompileResult compileResult;
          try {
            compileResult = await driver
                .compile(
                  CompileRequest(
                    test: spec,
                    workingDirectory: workDir,
                    binaryConfig: binaryConfig,
                    stdoutCapture: stdoutBuf,
                    stderrCapture: stderrBuf,
                  ),
                )
                .timeout(
                  timeout,
                  onTimeout: () {
                    compileTimedOut = true;
                    driver.cancel(spec.id);
                    return const CompileResult(
                      success: false,
                      artifactPath: null,
                      stdout: '',
                      stderr: '',
                    );
                  },
                );
          } finally {
            state.unregisterLiveTest(spec.id);
          }
          // Fallback for drivers that ignore the request's capture
          // sinks and only materialize the CompileResult strings
          // (e.g. out-of-tree drivers): ring-bound their returned text
          // after the fact. Per stream, and only when the driver wrote
          // nothing into the sink, so streamed lines never duplicate.
          if (stdoutBuf.lineCount == 0) stdoutBuf.addBlob(compileResult.stdout);
          if (stderrBuf.lineCount == 0) stderrBuf.addBlob(compileResult.stderr);
          // Replay compile-stage stdout/stderr as TestLog events so
          // the inspector's log buffer captures compile-time
          // diagnostics (syntax errors, missing modules, etc.). Without
          // this, compile failures land in the result's failure
          // message but the inspector pane reads "No log output
          // captured yet."
          _replayCompileLogs(
            state: state,
            spec: spec,
            compileResult: compileResult,
          );
          if (compileTimedOut) {
            status = TestStatus.timeout;
            failureMessage = 'compile timed out after ${timeout.inSeconds}s';
            await _maybeCleanup(workDir, success: false);
            workDir = null;
          } else if (!compileResult.success) {
            status = TestStatus.fail;
            failureMessage = 'compile failed';
            await _maybeCleanup(workDir, success: false);
            workDir = null;
          } else if (state.cancelled) {
            // Cancel/AppExit landed after compile succeeded but before the
            // simulator was spawned. Do not dispatch execute — the run is
            // being torn down. The post-loop classifier (:567) maps the
            // still-unknown status to cancelled (status != timeout).
            await _maybeCleanup(workDir, success: false);
            workDir = null;
          } else {
            final tuple = await _runExecute(
              driver: driver,
              state: state,
              spec: spec,
              workDir: workDir,
              binaryConfig: binaryConfig,
              compileResult: compileResult,
              timeout: timeout,
              stdoutBuf: stdoutBuf,
              stderrBuf: stderrBuf,
            );
            status = tuple.status;
            exitCode = tuple.exitCode;
            waveformPath = tuple.waveformPath;
            failureMessage = tuple.failureMessage;
            killSignal = tuple.killSignal;
            effectiveSeed = tuple.effectiveSeed;
            metrics = tuple.metrics;
          }
        } else {
          final tuple = await _runExecute(
            driver: driver,
            state: state,
            spec: spec,
            workDir: workDir,
            binaryConfig: binaryConfig,
            compileResult: null,
            timeout: timeout,
            stdoutBuf: stdoutBuf,
            stderrBuf: stderrBuf,
          );
          status = tuple.status;
          exitCode = tuple.exitCode;
          waveformPath = tuple.waveformPath;
          failureMessage = tuple.failureMessage;
          killSignal = tuple.killSignal;
          effectiveSeed = tuple.effectiveSeed;
          metrics = tuple.metrics;
        }
      }
    } on SimulatorNotAvailableException catch (e) {
      // The driver tried to spawn its simulator binary and the OS
      // reported "command not found" (or equivalent). Surface this
      // as inspector-visible log lines instead of an opaque
      // `?` row with no diagnostic — otherwise users facing a
      // simply-not-installed simulator see no signal at all.
      status = TestStatus.fail;
      didExecute = false;
      failureMessage =
          '${e.simulatorId} binary `${e.binary}` not available'
          ' (${e.source.name}).';
      _emitLog(state, spec, failureMessage, fromStderr: true);
      _emitLog(
        state,
        spec,
        'Install ${e.simulatorId} on the host PATH or configure a custom '
        'binary path in Settings → Simulators → ${e.simulatorId}.',
        fromStderr: true,
      );
      if (e.cause != null) {
        _emitLog(state, spec, 'cause: ${e.cause}', fromStderr: true);
      }
      stderrBuf.addLine(failureMessage);
    } on Object catch (e) {
      status = TestStatus.unknown;
      failureMessage = 'scheduler error: $e';
      _emitLog(state, spec, failureMessage, fromStderr: true);
    }

    if (state.cancelled && status != TestStatus.timeout) {
      status = TestStatus.cancelled;
    }

    // Cleanup the working dir based on outcome.
    final success = status == TestStatus.pass || status == TestStatus.vacuous;
    // `capture: always` asks for every test's dump to be kept, so a passing
    // test that produced one keeps its work dir exactly as a failing test
    // does — dump in place, bounded by [dumpRetentionPolicy] like any other
    // retained directory. Without this `always` behaved like `on_failure`:
    // the dump was archived with a small budget in the app and deleted
    // under `--ci`.
    final keepPassingDump =
        success &&
        spec.waveform.capture == WaveformCapturePolicy.always &&
        waveformPath != null &&
        waveformPath.isNotEmpty;
    // A passing test's work dir (and its waveform dump) is about to be swept.
    // Relocate the dump into the durable archive first so a later "Debug in
    // WaveCrux" / inspector open resolves a file that still exists; the result
    // then carries the archived path. When the work dir is instead retained
    // (retainSuccessfulWorkDirs, or an `always` dump), leave the dump in place
    // and the path alone.
    if (success &&
        workDir != null &&
        !retainSuccessfulWorkDirs &&
        !keepPassingDump) {
      waveformPath = await _archivePassingWaveform(
        waveformPath: waveformPath,
        runId: state.request.runId,
        testId: spec.id,
      );
    }
    if (workDir != null) {
      await _maybeCleanup(workDir, success: success && !keepPassingDump);
    }

    final finishedAt = DateTime.now().toUtc();
    return TestResult(
      testId: spec.id,
      runId: state.request.runId,
      status: status,
      startedAt: startedAt,
      finishedAt: finishedAt,
      exitCode: exitCode,
      waveformPath: waveformPath,
      failureMessage: failureMessage,
      metrics: metrics.isEmpty ? null : metrics,
      // Record the seed the driver actually ran with: its reported
      // [effectiveSeed] (the value it derived when none was requested),
      // falling back to the spec's pinned seed. This closes the
      // determinism gap — a clock-derived seed is never lost, so a
      // flaky retry can replay the exact run.
      executionSeed: effectiveSeed ?? spec.seed,
      // Carry the parameterization identity of the (already-expanded)
      // spec through onto the result. A parameterized template is fanned
      // out into concrete children by the [TestSpecExpander] before the
      // run starts, each child carrying its parent's id in
      // [TestSpec.parentSpecId] and its resolved sweep slice in
      // [TestSpec.parameters]. Without propagating these, the emitted
      // result loses the seed×parameter identity and Pro surfaces that
      // group results back by parent — the Seed Failure Heatmap and the
      // "Re-run all in this parameter group" query — see a flat list with
      // no parents. Non-parameterized specs have a null parentSpecId and
      // an empty parameters map, so this is a no-op for them.
      parentSpecId: spec.parentSpecId,
      boundParameters: spec.parameters.isEmpty ? null : spec.parameters,
      killSignal: killSignal,
      didExecute: didExecute,
    );
  }

  Future<_ExecOutcome> _runExecute({
    required SimulatorDriver driver,
    required _RunState state,
    required TestSpec spec,
    required String workDir,
    required SimulatorBinaryConfig binaryConfig,
    required CompileResult? compileResult,
    required Duration timeout,
    required BoundedLogCapture stdoutBuf,
    required BoundedLogCapture stderrBuf,
  }) async {
    state.registerLiveTest(spec.id, driver);

    // Wall-clock of the execute stage, handed to the pass/fail detector as
    // the real `runtime` (detectors may key off it) instead of a
    // zero-duration placeholder.
    final execStopwatch = Stopwatch()..start();

    var driverStatus = TestStatus.unknown;
    int? exitCode;
    String? waveformPath;
    String? failureMessage;
    KillSignal? killSignal;
    int? effectiveSeed;
    var driverMetrics = const <String, String>{};
    var timedOut = false;

    Timer? timeoutTimer;
    final done = Completer<void>();

    final sub = driver
        .execute(
          ExecuteRequest(
            test: spec,
            workingDirectory: workDir,
            compileResult: compileResult,
            binaryConfig: binaryConfig,
          ),
        )
        .listen(
          (event) {
            switch (event) {
              case TestLogLine(:final line, :final fromStderr):
                if (fromStderr) {
                  stderrBuf.addLine(line);
                } else {
                  stdoutBuf.addLine(line);
                }
                state.eventSink.add(
                  TestLog(
                    runId: state.request.runId,
                    testId: spec.id,
                    line: line,
                    fromStderr: fromStderr,
                  ),
                );
              case TestStatusChange(status: final s):
                state.eventSink.add(
                  TestProgress(
                    runId: state.request.runId,
                    testId: spec.id,
                    status: s,
                  ),
                );
              case TestExecutionFinished(
                status: final s,
                exitCode: final ec,
                waveformPath: final wp,
                failureMessage: final fm,
                killSignal: final ks,
                effectiveSeed: final es,
                metrics: final m,
              ):
                driverStatus = s;
                exitCode = ec;
                waveformPath = wp;
                failureMessage = fm;
                killSignal = ks;
                effectiveSeed = es;
                driverMetrics = m;
                if (!done.isCompleted) done.complete();
            }
          },
          onError: (Object error) {
            failureMessage = error.toString();
            if (!done.isCompleted) done.complete();
          },
          onDone: () {
            if (!done.isCompleted) done.complete();
          },
        );

    timeoutTimer = Timer(timeout, () {
      if (done.isCompleted) return;
      timedOut = true;
      driver.cancel(spec.id);
    });

    await done.future;
    timeoutTimer.cancel();
    await sub.cancel();
    state.unregisterLiveTest(spec.id);

    if (timedOut) {
      // The driver's cancel() routes through ProcessReaper.terminateTree
      // (SIGTERM → grace → SIGKILL on the whole tree); we surface the
      // user-visible status plus the terminal signal regardless of how
      // the driver's stream finalized.
      return _ExecOutcome(
        status: TestStatus.timeout,
        exitCode: exitCode,
        waveformPath: waveformPath,
        failureMessage:
            failureMessage ?? 'timed out after ${timeout.inSeconds}s',
        killSignal: killSignal,
        effectiveSeed: effectiveSeed,
        metrics: driverMetrics,
      );
    }

    // Re-classify via the configured PassFailDetector. The async path
    // routes any regex config through a killable-isolate deadline so a
    // catastrophic-backtracking user pattern cannot freeze the regression
    // mid-run; deterministic detectors stay synchronous internally.
    //
    // `workingDirectory` is this scheduler's single classification call
    // site, and the only way a filesystem-backed detector
    // (`golden_compare`) can find the dumps the run just produced — they
    // live in the work dir allocated above, which nothing in
    // `PassFailDetector.detect`'s signature can reach
    // (it takes only captured output). It must be passed *before* the
    // work dir is swept below.
    execStopwatch.stop();
    final classified = await passFailRegistry.classifyAsync(
      config: spec.passFail,
      stdout: stdoutBuf.text,
      stderr: stderrBuf.text,
      exitCode: exitCode,
      runtime: execStopwatch.elapsed,
      workingDirectory: workDir,
    );
    // If the detector reports unknown (e.g. it could not derive a
    // signal), fall back to the driver's best-guess status.
    final finalStatus = classified == TestStatus.unknown
        ? driverStatus
        : classified;

    return _ExecOutcome(
      status: finalStatus,
      exitCode: exitCode,
      waveformPath: waveformPath,
      failureMessage: failureMessage,
      killSignal: killSignal,
      effectiveSeed: effectiveSeed,
      metrics: driverMetrics,
    );
  }

  String _allocateWorkDir(String runId, String testId) {
    final safeTestId = testId.replaceAll(RegExp('[^A-Za-z0-9._+-]'), '_');
    final dirPath = p.join(runRoot, 'runs', runId, safeTestId);
    final dir = Directory(dirPath)..createSync(recursive: true);
    return dir.path;
  }

  /// Emits a single synthetic log line into the regression's event
  /// sink. Used to surface scheduler-side diagnostics
  /// (missing-simulator, compile-stage replays) into the inspector's
  /// log buffer alongside driver-emitted lines.
  void _emitLog(
    _RunState state,
    TestSpec spec,
    String line, {
    required bool fromStderr,
  }) {
    state.eventSink.add(
      TestLog(
        runId: state.request.runId,
        testId: spec.id,
        line: line,
        fromStderr: fromStderr,
      ),
    );
  }

  /// Replays the compile stage's captured stdout/stderr as TestLog
  /// events so the inspector log buffer reflects compile-time
  /// diagnostics. Drivers ring-bound compile output into the attempt's
  /// [BoundedLogCapture]s and surface the retained text on
  /// [CompileResult.stdout]/`stderr` (not streamed) because pass/fail
  /// detection needs the text in one pass; this hop fans those strings
  /// out as line-level events for the runtime log surface.
  void _replayCompileLogs({
    required _RunState state,
    required TestSpec spec,
    required CompileResult compileResult,
  }) {
    for (final line in const LineSplitter().convert(compileResult.stdout)) {
      if (line.isEmpty) continue;
      _emitLog(state, spec, line, fromStderr: false);
    }
    for (final line in const LineSplitter().convert(compileResult.stderr)) {
      if (line.isEmpty) continue;
      _emitLog(state, spec, line, fromStderr: true);
    }
  }

  /// Relocate a passing test's waveform dump into [passingWaveformArchive],
  /// returning the durable archive path — or null when there is nothing to
  /// hand off later.
  ///
  /// Returns null (dropping the path) rather than a location that will not
  /// survive: when no archive is configured the dump is about to be deleted
  /// with the work dir, and when [WaveformArchive.retain] fails (source gone,
  /// pool unwritable) the original path would dangle. A recorded
  /// `waveformPath` is thus always a file the hand-off can open.
  Future<String?> _archivePassingWaveform({
    required String? waveformPath,
    required String runId,
    required String testId,
  }) async {
    if (waveformPath == null || waveformPath.isEmpty) return null;
    final archive = passingWaveformArchive;
    if (archive == null) return null;
    return await archive.retain(
      waveformPath: waveformPath,
      runId: runId,
      testId: testId,
    );
  }

  Future<void> _maybeCleanup(
    String workDir, {
    required bool success,
  }) async {
    if (!success) return;
    if (retainSuccessfulWorkDirs) return;
    final dir = Directory(workDir);
    if (!dir.existsSync()) return;
    try {
      await dir.delete(recursive: true);
    } on Object {
      // Best-effort cleanup; swallowing keeps the run-finished
      // event flowing.
    }
  }

  Future<void> _cancel(_RunState state) async {
    state.cancelled = true;
    for (final entry in state.liveTests.entries.toList()) {
      entry.value.cancel(entry.key);
    }
    await state.quiescent;
  }
}

/// Outcome bundle returned by [LocalJobScheduler._runExecute].
class _ExecOutcome {
  _ExecOutcome({
    required this.status,
    required this.exitCode,
    required this.waveformPath,
    required this.failureMessage,
    this.killSignal,
    this.effectiveSeed,
    this.metrics = const <String, String>{},
  });
  final TestStatus status;
  final int? exitCode;
  final String? waveformPath;
  final String? failureMessage;
  final KillSignal? killSignal;
  final int? effectiveSeed;
  final Map<String, String> metrics;
}

/// Per-run mutable state held by the scheduler.
class _RunState {
  _RunState({
    required this.request,
    required this.semaphore,
    required this.eventSink,
  });

  final RegressionRequest request;
  final Semaphore semaphore;
  final StreamController<RegressionEvent> eventSink;

  int _runningCount = 0;
  int completedCount = 0;
  bool cancelled = false;
  bool _finished = false;
  Completer<void>? _quiescent;

  /// Number of tests currently inside their execute stage.
  int get runningCount => _runningCount;

  set runningCount(int value) {
    _runningCount = value;
    if (value <= 0 && _quiescent != null && !_quiescent!.isCompleted) {
      _quiescent!.complete();
      _quiescent = null;
    }
  }

  /// Completes once no test is running. The cancel path awaits this
  /// signal rather than busy-polling, so cancellation (and therefore
  /// app exit) resolves as soon as the last driver reports back rather
  /// than up to a polling interval later.
  Future<void> get quiescent {
    if (_runningCount <= 0) return Future<void>.value();
    return (_quiescent ??= Completer<void>()).future;
  }

  /// Live tests by id → the driver running them (so cancel() can
  /// route to the right driver).
  final Map<String, SimulatorDriver> liveTests = <String, SimulatorDriver>{};

  /// Resource-lock mutual exclusion for this run. Extracted so the
  /// grant/transfer invariant is unit-testable under a forced
  /// interleaving — see [ResourceLockTable].
  final ResourceLockTable lockTable = ResourceLockTable();

  Map<String, ResourceLock> get heldLocks => lockTable.held;

  int get totalTests => request.tests.length;
  bool get isFinished => _finished;

  void registerLiveTest(String testId, SimulatorDriver driver) {
    liveTests[testId] = driver;
  }

  void unregisterLiveTest(String testId) {
    liveTests.remove(testId);
  }

  Future<void> acquireResourceLock(ResourceLock lock) =>
      lockTable.acquire(lock);

  void releaseResourceLocks(Iterable<ResourceLock> locks) =>
      lockTable.release(locks);

  void markFinished() {
    _finished = true;
  }
}
