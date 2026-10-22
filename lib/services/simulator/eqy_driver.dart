// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:crux_io/crux_io.dart';
import 'package:crux_yosys/crux_yosys.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/formal_property_status.dart';
import 'package:simcrux/domain/enums/formal_verdict.dart';
import 'package:simcrux/domain/enums/hdl_language.dart';
import 'package:simcrux/domain/enums/kill_signal.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/eqy_outcome.dart';
import 'package:simcrux/domain/models/eqy_script.dart';
import 'package:simcrux/domain/models/formal_config.dart';
import 'package:simcrux/domain/models/riscv_config.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/services/formal/eqy_workdir_reader.dart';
import 'package:simcrux/services/formal/formal_containment.dart';
import 'package:simcrux/services/simulator/process_backed_simulator_driver.dart';
import 'package:simcrux/services/simulator/python_traceback_reducer.dart';
import 'package:simcrux/services/simulator/sby_driver.dart';

/// Everything one `eqy` run needs, worked out before anything is spawned.
@immutable
class EqyJob {
  /// Creates a job.
  const EqyJob({
    required this.workDirectory,
    this.problem,
    this.validationProblems = const <String>[],
    this.eqyFile = '',
    this.script,
    this.spawnDirectory,
    this.argv = const <String>[],
    this.skippedTools = const <String>[],
    this.unavailableMessage = '',
    this.eqyText,
    this.vhdlReads = const <EqyVhdlRead>[],
    this.loweredDirectory,
    this.loweredEqyFile,
    this.ghdl = 'ghdl',
  });

  /// The `-d` directory, inside the test's working directory.
  final String workDirectory;

  /// The `.eqy` file's text, when it could be read.
  final String? eqyText;

  /// The VHDL reads to lower before the spawn, each a `ghdl` plugin line of
  /// `[gold]` or `[gate]`. Empty for an all-Verilog file.
  final List<EqyVhdlRead> vhdlReads;

  /// Where the lowered Verilog and the rewritten `.eqy` go: one generated
  /// safe segment beside [workDirectory], never inside it (`eqy -f` clears
  /// that). Null when nothing is lowered.
  final String? loweredDirectory;

  /// The rewritten `.eqy` file `eqy` reads when VHDL is lowered: the user's
  /// file with each `ghdl` line replaced by a `read_verilog` of its lowered
  /// Verilog.
  final String? loweredEqyFile;

  /// The standalone GHDL that lowers [vhdlReads].
  final String ghdl;

  /// Why the run is refused before anything touches the disk, or null.
  final String? problem;

  /// What is missing for a run.
  final List<String> validationProblems;

  /// The `.eqy` file, absolute, or empty.
  final String eqyFile;

  /// What the `.eqy` file declares, when it could be read.
  final EqyScript? script;

  /// The directory `eqy` runs in: the one holding the `.eqy` file.
  final String? spawnDirectory;

  /// The command line.
  final List<String> argv;

  /// `formal.tools` entries `eqy` has no option for, left out of [argv].
  final List<String> skippedTools;

  /// The remediation when the binary is not found.
  final String unavailableMessage;
}

