// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/hdl_language.dart';
import 'package:simcrux/domain/enums/kill_signal.dart';
import 'package:simcrux/domain/enums/riscv_formal_verdict.dart';
import 'package:simcrux/domain/enums/riscv_host_platform.dart';
import 'package:simcrux/domain/enums/riscv_run_mode.dart';
import 'package:simcrux/domain/enums/riscv_toolchain_component.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/riscv_config.dart';
import 'package:simcrux/domain/models/sby_outcome.dart';
import 'package:simcrux/domain/models/sby_script.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/services/simulator/process_backed_simulator_driver.dart';
import 'package:simcrux/services/simulator/python_traceback_reducer.dart';
import 'package:simcrux/services/simulator/riscv_arch_driver.dart';
import 'package:simcrux/services/simulator/riscv_toolchain_probe.dart';

/// [SimulatorDriver] that runs **one riscv-formal
/// bounded proof per job**.
///
/// ## Why this maps onto the existing job model unchanged
///
/// riscv-formal is SymbiYosys running the RVFI check set against an
/// instrumented core: *N* independent bounded proofs, each pass/fail,
/// each with a counterexample VCD on failure. That is structurally a
/// regression run, so nothing about scheduling, timeouts, cancellation,
/// retry or persistence needs a parallel mechanism.
///
/// The one impedance mismatch is the same one `riscv_arch` has: the job model has
/// **no fan-out** — one `TestSpec` yields exactly one
/// `TestExecutionFinished` and exactly one `TestResult` — while `sby`
/// naturally reports many proofs per `make`. It is resolved *before* the
/// scheduler by [RiscvFormalCheckImporter], which enumerates the generated
/// `.sby` files into one inspectable SimCrux test each. This driver then
/// runs exactly one of them, reusing [ProcessBackedSimulatorDriver]'s
/// process-tree reaping, timeout escalation and cancellation. No new
/// subprocess handling is written here.
///
/// ## The verdict comes from the log, never from the exit code
///
/// `sby` states its own conclusion on a `DONE (…)` line, and that is what
/// [SbyLogReader] reads. Classifying from the exit code instead would
/// make an `sby` that exits 0 without ever producing a verdict — a killed
/// pipeline, a wrapper that swallows the status, a mis-set `expect` —
/// report a proof that never happened as **pass**. That is the exit-0 trap
/// in its formal form, and [RiscvFormalVerdict.noOutcome] is what catches
/// it.
///
/// **Every non-`PASS` outcome is [TestStatus.fail]**, including
/// `UNKNOWN` and `TIMEOUT`. The reasoning, including why
/// [TestStatus.timeout] was considered and rejected, is on
/// [RiscvFormalVerdict]. `unknown` and `vacuous` are unreachable by
/// construction: `unknown` would hand the verdict back to the driver's
/// own exit code, and `vacuous` is success-equivalent to the scheduler —
/// no retry, and the work directory holding the counterexample VCD is
/// deleted.
///
/// ## Where the counterexample VCD goes
///
/// Straight onto [TestExecutionFinished.waveformPath], which the
/// scheduler already forwards to `TestResult.waveformPath` and which
/// already round-trips NDJSON as `waveform_path`. **No new result field
/// is needed**, and the existing "Debug in WaveCrux" / CXP producer path
/// consumes it unchanged — which is the whole hand-off to WaveCrux.
///
/// It survives on disk because `sby -d` is pointed at the test's working
/// directory and the scheduler only sweeps **successful** work dirs. A
/// failing proof is not successful, so its evidence stays. A *passing*
/// proof's work dir is swept, and the scheduler's existing
/// archive-or-drop rule keeps the recorded path from dangling — so a
/// cover trace from a passing run is dropped rather than pointing at a
/// deleted file. That is correct, and it is why this driver hands the
/// path over rather than special-casing it.
///
/// ## Toolchain posture
///
/// Detect and guide, never bundle. SymbiYosys is
/// [RiscvToolchainComponent.formalEngine] in the existing
/// [RiscvToolchainProbe], which covers it so the diagnostics
/// panel shows one coherent RISC-V picture; this driver **consumes** that
/// probe and does not extend it.
///
/// ## Tiering
///
/// **Never gated.** Not by `LicenseTier`, not by `FeatureGate`, not by a
/// row cap, and not after `kBetaPeriod` flips to `false` — identical to
/// `riscv_arch` and for the identical reason. The property-level pass/fail is
/// correctness and is free; the Pro formal dashboard is the analysis
/// layer over an ungated result set. The deliberate asymmetry with the
/// config loader's `_parameterizationUnlocked` sweep gate is recorded at
/// `config_loader_riscv.dart` and on [RiscvConfig].
class RiscvFormalDriver extends ProcessBackedSimulatorDriver {
  /// Creates a [RiscvFormalDriver].
  ///
  /// [platform] overrides the host OS the toolchain guidance is phrased
  /// for; production leaves it null.
  RiscvFormalDriver({
    super.launcher,
    super.reaper,
    super.killGrace,
    RiscvHostPlatform? platform,
    // Initializing formals cannot name a private field (Dart's parser
    // disallows `this._platform`), and the field is intentionally private.
    // ignore: prefer_initializing_formals
  }) : _platform = platform;

