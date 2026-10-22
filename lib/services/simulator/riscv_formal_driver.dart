// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/formal_verdict.dart';
import 'package:simcrux/domain/enums/riscv_host_platform.dart';
import 'package:simcrux/domain/enums/riscv_run_mode.dart';
import 'package:simcrux/domain/enums/riscv_toolchain_component.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/riscv_config.dart';
import 'package:simcrux/domain/models/sby_outcome.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/services/formal/formal_containment.dart';
import 'package:simcrux/services/simulator/riscv_arch_driver.dart';
import 'package:simcrux/services/simulator/riscv_toolchain_probe.dart';
import 'package:simcrux/services/simulator/sby_driver.dart';

/// [SimulatorDriver] that runs **one riscv-formal
/// bounded proof per job**: the general [SbyDriver] plus the RISC-V layer.
///
/// ## What the RISC-V layer is
///
/// Everything that is not SymbiYosys: the `riscv.formal:` block it reads,
/// the `riscv.formal.*` metric names (emitted **in addition to** the
/// general `formal.*` set, never instead), `riscv.mode` / `riscv.isa`, the
/// RVFI check / group / channel, its own demo corpus and its toolchain
/// guidance through [RiscvToolchainProbe]. The spawn, the log and status
/// readers, the agreement rule, trace containment and the exit-code rule
/// are [SbyDriver]'s. Its command line is the shipped one: no
/// `--live jsonl`, so an older `sby` a riscv-formal checkout pins still
/// runs, and the per-property statuses come from the task's
/// `status.sqlite` when there is one.
///
/// ## Why this maps onto the existing job model unchanged
///
/// riscv-formal is SymbiYosys running the RVFI check set against an
/// instrumented core: *N* independent bounded proofs, each pass/fail,
/// each with a counterexample VCD on failure. That is structurally a
/// regression run, so nothing about scheduling, timeouts, cancellation,
/// retry or persistence needs a parallel mechanism. The fan-out is resolved
/// *before* the scheduler by [RiscvFormalCheckImporter], which enumerates
/// the generated `.sby` files into one inspectable SimCrux test each.
///
/// ## The verdict comes from the log, never from the exit code
///
/// `sby` states its own conclusion on a `DONE (…)` line, and that is what
/// [SbyLogReader] reads. An `sby` that exits 0 without ever producing a
/// verdict is [FormalVerdict.noOutcome], never a pass. **Every non-`PASS`
/// outcome is [TestStatus.fail]**, including `UNKNOWN` and `TIMEOUT`; the
/// reasoning is on [FormalVerdict].
///
/// ## Where the counterexample VCD goes
///
/// Straight onto [TestExecutionFinished.waveformPath], which the scheduler
/// forwards to `TestResult.waveformPath` and the "Debug in WaveCrux" / CXP
/// producer path consumes unchanged. It survives on disk because `sby -d`
/// is pointed at the test's working directory and the scheduler only
/// sweeps **successful** work dirs.
///
/// ## Tiering
///
/// **Never gated.** Not by `LicenseTier`, not by `FeatureGate`, not by a
/// row cap, and not after `kBetaPeriod` flips to `false`. The property-level
/// pass/fail is correctness and is free; the Pro formal dashboard is the
/// analysis layer over an ungated result set.
class RiscvFormalDriver extends SbyDriver {
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

  /// Metric key: the reconciled outcome token — `PASS`, `FAIL`,
  /// `UNKNOWN`, `ERROR`, `TIMEOUT` or `NO_OUTCOME`. The same value as
  /// `formal.verdict`.
  ///
  /// Every non-`PASS` outcome is a `TestStatus.fail`, so "a counterexample
  /// was found" and "the solver gave up" are the same status — and
  /// different values of this key.
  static const String kMetricVerdict = 'riscv.formal.verdict';

  /// Metric key: `sby`'s `rc=` value, for provenance.
  static const String kMetricReturnCode = 'riscv.formal.rc';