/// [SimulatorDriver] for **one EQY equivalence check per SimCrux test**
/// (id `eqy`).
///
/// One `eqy` invocation is one verdict with parts: EQY cuts the gold and
/// gate designs into partitions and proves each one. The row's verdict is
/// the run's; each partition is a child row in the same indexed
/// `formal.property.<n>.*` keys the `sby` driver writes per property, with
/// `kind` `partition` (verification guide §26.11).
///
/// ## The verdict comes from the log and the work directory, never the
/// exit code
///
/// `eqy` states its conclusion on a `DONE (…)` line ([EqyLogReader]). Each
/// partition's status comes from the strategy status file EQY's own summary
/// reads and from the log's partition lines ([EqyWorkdirReader]); the two
/// are reconciled by [EqyReconciliation]: the more conservative fact wins
/// and nothing is resolved toward Proved. The row is Proved only when every
/// partition was proved equivalent; otherwise the failure message names
/// which partitions were not, and which were. The exit code is recorded in
/// `formal.process_exit_code` and decides nothing; an exit code of 0 under
/// any verdict but `PASS` is withheld from the scheduler.
///
/// ## Containment
///
/// `eqy -f` deletes its `-d` directory before it runs, so the driver alone
/// chooses it: `<test working dir>/<the .eqy file's basename>`, which must
/// be one safe path segment. `extra_args` may not choose, keep or clear the
/// work directory. Partition and strategy names from the run are joined
/// only when each is a safe segment, and a counterexample is attached only
/// when it resolves inside the work directory. The work directory is read
/// off the UI isolate and every read is bounded.
///
/// ## VHDL
///
/// SimCrux reads VHDL only after lowering it with a standalone
/// `ghdl --synth --out=verilog` (`crux_yosys`'s `YosysRunner.lowerVhdl`),
/// never through the GHDL Yosys plugin. A `ghdl …` line in `[gold]` or
/// `[gate]` is lowered before the spawn into a generated directory beside
/// the work directory, and `eqy` reads a copy of the `.eqy` file in which
/// that line is a `read_verilog` of the lowered file. A `ghdl` line that
/// cannot be lowered faithfully (in `[script]`, with an option other than
/// `--std=`, without `-e <unit>`) refuses the run before anything runs.
///
/// ## Tiering
///
/// **Never gated.** The verdict, every partition, and every counterexample
/// are correctness and are free.
class EqyDriver extends ProcessBackedSimulatorDriver {
  /// Creates an [EqyDriver]. [lowerer] builds the `crux_yosys` runner that
  /// lowers VHDL for a given `ghdl`; tests pass one with a scripted process
  /// runner.
  EqyDriver({
    super.launcher,
    super.reaper,
    super.killGrace,
    YosysRunner Function(String ghdl)? lowerer,
  }) : _lowerer = lowerer ?? ((ghdl) => YosysRunner(ghdlExecutable: ghdl));

  final YosysRunner Function(String ghdl) _lowerer;

  /// In-flight VHDL lowerings by test id, so [cancel] reaches `ghdl` too.
  final Map<String, Completer<void>> _lowering = <String, Completer<void>>{};

  /// Metric key: how many `ghdl` reads were lowered to Verilog for the run.
  static const String kMetricVhdlLowered = 'formal.eqy.vhdl_lowered';

  /// The budget for one `ghdl --synth` lowering.
  static const Duration kVhdlLowerTimeout = Duration(minutes: 10);

  @override
  void cancel(String testId) {
    final lowering = _lowering[testId];
    if (lowering != null && !lowering.isCompleted) lowering.complete();
    super.cancel(testId);
  }

  /// The `simulatorId` this driver claims.
  static const String kId = FormalConfig.kEqySimulatorId;

  /// `formal.mode` for every EQY row.
  static const String kModeEquiv = 'equiv';

  /// `formal.property.<n>.kind` for a partition.
  static const String kPartitionKind = 'partition';

  /// Metric key: the strategy whose status decided a partition.
  static const String kPropertyStrategyField = 'strategy';

  /// The most partitions named in a failure message.
  static const int kMaxNamedPartitions = 8;

  /// The `eqy` options that choose, keep or clear a work directory, or that
  /// run something other than the check. Only the driver passes `-d` and
  /// `-f`; the rest are never passed.
  static const Set<String> kReservedOptions = <String>{
    '-d',
    '-f',
    '--force',
    '-b',
    '--backup',
    '-t',
    '--tmp',
    '-c',
    '--continue',
    '-m',
    '--setup',
    '-P',
    '--purge',
    '-p',
    '--init-config-file',
  };

  /// The most bytes of the `.eqy` file read before the spawn.
  static const int kMaxEqyFileBytes = 1024 * 1024;

  @override
  String get id => kId;

  @override
  String get displayName => 'EQY';

  /// Declares no HDL languages: `eqy` reads the sources its `[gold]` and
  /// `[gate]` scripts name, never `TestSpec.sources`.
  @override
  SimulatorCapabilities get capabilities => SimulatorCapabilities(
    supportedLanguages: const <HdlLanguage>{},
    supportsVcd: true,
    supportsFst: false,
    supportsCocotb: false,
    requiresSeparateCompileStep: false,
    emitsStructuredOutput: false,
  );

  @override
  Future<String?> detectVersion(SimulatorBinaryConfig config) =>
      detectVersionOf(resolveBinary(config, FormalConfig.kDefaultEqyBinary));

  /// No-op: `eqy` reads, partitions and proves in one invocation.
  @override
  Future<CompileResult> compile(CompileRequest request) async =>
      const CompileResult(
        success: true,
        artifactPath: null,
        stdout: '',
        stderr: '',
      );