  final RiscvHostPlatform? _platform;

  /// The `simulatorId` this driver claims. Bare and lowercase, matching
  /// the open-core convention (`icarus`, `verilator`, `riscv_arch`, …).
  static const String kId = RiscvConfig.kFormalSimulatorId;

  /// Metric key: the riscv-formal check this row proved (`insn_add_ch0`).
  static const String kMetricCheck = 'riscv.formal.check';

  /// Metric key: the property group (`insn`, `reg`, `pc_fwd`, …). The Pro
  /// formal dashboard's check-set coverage rollup groups on this.
  static const String kMetricGroup = 'riscv.formal.group';

  /// Metric key: the RVFI channel index from a `…_chN` check name.
  static const String kMetricChannel = 'riscv.formal.channel';

  /// Metric key: `sby`'s own outcome token, verbatim — `PASS`, `FAIL`,
  /// `UNKNOWN`, `ERROR`, `TIMEOUT` or `NO_OUTCOME`.
  ///
  /// **This is where the honest distinction lives.** Every non-`PASS`
  /// outcome is a `TestStatus.fail`, so "a counterexample was found" and
  /// "the solver gave up" are the same status — and different values of
  /// this key.
  static const String kMetricVerdict = 'riscv.formal.verdict';

  /// Metric key: `sby`'s `rc=` value, for provenance.
  static const String kMetricReturnCode = 'riscv.formal.rc';

  /// Metric key: a process exit code of **0** that was withheld from
  /// [TestExecutionFinished.exitCode] because the verdict was not `PASS`.
  ///
  /// See the note on that suppression in [buildTerminalEvent]: the value
  /// is not discarded, it is moved somewhere that cannot be mistaken for
  /// a verdict.
  static const String kMetricProcessExitCode = 'riscv.formal.process_exit_code';

  /// Metric key: the proof mode from the `.sby` (`bmc` / `prove` /
  /// `cover` / `live`).
  static const String kMetricProofMode = 'riscv.formal.proof_mode';

  /// Metric key: the bound the `.sby` configured.
  static const String kMetricDepthConfigured = 'riscv.formal.depth_configured';

  /// Metric key: the deepest step the engine reported reaching.
  ///
  /// Reported beside [kMetricDepthConfigured] rather than alone, because
  /// "reached 12 of a configured 20" and "reached 12 of a configured 12"
  /// are different facts about a proof.
  static const String kMetricDepthReached = 'riscv.formal.depth_reached';

  /// Metric key: wall time in milliseconds. See [kMetricWallTimeSource].
  static const String kMetricWallTimeMs = 'riscv.formal.wall_time_ms';

  /// Metric key: `engine` when the wall time is `sby`'s own reported
  /// elapsed clock time, `measured` when it is this driver's stopwatch
  /// around the job.
  ///
  /// Two sources, never conflated: an exported report that says "this
  /// proof took 4 seconds" must be able to say whether that is what the
  /// solver reported or what the job took. In `mode: demo` the replayed
  /// log's own elapsed time is the honest number — a stopwatch there
  /// would report how long it took to read a file.
  static const String kMetricWallTimeSource = 'riscv.formal.wall_time_source';

  /// [kMetricWallTimeSource] value meaning the figure is `sby`'s own
  /// reported elapsed clock time — the **proof's** wall time.
  ///
  /// A named constant rather than a bare literal because the Pro formal
  /// dashboard has to render the two sources differently, and a reader
  /// that spelled `'engine'` itself would be a second literal for one
  /// shared convention — the drift `GoldenComparator` and
  /// [SbyLogReader.kPassMarker] both exist to prevent.
  static const String kWallTimeSourceEngine = 'engine';