  /// Metric key: a process exit code of **0** that was withheld from
  /// [TestExecutionFinished.exitCode] because the verdict was not `PASS`.
  static const String kMetricProcessExitCode = 'riscv.formal.process_exit_code';

  /// Metric key: the proof mode from the `.sby` (`bmc` / `prove` /
  /// `cover` / `live`).
  static const String kMetricProofMode = 'riscv.formal.proof_mode';

  /// Metric key: the bound the `.sby` configured.
  static const String kMetricDepthConfigured = 'riscv.formal.depth_configured';

  /// Metric key: the deepest step the engine reported reaching, beside
  /// [kMetricDepthConfigured]: "reached 12 of a configured 20" and "reached
  /// 12 of a configured 12" are different facts about a proof.
  static const String kMetricDepthReached = 'riscv.formal.depth_reached';

  /// Metric key: wall time in milliseconds. See [kMetricWallTimeSource].
  static const String kMetricWallTimeMs = 'riscv.formal.wall_time_ms';

  /// Metric key: `engine` when the wall time is `sby`'s own reported
  /// elapsed clock time, `measured` when it is this driver's stopwatch
  /// around the job. In `mode: demo` the replayed log's own elapsed time is
  /// the number a stopwatch could not give.
  static const String kMetricWallTimeSource = 'riscv.formal.wall_time_source';

  /// [kMetricWallTimeSource] value meaning the figure is `sby`'s own
  /// reported elapsed clock time — the **proof's** wall time. A named
  /// constant because the Pro formal dashboard renders the two sources
  /// differently.
  static const String kWallTimeSourceEngine = SbyDriver.kWallTimeSourceEngine;

  /// [kMetricWallTimeSource] value meaning the figure is this driver's
  /// stopwatch around the job, used when `sby` reported no elapsed time.
  static const String kWallTimeSourceMeasured =
      SbyDriver.kWallTimeSourceMeasured;

  /// Metric key: the engine specification, e.g. `smtbmc boolector`.
  static const String kMetricEngine = 'riscv.formal.engine';

  /// Metric key: how many traces `sby` announced. The first resolvable
  /// one becomes [TestExecutionFinished.waveformPath]; a `cover` run can
  /// legitimately emit several.
  static const String kMetricTraceCount = 'riscv.formal.trace_count';

  /// Metric key: a trace `sby` announced that could not be resolved to a
  /// file inside the task directory, recorded verbatim so the mismatch is
  /// diagnosable instead of silently becoming "no counterexample".
  static const String kMetricTraceUnresolved = 'riscv.formal.trace_unresolved';

  /// Metric key: which of the two modes produced this row. Shared with the
  /// `riscv_arch` driver **by reference, not by a second literal**.
  static const String kMetricMode = RiscvArchDriver.kMetricMode;

  /// Metric key: the ISA string the config claimed. Descriptive only, and
  /// shared with `riscv_arch` for the same reason as [kMetricMode].
  static const String kMetricIsa = RiscvArchDriver.kMetricIsa;

  @override
  String get id => kId;

  @override
  String get displayName => 'riscv-formal (SymbiYosys)';

  @override
  String get logTag => kId;

  /// The shipped command line, unchanged: no `--live jsonl`.
  @override
  bool get liveStatus => false;

  /// The shipped metrics, unchanged: riscv-formal's generated checks are
  /// read by one known frontend, and the track's rows stay byte-identical.
  @override
  bool get analysesRuns => false;

  /// Builds a probe phrased for this driver's platform, spawning through
  /// the base class's non-throwing [detectVersionOf].
  RiscvToolchainProbe probeFor() =>
      RiscvToolchainProbe(versionProbe: detectVersionOf, platform: _platform);

  /// Returns the SymbiYosys version line for the diagnostics panel, or
  /// null when `sby` was not found. Non-throwing, per the interface.
  @override
  Future<String?> detectVersion(SimulatorBinaryConfig config) async {
    try {
      final report = await probeFor().probe(const RiscvConfig());
      return report[RiscvToolchainComponent.formalEngine]?.version;
    } on Object {
      return null;
    }
  }