  /// Works out the job for [request] from its `formal:` block.
  @visibleForTesting
  EqyJob prepareJob(ExecuteRequest request) {
    final cfg = request.test.formal ?? const FormalConfig();
    final eqyFile = _absolute(cfg.eqyFile);
    final segment = eqyFile.isEmpty
        ? 'equivalence'
        : p.basenameWithoutExtension(eqyFile);
    final workDir = p.join(request.workingDirectory, segment);
    final segmentProblem = FormalContainment.segmentProblem(segment);
    if (segmentProblem != null ||
        !p.isWithin(request.workingDirectory, workDir)) {
      return EqyJob(
        workDirectory: workDir,
        problem:
            '`formal.eqy_file` "$segment" cannot name the EQY work directory '
            '(${segmentProblem ?? 'it leaves the working directory'}). '
            '`eqy -f` deletes its work directory before it runs, so the '
            'equivalence check was not started.',
      );
    }
    final validation = cfg.validateForEqyRun();
    if (cfg.effectiveMode == FormalRunMode.demo) {
      return EqyJob(workDirectory: workDir, problem: validation.join(' '));
    }
    final reserved = <String>[
      for (final arg in cfg.extraArgs ?? const <String>[])
        if (kReservedOptions.contains(arg) ||
            arg.startsWith('--purge=') ||
            arg.startsWith('--init-config-file=') ||
            (arg.length > 2 &&
                (arg.startsWith('-d') ||
                    arg.startsWith('-P') ||
                    arg.startsWith('-p'))))
          arg,
    ];
    if (reserved.isNotEmpty) {
      return EqyJob(
        workDirectory: workDir,
        problem:
            '`formal.extra_args` may not pass ${reserved.join(', ')}: '
            'SimCrux alone chooses and clears the EQY work directory, so the '
            'equivalence check was not started.',
      );
    }
    final text = _readText(eqyFile);
    final script = text == null ? null : EqyScript.parse(text);
    final vhdl = text == null
        ? const <EqyVhdlRead>[]
        : EqyScript.vhdlReads(text);
    final unlowerable = vhdl.where((r) => r.problem != null).firstOrNull;
    if (unlowerable != null) {
      return EqyJob(
        workDirectory: workDir,
        eqyFile: eqyFile,
        script: script,
        problem:
            '`${p.basename(eqyFile)}` reads VHDL through the GHDL Yosys '
            'plugin (`${unlowerable.line}`), which SimCrux does not run, and '
            'cannot lower that line to Verilog: ${unlowerable.problem}. '
            'The equivalence check was not started.',
      );
    }
    final binary =
        cfg.eqyBinary ??
        resolveBinary(request.binaryConfig, FormalConfig.kDefaultEqyBinary);
    // A generated segment of its own, beside the work directory `eqy -f`
    // clears: the lowered Verilog and the rewritten `.eqy` survive the run.
    final loweredDir = vhdl.isEmpty
        ? null
        : p.join(request.workingDirectory, '${segment}_vhdl');
    final loweredEqy = loweredDir == null
        ? null
        : p.join(loweredDir, p.basename(eqyFile));
    final runFile = loweredEqy ?? eqyFile;
    final tools = cfg.tools ?? const <String, String>{};
    final values = <String, String>{
      'eqy_file': runFile,
      'task_dir': workDir,
      'work_dir': request.workingDirectory,
      'name': request.test.name,
    };
    final override = cfg.command ?? const <String>[];
    final argv = override.isNotEmpty
        ? override
              .map((a) => expandRiscvPlaceholders(a, values))
              .toList(growable: false)
        : <String>[
            binary,
            '-f',
            '-d',
            workDir,
            for (final MapEntry(:key, :value) in tools.entries)
              if (FormalConfig.kEqyToolKeys.contains(key)) ...<String>[
                '--$key',
                value,
              ],
            ...?cfg.extraArgs,
            runFile,
          ];
    return EqyJob(
      workDirectory: workDir,
      validationProblems: validation,
      eqyFile: eqyFile,
      script: script,
      eqyText: text,
      vhdlReads: vhdl,
      loweredDirectory: loweredDir,
      loweredEqyFile: loweredEqy,
      ghdl: cfg.ghdlBinary ?? _ghdlFor(binary),
      spawnDirectory: eqyFile.isEmpty ? null : p.dirname(eqyFile),
      argv: argv,
      skippedTools: <String>[
        for (final key in tools.keys)
          if (!FormalConfig.kEqyToolKeys.contains(key)) key,
      ],
      unavailableMessage:
          'EQY (`$binary`) was not found. Set its path in Settings → '
          'Engines, or put the directory holding `eqy` (an OSS CAD Suite '
          '`bin/`, for example) on PATH.',
    );
  }