  /// [kMetricWallTimeSource] value meaning the figure is this driver's
  /// stopwatch around the job, used when `sby` reported no elapsed time.
  static const String kWallTimeSourceMeasured = 'measured';

  /// Metric key: the engine specification, e.g. `smtbmc boolector`.
  static const String kMetricEngine = 'riscv.formal.engine';

  /// Metric key: how many traces `sby` announced. The first resolvable
  /// one becomes [TestExecutionFinished.waveformPath]; a `cover` run can
  /// legitimately emit several.
  static const String kMetricTraceCount = 'riscv.formal.trace_count';

  /// Metric key: a trace `sby` announced that could not be resolved to a
  /// file on disk, recorded verbatim so the mismatch is diagnosable
  /// instead of silently becoming "no counterexample".
  static const String kMetricTraceUnresolved = 'riscv.formal.trace_unresolved';

  /// Metric key: which of the two modes produced this row. Present so a
  /// demo-mode row can never be mistaken for a real proof in an exported
  /// report.
  ///
  /// Shared with the `riscv_arch` driver **by reference, not by a second
  /// literal** — a report that mixes the two flows must not end up with
  /// two spellings of the same fact.
  static const String kMetricMode = RiscvArchDriver.kMetricMode;

  /// Metric key: the ISA string the config claimed. Descriptive only, and
  /// shared with `riscv_arch` for the same reason as [kMetricMode].
  static const String kMetricIsa = RiscvArchDriver.kMetricIsa;

  /// Filename the demo corpus gives its captured log when `case.json`
  /// does not name one.
  static const String kDefaultDemoLogName = 'sby.log';

  @override
  String get id => kId;

  @override
  String get displayName => 'riscv-formal (SymbiYosys)';

  /// Declares **no HDL languages**, deliberately — the same call as
  /// `riscv_arch`, for a different reason.
  ///
  /// SymbiYosys certainly reads HDL, but not from `TestSpec.sources`: the
  /// `.sby` job file declares its own `[files]` and `[script]`. Claiming
  /// a language set here would make `MixedLanguageValidator` police a
  /// list this driver never consumes. See the note in
  /// `config_loader_riscv.dart`.
  ///
  /// [supportsVcd] is true and means exactly one thing: this driver can
  /// hand back a VCD. It is the **counterexample** trace `sby` emits on
  /// failure, not a user-requested dump — `TestSpec.waveform` is not
  /// consulted, because a proof either produces a trace or has nothing to
  /// show.
  @override
  SimulatorCapabilities get capabilities => SimulatorCapabilities(
    supportedLanguages: const <HdlLanguage>{},
    supportsVcd: true,
    supportsFst: false,
    supportsCocotb: false,
    // `sby` does everything in one invocation: read, elaborate, solve.
    // There is no artifact for a separate compile stage to produce.
    requiresSeparateCompileStep: false,
    emitsStructuredOutput: false,
  );

  /// Builds a probe phrased for this driver's platform, spawning through
  /// the base class's non-throwing [detectVersionOf].
  ///
  /// **Consumes** the existing probe, which already covers
  /// [RiscvToolchainComponent.formalEngine] with per-platform
  /// guidance, so there is nothing to extend here.
  RiscvToolchainProbe probeFor() =>
      RiscvToolchainProbe(versionProbe: detectVersionOf, platform: _platform);

  /// Returns the SymbiYosys version line for the diagnostics panel, or
  /// null when `sby` was not found. Non-throwing, per the interface.
  ///
  /// Reports only its own component rather than the four-component
  /// summary `RiscvArchDriver.detectVersion` returns: the panel already
  /// renders the whole toolchain report once, and a second copy of the
  /// cross-compiler's state under a formal-engine heading would be noise.
  @override
  Future<String?> detectVersion(SimulatorBinaryConfig config) async {
    try {
      final report = await probeFor().probe(const RiscvConfig());
      return report[RiscvToolchainComponent.formalEngine]?.version;
    } on Object {
      return null;
    }
  }

  /// No-op: `sby` reads, elaborates and solves in a single invocation, so
  /// there is no prerequisite artifact for a compile stage to produce.
  ///
  /// [capabilities] declares `requiresSeparateCompileStep: false` and the
  /// scheduler honors that, but the interface still requires the method.
  /// Reporting success with no artifact is the honest answer, and it is
  /// what `DemoSimulatorDriver` does for the same reason.
  @override
  Future<CompileResult> compile(CompileRequest request) async =>
      const CompileResult(
        success: true,
        artifactPath: null,
        stdout: '',
        stderr: '',
      );