  @override
  String demoNotConfiguredMessage() =>
      'riscv_formal: `riscv.formal.demo_outputs` is not set, so there '
      'is no captured corpus to replay.';

  @override
  SbyJob prepareJob(ExecuteRequest request) {
    final cfg = request.test.riscv ?? const RiscvConfig();
    final formal = cfg.formal ?? const RiscvFormalConfig();
    final subject = formal.check ?? 'the check';
    // Before either path touches the disk: demo mode copies traces into
    // the task directory and the real path hands it to `sby -f`, which
    // deletes it.
    final (path: taskDir, :problem) = _taskDirectory(
      cfg,
      request.workingDirectory,
    );
    if (problem != null) {
      return SbyJob(taskDirectory: taskDir, problem: problem, subject: subject);
    }
    if (cfg.effectiveMode == RiscvRunMode.demo) {
      return SbyJob(
        taskDirectory: taskDir,
        task: formal.task,
        demo: true,
        demoCaseDir: demoCaseDir(cfg, request.test.name),
        subject: subject,
      );
    }
    final problems = cfg.validateForRun(simulatorId: kId);
    if (problems.isNotEmpty) {
      return SbyJob(
        taskDirectory: taskDir,
        validationProblems: problems,
        subject: subject,
      );
    }
    final sbyFile = resolvedSbyFile(cfg);
    return SbyJob(
      taskDirectory: taskDir,
      sbyFile: sbyFile,
      task: formal.task,
      // `sby` must run in the directory holding the `.sby` file:
      // riscv-formal's `genchecks.py` writes `[files]` entries relative to
      // `checks/`, and its own Makefile runs `sby` from there.
      spawnDirectory: _spawnDirectory(formal, sbyFile),
      argv: buildArgv(
        cfg: cfg,
        workingDirectory: request.workingDirectory,
        testName: request.test.name,
      ),
      subject: subject,
      unavailableMessage: probeFor().remediationFor(
        RiscvToolchainComponent.formalEngine,
        cfg,
      ),
    );
  }

  /// The `riscv.*` metrics, in the shipped order, before the `formal.*`
  /// set the base class appends.
  @override
  Map<String, String> trackMetrics(ExecuteRequest request, SbyRunFacts facts) {
    final cfg = request.test.riscv ?? const RiscvConfig();
    final formal = cfg.formal ?? const RiscvFormalConfig();
    final outcome = facts.outcome;
    final script = facts.script;
    final metrics = <String, String>{
      kMetricMode: cfg.effectiveMode.wireName,
      kMetricVerdict: facts.verdict.wireName,
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
      metrics[kMetricWallTimeMs] = '${facts.measured.inMilliseconds}';
      metrics[kMetricWallTimeSource] = kWallTimeSourceMeasured;
    }
    if (outcome.traces.isNotEmpty) {
      metrics[kMetricTraceCount] = '${outcome.traces.length}';
      if (facts.traceUnresolved != null) {
        metrics[kMetricTraceUnresolved] = facts.traceUnresolved!;
      }
    }
    if (facts.exitCodeWithheld) metrics[kMetricProcessExitCode] = '0';
    return metrics;
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
  /// Throws an [ArgumentError] unless the name is one safe path segment
  /// ([FormalContainment.segmentProblem]) and the result is strictly inside
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
  /// used when it is not one safe segment strictly inside
  /// [workingDirectory].
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
    if (FormalContainment.segmentProblem(name) == null &&
        p.isWithin(workingDirectory, taskDir)) {
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

  // ── demo corpus ────────────────────────────────────────────────────

  /// The corpus subdirectory this test replays, or null when no corpus is
  /// configured.
  String? demoCaseDir(RiscvConfig cfg, String testName) {
    final root = cfg.formal?.demoOutputs;
    if (root == null || root.isEmpty) return null;
    return p.join(root, cfg.demoCase ?? testName);
  }
}