  @override
  Future<void> runExecute(
    ExecuteRequest request,
    StreamController<TestExecutionEvent> controller,
  ) async {
    final startedAt = DateTime.now().toUtc();
    final stopwatch = Stopwatch()..start();
    final job = prepareJob(request);
    if (job.problem != null) {
      await _failBeforeRunning(controller, startedAt, job.problem!);
      return;
    }
    if (job.validationProblems.isNotEmpty) {
      await _failBeforeRunning(
        controller,
        startedAt,
        job.validationProblems.join(' '),
      );
      return;
    }
    for (final tool in job.skippedTools) {
      _notice(
        controller,
        '`formal.tools.$tool` is a SymbiYosys option EQY does not take; it '
        'was not passed.',
      );
    }
    if (job.vhdlReads.isNotEmpty) {
      final problem = await _lowerVhdl(request.test.id, job, controller);
      if (problem != null) {
        await _failBeforeRunning(controller, startedAt, problem);
        return;
      }
    }
    final reader = EqyLogReader();
    final reducer = PythonTracebackReducer();
    await runProcessStreaming(
      request: request,
      executable: job.argv.first,
      args: job.argv.skip(1).toList(growable: false),
      environment: request.binaryConfig.extraEnv,
      startedAt: startedAt,
      controller: controller,
      unavailableBinaryLabel: job.argv.first,
      unavailableMessage: job.unavailableMessage,
      workingDirectoryOverride: job.spawnDirectory,
      onLine: (line, {required fromStderr}) {
        reader.addLine(line);
        reducer.addLine(line);
      },
      buildFinished: (exitCode, process) async {
        stopwatch.stop();
        final outcome = reader.outcome;
        final snapshot = await EqyDriver.readWorkdir(
          job.workDirectory,
          outcome.partitions,
          <String>[
            for (final s in job.script?.strategies ?? const <EqyStrategy>[])
              s.name,
          ],
        );
        return buildTerminalEvent(
          job: job,
          outcome: outcome,
          snapshot: snapshot,
          exitCode: exitCode,
          startedAt: startedAt,
          measured: stopwatch.elapsed,
          tracebackSummary: reducer.summary,
          controller: controller,
          killSignal: process.killSignal,
        );
      },
    );
  }

  /// Reads [workDirectory] on a separate isolate: the partition list and
  /// each failing partition's SymbiYosys log can be large, and none of it
  /// is read on the caller's isolate.
  static Future<EqyWorkdirSnapshot> readWorkdir(
    String workDirectory,
    Map<String, EqyLogPartitionStatus> log,
    List<String> strategyOrder,
  ) {
    final logCopy = Map<String, EqyLogPartitionStatus>.of(log);
    final order = List<String>.of(strategyOrder);
    return Isolate.run(
      () => const EqyWorkdirReader().read(
        workDirectory,
        log: logCopy,
        strategyOrder: order,
      ),
    );
  }