  // ── execute ────────────────────────────────────────────────────────

  @override
  Future<void> runExecute(
    ExecuteRequest request,
    StreamController<TestExecutionEvent> controller,
  ) async {
    final cfg = request.test.riscv ?? const RiscvConfig();
    final startedAt = DateTime.now().toUtc();
    final stopwatch = Stopwatch()..start();

    // Before either path touches the disk: demo mode copies traces into
    // the task directory and the real path hands it to `sby -f`, which
    // deletes it. The loader refuses a check name that escapes the work
    // dir, so reaching this means a programmatically-built spec.
    final (path: taskDir, :problem) = _taskDirectory(
      cfg,
      request.workingDirectory,
    );
    if (problem != null) {
      await _failBeforeRunning(controller, startedAt, problem);
      return;
    }

    if (cfg.effectiveMode == RiscvRunMode.demo) {
      await _runDemo(request, cfg, taskDir, controller, startedAt, stopwatch);
      return;
    }

    final problems = cfg.validateForRun(simulatorId: kId);
    if (problems.isNotEmpty) {
      // The loader refuses this configuration, so reaching here means a
      // programmatically-built spec. Fail loudly rather than passing.
      await _failBeforeRunning(controller, startedAt, problems.join(' '));
      return;
    }

    final formal = cfg.formal ?? const RiscvFormalConfig();
    final sbyFile = resolvedSbyFile(cfg);
    final script = _readScript(sbyFile);
    final argv = buildArgv(
      cfg: cfg,
      workingDirectory: request.workingDirectory,
      testName: request.test.name,
    );

    final reader = SbyLogReader();
    // SymbiYosys is Python. A crash arrives as a multi-frame traceback,
    // and the reducer is generic for exactly this reuse — one
    // reducer in the codebase, wired to the same `onLine` hook.
    final reducer = PythonTracebackReducer();

    await runProcessStreaming(
      request: request,
      executable: argv.first,
      args: argv.skip(1).toList(growable: false),
      environment: request.binaryConfig.extraEnv,
      startedAt: startedAt,
      controller: controller,
      unavailableBinaryLabel: argv.first,
      // The actionable remediation, not an errno. This is the same
      // unlocalized-English channel as
      // `SimulatorNotAvailableException.remediation`: it
      // reaches logs and `failureMessage`, and no widget renders it.
      unavailableMessage: probeFor().remediationFor(
        RiscvToolchainComponent.formalEngine,
        cfg,
      ),
      // `sby` must run in the directory holding the `.sby` file:
      // riscv-formal's `genchecks.py` writes `[files]` entries relative
      // to `checks/`, and its own Makefile runs `sby` from there. The
      // artifacts still land in the test's working directory, because
      // `-d` is pointed at it.
      workingDirectoryOverride: _spawnDirectory(formal, sbyFile),
      onLine: (line, {required fromStderr}) {
        reader.addLine(line);
        reducer.addLine(line);
      },
      buildFinished: (exitCode, process) async {
        stopwatch.stop();
        return buildTerminalEvent(
          cfg: cfg,
          outcome: reader.outcome,
          script: script,
          taskDirectory: taskDir,
          spawnDirectory: _spawnDirectory(formal, sbyFile),
          exitCode: exitCode,
          startedAt: startedAt,
          measured: stopwatch.elapsed,
          killSignal: process.killSignal,
          tracebackSummary: reducer.summary,
        );
      },
    );
  }

  /// Ends the run as a `fail` before anything is spawned or staged.
  Future<void> _failBeforeRunning(
    StreamController<TestExecutionEvent> controller,
    DateTime startedAt,
    String message,
  ) async {
    controller.add(
      TestExecutionFinished(
        status: TestStatus.fail,
        exitCode: null,
        startedAt: startedAt,
        finishedAt: DateTime.now().toUtc(),
        failureMessage: message,
      ),
    );
    await controller.close();
  }