  /// Builds the terminal event from what the run left. Public for the
  /// corpus tests, which feed it committed captures.
  @visibleForTesting
  TestExecutionFinished buildTerminalEvent({
    required EqyJob job,
    required EqyOutcome outcome,
    required EqyWorkdirSnapshot snapshot,
    required int? exitCode,
    required DateTime startedAt,
    required Duration measured,
    String? tracebackSummary,
    StreamController<TestExecutionEvent>? controller,
    KillSignal? killSignal,
  }) {
    for (final note in snapshot.notes) {
      if (controller != null) _notice(controller, note);
    }
    final reconciliation = EqyReconciliation.reconcile(
      taskVerdict: outcome.verdict,
      snapshot: snapshot,
    );
    final verdict = reconciliation.verdict;
    final partitions = snapshot.partitions;

    String? waveformPath;
    for (final partition in partitions) {
      if (partition.trace != null) {
        waveformPath = partition.trace;
        break;
      }
    }
    final failing = partitions
        .where((x) => x.status == FormalPropertyStatus.counterexample)
        .toList(growable: false);
    if (controller != null) {
      for (final partition in failing) {
        if (partition.trace == null) {
          _notice(
            controller,
            'partition ${partition.name} is not equivalent, but no '
            'counterexample trace was found inside ${job.workDirectory}.',
          );
        }
      }
    }

    final metrics = _metrics(
      job,
      outcome,
      snapshot,
      reconciliation,
      exitCode,
      measured,
    );
    var status = verdict.status;
    var failureMessage = _describe(verdict, outcome, snapshot);
    if (verdict.proved && exitCode != null && exitCode != 0) {
      status = TestStatus.fail;
      failureMessage =
          'EQY reported PASS but exited $exitCode — the equivalence result is '
          'contradicted by the process outcome.';
    }
    if (tracebackSummary != null && status != TestStatus.pass) {
      failureMessage = '$failureMessage $tracebackSummary';
    }
    final withheld = !verdict.proved && exitCode == 0;
    return TestExecutionFinished(
      status: status,
      exitCode: withheld ? null : exitCode,
      startedAt: startedAt,
      finishedAt: DateTime.now().toUtc(),
      waveformPath: waveformPath,
      failureMessage: failureMessage,
      killSignal: killSignal,
      metrics: metrics,
    );
  }

  Map<String, String> _metrics(
    EqyJob job,
    EqyOutcome outcome,
    EqyWorkdirSnapshot snapshot,
    EqyReconciliation reconciliation,
    int? exitCode,
    Duration measured,
  ) {
    final partitions = snapshot.partitions;
    final metrics = <String, String>{
      SbyDriver.kMetricTool: kId,
      SbyDriver.kMetricRunMode: 'normal',
      SbyDriver.kMetricMode: kModeEquiv,
      SbyDriver.kMetricVerdict: reconciliation.verdict.wireName,
      if (outcome.returnCode != null)
        SbyDriver.kMetricReturnCode: '${outcome.returnCode}',
      if (exitCode != null) SbyDriver.kMetricProcessExitCode: '$exitCode',
      if (outcome.elapsedSeconds != null) ...<String, String>{
        SbyDriver.kMetricWallTimeMs: '${outcome.elapsedSeconds! * 1000}',
        SbyDriver.kMetricWallTimeSource: SbyDriver.kWallTimeSourceEngine,
      } else ...<String, String>{
        SbyDriver.kMetricWallTimeMs: '${measured.inMilliseconds}',
        SbyDriver.kMetricWallTimeSource: SbyDriver.kWallTimeSourceMeasured,
      },
      SbyDriver.kMetricEngine: ?job.script?.engineWord,
      SbyDriver.kMetricSolver: ?job.script?.solver,
      if (job.vhdlReads.isNotEmpty)
        kMetricVhdlLowered: '${job.vhdlReads.length}',
    };
    if (snapshot.partitionListRead) {
      final traced = partitions.where((x) => x.trace != null).length;
      metrics[SbyDriver.kMetricProperties] = '${partitions.length}';
      metrics[SbyDriver.kMetricPropertiesFailed] =
          '${partitions.where((x) => x.status.bucketIsCounterexample).length}';
      metrics[SbyDriver.kMetricPropertiesUndecided] =
          '${partitions.where((x) => x.status.isUndecided).length}';
      if (traced > 0) metrics[SbyDriver.kMetricTraceCount] = '$traced';
    }
    if (reconciliation.disagreement != null) {
      metrics[SbyDriver.kMetricVerdictDisagreement] =
          reconciliation.disagreement! ? '1' : '0';
    }
    if (snapshot.truncated || partitions.length > SbyDriver.kMaxPropertyRows) {
      metrics[SbyDriver.kMetricPropertiesTruncated] = '1';
    }
    var n = 0;
    for (final partition in partitions.take(SbyDriver.kMaxPropertyRows)) {
      final prefix = '${SbyDriver.kPropertyPrefix}$n.';
      metrics['${prefix}kind'] = kPartitionKind;
      metrics['${prefix}location'] = partition.name;
      metrics['${prefix}status'] = partition.status.wireName;
      metrics['${prefix}label'] = partition.name;
      if (partition.trace case final String trace) {
        metrics['${prefix}trace'] = p
            .relative(trace, from: job.workDirectory)
            .replaceAll(r'\', '/');
      }
      metrics['${prefix}id'] = partition.name;
      if (partition.strategy case final String strategy) {
        metrics['$prefix$kPropertyStrategyField'] = strategy;
      }
      n++;
    }
    return metrics;
  }

  /// The failure message for [verdict]. Never claims a proof: a run that
  /// proved some partitions and not others names both sets.
  String? _describe(
    FormalVerdict verdict,
    EqyOutcome outcome,
    EqyWorkdirSnapshot snapshot,
  ) {
    if (verdict == FormalVerdict.pass) return null;
    final partitions = snapshot.partitions;
    if (partitions.isNotEmpty) {
      final unproved = partitions
          .where((x) => x.status != FormalPropertyStatus.proved)
          .toList(growable: false);
      final proved = partitions
          .where((x) => x.status == FormalPropertyStatus.proved)
          .toList(growable: false);
      if (unproved.isNotEmpty) {
        final named = unproved
            .take(kMaxNamedPartitions)
            .map((x) => '${x.name} (${_statusPhrase(x.status)})')
            .join(', ');
        final more = unproved.length > kMaxNamedPartitions
            ? ' and ${unproved.length - kMaxNamedPartitions} more'
            : '';
        final provedText = proved.isEmpty
            ? 'No partition was proved equivalent.'
            : '${_names(proved)} ${proved.length == 1 ? 'was' : 'were'} '
                  'proved equivalent; the designs are not proved '
                  'equivalent as a whole.';
        return 'EQY did not prove ${unproved.length} of '
            '${partitions.length} '
            '${partitions.length == 1 ? 'partition' : 'partitions'} '
            'equivalent: $named$more. $provedText';
      }
      // Every partition proved, but the log did not say PASS.
      return 'EQY reported ${outcome.verdict.wireName} although every '
          'partition it wrote a status for was proved; the more '
          'conservative result stands.';
    }
    return switch (verdict) {
      FormalVerdict.noOutcome when outcome.verdict == FormalVerdict.pass =>
        'EQY reported PASS but wrote no partition list, so nothing is known '
            'to have been proved.',
      FormalVerdict.noOutcome =>
        'EQY produced no verdict — no `DONE (…)` line was reported, so '
            'nothing was proved.',
      FormalVerdict.error =>
        outcome.errorLine ??
            'EQY errored out before it proved any partition — the check did '
                'not run.',
      FormalVerdict.fail =>
        'EQY reported FAIL before it wrote a partition list.',
      FormalVerdict.unknown || FormalVerdict.timeout =>
        'inconclusive: EQY returned ${verdict.wireName} and proved nothing.',
      FormalVerdict.pass => null,
    };
  }

  static String _names(List<EqyPartitionResult> partitions) {
    final named = partitions.take(kMaxNamedPartitions).map((x) => x.name);
    final more = partitions.length > kMaxNamedPartitions
        ? ' and ${partitions.length - kMaxNamedPartitions} more'
        : '';
    return '${named.join(', ')}$more';
  }

  static String _statusPhrase(FormalPropertyStatus status) => switch (status) {
    FormalPropertyStatus.proved ||
    FormalPropertyStatus.reached => 'proved equivalent',
    FormalPropertyStatus.counterexample ||
    FormalPropertyStatus.notReached => 'not equivalent, counterexample',
    FormalPropertyStatus.inconclusive => 'undecided',
    FormalPropertyStatus.didNotRun => 'did not run',
  };

  Future<void> _failBeforeRunning(
    StreamController<TestExecutionEvent> controller,
    DateTime startedAt,
    String message,
  ) async {
    _notice(controller, message);
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

  /// A driver note, to the run log and to this process's stderr:
  /// `developer.log` is invisible in a release build.
  void _notice(StreamController<TestExecutionEvent> controller, String text) {
    final line = 'eqy: $text';
    stderr.writeln(line);
    if (controller.isClosed) return;
    controller.add(
      TestLogLine(
        line: line,
        fromStderr: true,
        timestamp: DateTime.now().toUtc(),
      ),
    );
  }

  static String _absolute(String? file) {
    if (file == null || file.isEmpty) return '';
    return p.normalize(p.isAbsolute(file) ? file : p.absolute(file));
  }

  static String? _readText(String eqyFile) {
    if (eqyFile.isEmpty) return null;
    try {
      final file = File(eqyFile);
      if (!file.existsSync() || file.lengthSync() > kMaxEqyFileBytes) {
        return null;
      }
      return file.readAsStringSync();
    } on Object {
      return null;
    }
  }

  /// The `ghdl` to lower with when the project names none: the one beside
  /// an absolute `eqy` (an OSS CAD Suite `bin/`), else the first on PATH
  /// with the platform's engine directories appended (a macOS app does not
  /// inherit the shell's PATH), else the bare name.
  static String _ghdlFor(String eqy) {
    final name = Platform.isWindows ? 'ghdl.exe' : 'ghdl';
    final dirs = <String>[
      if (p.isAbsolute(eqy)) p.dirname(eqy),
      ...(Platform.environment['PATH'] ?? '').split(
        Platform.isWindows ? ';' : ':',
      ),
      ...engineSearchDirs(),
    ];
    for (final dir in dirs) {
      if (dir.isEmpty) continue;
      final candidate = p.join(dir, name);
      if (File(candidate).existsSync()) return candidate;
    }
    return name;
  }

  /// Lowers each of [job]'s `ghdl` reads to Verilog with `crux_yosys`'s
  /// `lowerVhdl` and writes the rewritten `.eqy` beside them. Returns why it
  /// could not, or null.
  Future<String?> _lowerVhdl(
    String testId,
    EqyJob job,
    StreamController<TestExecutionEvent> controller,
  ) async {
    final dir = job.loweredDirectory!;
    final cancel = Completer<void>();
    _lowering[testId] = cancel;
    try {
      await Directory(dir).create(recursive: true);
      final runner = _lowerer(job.ghdl);
      final base = p.dirname(job.eqyFile);
      final replacements = <int, String>{};
      for (final read in job.vhdlReads) {
        final out = p.join(dir, '${read.section}_${read.ordinal}.v');
        final result = await runner.lowerVhdl(
          YosysRunRequest(
            sources: <YosysSourceFile>[
              for (final file in read.files)
                YosysSourceFile.vhdl(
                  p.normalize(p.isAbsolute(file) ? file : p.join(base, file)),
                ),
            ],
            vhdlTopUnit: read.unit,
            vhdlStandard: read.standard,
          ),
          outputPath: out,
          timeout: kVhdlLowerTimeout,
          cancelSignal: cancel.future,
        );
        final why = switch (result) {
          VhdlLowerSuccess() => null,
          VhdlLowerFailure(:final kind, :final stderr) =>
            kind == YosysFailureKind.launch
                ? '`${job.ghdl}` was not found. Set `formal.ghdl_binary`, or '
                      'put the directory holding `ghdl` on PATH'
                : _firstLines(stderr),
          VhdlLowerTimeout() =>
            'it did not finish within ${kVhdlLowerTimeout.inMinutes} minutes',
          VhdlLowerCancelled() => 'the run was cancelled',
        };
        if (why != null) {
          return '`ghdl --synth` could not lower `${read.line}` from '
              '[${read.section}] to Verilog ($why), so the equivalence check '
              'was not started.';
        }
        try {
          replacements[read.ordinal] = YosysScriptCommands.readVerilog(
            <String>[out],
          );
          // Not a crash: a path SimCrux generated cannot be quoted for Yosys.
          // ignore: avoid_catching_errors
        } on ArgumentError catch (e) {
          return 'The lowered Verilog path cannot be read by Yosys ($e), so '
              'the equivalence check was not started.';
        }
        _notice(
          controller,
          'lowered `${read.line}` to $out with `ghdl --synth --out=verilog`.',
        );
      }
      await File(
        job.loweredEqyFile!,
      ).writeAsString(EqyScript.replaceVhdlReads(job.eqyText!, replacements));
      return null;
    } on FileSystemException catch (e) {
      return 'The lowered VHDL could not be written ($e), so the equivalence '
          'check was not started.';
    } finally {
      _lowering.remove(testId);
    }
  }

  /// The first few lines of a tool's diagnostics, for a failure message.
  static String _firstLines(String text) {
    final lines = text
        .split('\n')
        .map((l) => l.trimRight())
        .where((l) => l.isNotEmpty)
        .take(4)
        .join(' ');
    if (lines.isEmpty) return 'it failed with no diagnostic';
    return lines.length > 400 ? '${lines.substring(0, 400)}…' : lines;
  }
}

extension on FormalPropertyStatus {
  bool get bucketIsCounterexample =>
      this == FormalPropertyStatus.counterexample ||
      this == FormalPropertyStatus.notReached;

  bool get isUndecided =>
      this == FormalPropertyStatus.inconclusive ||
      this == FormalPropertyStatus.didNotRun;
}