  /// Demo execute: replay a committed SymbiYosys log. No spawn.
  ///
  /// **Only the spawn is skipped.** The captured log is fed line by line
  /// into the same [SbyLogReader] the real path feeds from
  /// `runProcessStreaming`'s `onLine` hook, every line still reaches the
  /// stream as a `TestLogLine` (so the `string_match` detector the
  /// importer emits sees exactly the text it would see in production),
  /// and the terminal event is built by the same [buildTerminalEvent].
  /// Config-declared, never environment-gated — explicitly not the
  /// `SIMCRUX_DEMO_RUNNER` / `DemoSimulatorDriver` pattern, which would
  /// make CI exercise a different code path than production.
  Future<void> _runDemo(
    ExecuteRequest request,
    RiscvConfig cfg,
    String taskDir,
    StreamController<TestExecutionEvent> controller,
    DateTime startedAt,
    Stopwatch stopwatch,
  ) async {
    final caseDir = demoCaseDir(cfg, request.test.name);
    final reader = SbyLogReader();
    final reducer = PythonTracebackReducer();
    var exitCode = 0;
    SbyScript? script;

    if (caseDir == null) {
      controller.add(
        TestLogLine(
          line:
              'riscv_formal: `riscv.formal.demo_outputs` is not set, so there '
              'is no captured corpus to replay.',
          fromStderr: true,
          timestamp: DateTime.now().toUtc(),
        ),
      );
    } else {
      final manifest = await _demoManifest(caseDir);
      script = SbyScript(
        proofMode: manifest.proofMode,
        depth: manifest.depth,
      );
      exitCode = manifest.exitCode;
      controller.add(
        TestLogLine(
          line:
              'riscv_formal: mode=demo — replaying captured SymbiYosys output '
              'from $caseDir (no SymbiYosys, no subprocess).',
          fromStderr: false,
          timestamp: DateTime.now().toUtc(),
        ),
      );
      await _stageDemoTraces(manifest, caseDir, taskDir, controller);
      final log = await _readOrNull(p.join(caseDir, manifest.log));
      if (log == null) {
        controller.add(
          TestLogLine(
            line:
                'riscv_formal: demo corpus has no ${manifest.log} at '
                '$caseDir — the run proceeds and reports the absence of a '
                'verdict, exactly as a real run that produced none would.',
            fromStderr: true,
            timestamp: DateTime.now().toUtc(),
          ),
        );
      } else {
        for (final line in const LineSplitter().convert(log)) {
          reader.addLine(line);
          reducer.addLine(line);
          controller.add(
            TestLogLine(
              line: line,
              fromStderr: false,
              timestamp: DateTime.now().toUtc(),
            ),
          );
        }
      }
    }

    stopwatch.stop();
    controller.add(
      await buildTerminalEvent(
        cfg: cfg,
        outcome: reader.outcome,
        script: script,
        taskDirectory: taskDir,
        spawnDirectory: caseDir,
        exitCode: exitCode,
        startedAt: startedAt,
        measured: stopwatch.elapsed,
        killSignal: null,
        tracebackSummary: reducer.summary,
      ),
    );
    await controller.close();
  }

  // ── the shared tail: classify, resolve the trace, emit ─────────────

  /// Builds the terminal event from a parsed [outcome].
  ///
  /// **Every mode reaches this unchanged**, which is what makes the
  /// demo-mode tests evidence about the production path.
  ///
  /// The status is always `pass` or `fail` — never `unknown` (which hands
  /// the verdict back to this driver's own exit code, so an `sby` that
  /// exited 0 without proving anything would report pass) and never
  /// `vacuous` (which the scheduler treats as success-equivalent: no
  /// retry, and the work directory holding the counterexample VCD is
  /// deleted).
  Future<TestExecutionFinished> buildTerminalEvent({
    required RiscvConfig cfg,
    required SbyOutcome outcome,
    required SbyScript? script,
    required String taskDirectory,
    required String? spawnDirectory,
    required int? exitCode,
    required DateTime startedAt,
    required Duration measured,
    required KillSignal? killSignal,
    required String? tracebackSummary,
  }) async {
    final formal = cfg.formal ?? const RiscvFormalConfig();
    final verdict = outcome.verdict;

    final metrics = <String, String>{
      kMetricMode: cfg.effectiveMode.wireName,
      kMetricVerdict: verdict.wireName,
      kMetricCheck: ?formal.check,
      kMetricGroup: ?formal.effectiveGroup,
      kMetricChannel: ?formal.channel,
      kMetricIsa: ?cfg.isa,
    };
    if (outcome.returnCode != null) {
      metrics[kMetricReturnCode] = '${outcome.returnCode}';
    }
    if (script?.proofMode != null) {
      metrics[kMetricProofMode] = script!.proofMode!;
    }
    if (script?.depth != null) {
      metrics[kMetricDepthConfigured] = '${script!.depth}';
    }
    if (outcome.depthReached != null) {
      metrics[kMetricDepthReached] = '${outcome.depthReached}';
    }
    if (outcome.engine != null) metrics[kMetricEngine] = outcome.engine!;
    if (outcome.elapsedSeconds != null) {
      metrics[kMetricWallTimeMs] = '${outcome.elapsedSeconds! * 1000}';
      metrics[kMetricWallTimeSource] = kWallTimeSourceEngine;
    } else {
      metrics[kMetricWallTimeMs] = '${measured.inMilliseconds}';
      metrics[kMetricWallTimeSource] = kWallTimeSourceMeasured;
    }

    // The hand-off to WaveCrux. `waveformPath` already round-trips through
    // the scheduler, NDJSON (`waveform_path`), the bundle writer, the
    // JSON exporter and the web reader, and the "Debug in WaveCrux"
    // dispatcher consumes it — so no new result field is needed, and the
    // CXP producer gets the coordinate it expects.
    String? waveformPath;
    if (outcome.traces.isNotEmpty) {
      metrics[kMetricTraceCount] = '${outcome.traces.length}';
      waveformPath = await _resolveTrace(
        outcome.traces,
        taskDirectory: taskDirectory,
        spawnDirectory: spawnDirectory,
      );
      if (waveformPath == null) {
        metrics[kMetricTraceUnresolved] = outcome.traces.first;
      }
    }

    var status = verdict.status;
    var failureMessage = _describe(verdict, outcome, formal);

    // `sby` said PASS but the process did not exit cleanly: something
    // downstream of the verdict went wrong, and a contradicted pass is
    // not a pass.
    if (verdict.proved && exitCode != null && exitCode != 0) {
      status = TestStatus.fail;
      failureMessage =
          'SymbiYosys reported PASS but exited $exitCode — the proof result '
          'is contradicted by the process outcome.';
    }

    // **The driver never hands the scheduler an exit code that
    // contradicts its own verdict.**
    //
    // A detector that returns a decisive answer overrides the driver's
    // status, and `0` is the one value every exit-code-shaped classifier
    // reads as a pass — including `ExitCodePassFailConfig`, which is what
    // a `TestSpec` gets when no `pass_fail:` block is declared. An `sby`
    // that exited 0 having proved nothing (the exit-0 trap in its formal
    // form) would then report green no matter how carefully this driver
    // classified it. Reporting `null` instead makes `ExitCodeDetector`
    // return `unknown`, which falls back to the status computed above —
    // the honest one. The suppressed value is preserved in
    // [kMetricProcessExitCode] rather than discarded.
    var reportedExitCode = exitCode;
    if (!verdict.proved && exitCode == 0) {
      metrics[kMetricProcessExitCode] = '0';
      reportedExitCode = null;
    }
    // A reduced Python traceback is the most informative single line we
    // have, so it wins over the generic phrasing.
    if (tracebackSummary != null && status != TestStatus.pass) {
      failureMessage = tracebackSummary;
    }

    return TestExecutionFinished(
      status: status,
      exitCode: reportedExitCode,
      startedAt: startedAt,
      finishedAt: DateTime.now().toUtc(),
      waveformPath: waveformPath,
      failureMessage: failureMessage,
      killSignal: killSignal,
      metrics: metrics,
    );
  }

  String? _describe(
    RiscvFormalVerdict verdict,
    SbyOutcome outcome,
    RiscvFormalConfig formal,
  ) {
    final check = formal.check ?? 'the check';
    final depth = outcome.depthReached;
    switch (verdict) {
      case RiscvFormalVerdict.pass:
        return null;
      case RiscvFormalVerdict.fail:
        return depth == null
            ? 'property violated: SymbiYosys found a counterexample for $check'
            : 'property violated at step $depth: SymbiYosys found a '
                  'counterexample for $check';
      case RiscvFormalVerdict.unknown:
        // Deliberately not the word "pass" in any form. The solver did
        // not decide, so nothing was proven.
        return 'inconclusive: SymbiYosys returned UNKNOWN for $check'
            '${depth == null ? '' : ' (reached step $depth)'} — the property '
            'was neither proved nor refuted.';
      case RiscvFormalVerdict.timeout:
        return 'inconclusive: SymbiYosys hit its own solver timeout for $check'
            '${depth == null ? '' : ' at step $depth'} — the property was not '
            'proved.';
      case RiscvFormalVerdict.error:
        return outcome.errorLine ??
            'SymbiYosys errored out for $check — the proof did not run.';
      case RiscvFormalVerdict.noOutcome:
        return 'SymbiYosys produced no verdict for $check — no '
            '`DONE (…)` line was reported, so nothing was proved.';
    }
  }

  // ── argv + paths ───────────────────────────────────────────────────

  /// The `.sby` job file, resolved against `formal.checks_dir` when
  /// relative, and made absolute so the spawn is cwd-independent.
  String resolvedSbyFile(RiscvConfig cfg) {
    final formal = cfg.formal ?? const RiscvFormalConfig();
    final file = formal.sbyFile ?? '';
    if (file.isEmpty) return '';
    if (p.isAbsolute(file)) return p.normalize(file);
    final dir = formal.checksDir;
    if (dir == null || dir.isEmpty) return p.normalize(p.absolute(file));
    return p.normalize(p.absolute(p.join(dir, file)));
  }

  /// Where `sby -d` writes this proof's task directory.
  ///
  /// Inside the test's working directory on purpose: the scheduler only
  /// sweeps **successful** work dirs, so a failing proof's counterexample
  /// VCD is still on disk when the Pro dashboard or the CXP producer asks
  /// for it.
  ///
  /// Throws an [ArgumentError] unless the result is strictly inside
  /// [workingDirectory]. `sby -f` deletes its task directory before it
  /// runs, so a name that joins to anywhere else — `../..`, an absolute
  /// path (which `p.join` lets win outright), `.` or an empty name — would
  /// have SymbiYosys delete a directory SimCrux never created. The loader
  /// already refuses such a `riscv.formal.check`; this is the second layer,
  /// for a config built in code.
  String taskDirectoryFor(RiscvConfig cfg, String workingDirectory) {
    final (:path, :problem) = _taskDirectory(cfg, workingDirectory);
    if (problem != null) throw ArgumentError(problem);
    return path;
  }

  /// [taskDirectoryFor] without the throw: the path, and why it may not be
  /// used when it is not strictly inside [workingDirectory].
  ({String path, String? problem}) _taskDirectory(
    RiscvConfig cfg,
    String workingDirectory,
  ) {
    final formal = cfg.formal ?? const RiscvFormalConfig();
    final check = formal.check;
    final sbyFile = formal.sbyFile;
    final name =
        check ??
        (sbyFile == null ? 'proof' : p.basenameWithoutExtension(sbyFile));
    final taskDir = p.join(workingDirectory, name);
    if (p.isWithin(workingDirectory, taskDir)) {
      return (path: taskDir, problem: null);
    }
    final key = check != null ? 'riscv.formal.check' : 'riscv.formal.sby_file';
    return (
      path: taskDir,
      problem:
          '`$key` "$name" would put the SymbiYosys task directory at '
          "$taskDir, outside the test's working directory $workingDirectory. "
          '`sby -f` deletes its task directory before it runs, so the proof '
          'was not started. The check name must be a single file name, e.g. '
          '`insn_add_ch0`.',
    );
  }

  /// The directory `sby` is spawned in — the one holding the `.sby` file.
  String? _spawnDirectory(RiscvFormalConfig formal, String sbyFile) {
    final dir = formal.checksDir;
    if (dir != null && dir.isNotEmpty) return p.normalize(p.absolute(dir));
    if (sbyFile.isEmpty) return null;
    return p.dirname(sbyFile);
  }

  /// Builds the `sby` command line, or the user's `formal.command`
  /// override with placeholders expanded.
  ///
  /// The derived line is `sby -f -d <task_dir> <sby_file> [task]`:
  /// `-f` overwrites a stale task directory (SimCrux allocates a fresh
  /// one per attempt, so this only matters on a retry into a retained
  /// dir), and `-d` is what puts every artifact — including the
  /// counterexample VCD — inside the test's working directory.
  List<String> buildArgv({
    required RiscvConfig cfg,
    required String workingDirectory,
    required String testName,
  }) {
    final formal = cfg.formal ?? const RiscvFormalConfig();
    final sbyFile = resolvedSbyFile(cfg);
    final taskDir = taskDirectoryFor(cfg, workingDirectory);
    final values = <String, String>{
      'sby_file': sbyFile,
      'task_dir': taskDir,
      'task': formal.task ?? '',
      'check': formal.check ?? '',
      'checks_dir': formal.checksDir ?? '',
      'isa': cfg.isa ?? '',
      'name': testName,
      'work_dir': workingDirectory,
    };
    final override = formal.command ?? const <String>[];
    if (override.isNotEmpty) {
      return override
          .map((a) => expandRiscvPlaceholders(a, values))
          .toList(growable: false);
    }
    final task = formal.task;
    return <String>[
      formal.effectiveSbyBinary,
      '-f',
      '-d',
      taskDir,
      sbyFile,
      if (task != null && task.isNotEmpty) task,
    ];
  }

  // ── trace resolution ───────────────────────────────────────────────

  /// Resolves the first trace `sby` announced to an absolute path that
  /// exists, or null when none of them does.
  ///
  /// Returning null rather than a best guess is deliberate: the "Debug in
  /// WaveCrux" dispatcher and the CXP producer both open the recorded
  /// path, and a recorded path that does not exist is worse than an
  /// honest absence — the unresolved spelling is kept in
  /// [kMetricTraceUnresolved] so the mismatch stays diagnosable.
  ///
  /// `sby` spells traces two ways depending on which line reported them:
  /// relative to the task directory (`engine_0/trace.vcd`) or relative to
  /// its own invocation directory (`<task>/engine_0/trace.vcd`). Both are
  /// tried, plus absolute.
  Future<String?> _resolveTrace(
    List<String> traces, {
    required String taskDirectory,
    required String? spawnDirectory,
  }) async {
    for (final trace in traces) {
      for (final candidate in <String>[
        if (p.isAbsolute(trace)) trace,
        p.join(taskDirectory, trace),
        p.join(p.dirname(taskDirectory), trace),
        if (spawnDirectory != null) p.join(spawnDirectory, trace),
      ]) {
        final normalized = p.normalize(p.absolute(candidate));
        if (File(normalized).existsSync()) return normalized;
      }
    }
    return null;
  }

  // ── demo corpus ────────────────────────────────────────────────────

  /// The corpus subdirectory this test replays, or null when no corpus is
  /// configured.
  String? demoCaseDir(RiscvConfig cfg, String testName) {
    final root = cfg.formal?.demoOutputs;
    if (root == null || root.isEmpty) return null;
    return p.join(root, cfg.demoCase ?? testName);
  }

  Future<_DemoCase> _demoManifest(String caseDir) async {
    const fallback = _DemoCase(log: kDefaultDemoLogName);
    try {
      final file = File(p.join(caseDir, 'case.json'));
      if (!file.existsSync()) return fallback;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) return fallback;
      final log = decoded['log'];
      final traces = decoded['traces'];
      final trace = decoded['trace'];
      return _DemoCase(
        log: log is String && log.isNotEmpty ? log : fallback.log,
        traces: <String>[
          if (trace is String && trace.isNotEmpty) trace,
          if (traces is List)
            for (final t in traces)
              if (t is String && t.isNotEmpty) t,
        ],
        exitCode: decoded['exit_code'] is int
            ? decoded['exit_code']! as int
            : 0,
        proofMode: decoded['proof_mode'] is String
            ? decoded['proof_mode']! as String
            : null,
        depth: decoded['depth'] is int ? decoded['depth']! as int : null,
      );
    } on Object {
      return fallback;
    }
  }

  /// Copies the case's committed trace files into the task directory, so
  /// the same resolution the real path performs finds the same files.
  Future<void> _stageDemoTraces(
    _DemoCase manifest,
    String caseDir,
    String taskDirectory,
    StreamController<TestExecutionEvent> controller,
  ) async {
    for (final relative in manifest.traces) {
      final from = File(p.join(caseDir, relative));
      if (!from.existsSync()) continue;
      try {
        final to = File(p.join(taskDirectory, relative));
        await to.parent.create(recursive: true);
        await to.writeAsBytes(await from.readAsBytes());
      } on FileSystemException catch (e) {
        controller.add(
          TestLogLine(
            line: 'riscv_formal: could not stage demo trace $relative: $e',
            fromStderr: true,
            timestamp: DateTime.now().toUtc(),
          ),
        );
      }
    }
  }

  SbyScript? _readScript(String sbyFile) {
    if (sbyFile.isEmpty) return null;
    try {
      final file = File(sbyFile);
      if (!file.existsSync()) return null;
      return SbyScript.parse(file.readAsStringSync());
    } on Object {
      return null;
    }
  }

  Future<String?> _readOrNull(String path) async {
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      return await file.readAsString();
    } on FileSystemException {
      return null;
    }
  }
}

class _DemoCase {
  const _DemoCase({
    required this.log,
    this.traces = const <String>[],
    this.exitCode = 0,
    this.proofMode,
    this.depth,
  });

  final String log;
  final List<String> traces;
  final int exitCode;
  final String? proofMode;
  final int? depth;
}
