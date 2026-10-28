// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/formal_property_status.dart';
import 'package:simcrux/domain/enums/formal_verdict.dart';
import 'package:simcrux/domain/enums/hdl_language.dart';
import 'package:simcrux/domain/enums/kill_signal.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/formal_config.dart';
import 'package:simcrux/domain/models/formal_diagnostic.dart';
import 'package:simcrux/domain/models/riscv_config.dart';
import 'package:simcrux/domain/models/sby_outcome.dart';
import 'package:simcrux/domain/models/sby_script.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/services/formal/formal_containment.dart';
import 'package:simcrux/services/formal/formal_property_identity.dart';
import 'package:simcrux/services/formal/formal_reconciliation.dart';
import 'package:simcrux/services/formal/formal_run_analysis.dart';
import 'package:simcrux/services/formal/sby_status_database.dart';
import 'package:simcrux/services/formal/sby_status_reader.dart';
import 'package:simcrux/services/simulator/process_backed_simulator_driver.dart';
import 'package:simcrux/services/simulator/python_traceback_reducer.dart';

/// Everything one `sby` run needs, worked out from the spec before
/// anything is spawned or staged.
@immutable
class SbyJob {
  /// Creates a job description.
  const SbyJob({
    required this.taskDirectory,
    this.problem,
    this.validationProblems = const <String>[],
    this.sbyFile = '',
    this.task,
    this.spawnDirectory,
    this.argv = const <String>[],
    this.demo = false,
    this.demoCaseDir,
    this.projectRoot,
    this.subject = 'the proof',
    this.unavailableMessage = '',
  });

  /// The `-d` directory, inside the test's working directory.
  final String taskDirectory;

  /// Why the run must be refused before anything touches the disk, or null.
  final String? problem;

  /// What is missing for a real run (demo mode ignores these).
  final List<String> validationProblems;

  /// The `.sby` job file, absolute, or empty.
  final String sbyFile;

  /// The `[tasks]` name, when one is selected.
  final String? task;

  /// The directory `sby` runs in: the one holding the `.sby` file.
  final String? spawnDirectory;

  /// The command line.
  final List<String> argv;

  /// True in demo mode.
  final bool demo;

  /// The capture this demo run replays, or null when none is configured.
  final String? demoCaseDir;

  /// The project file's directory, for property locations.
  final String? projectRoot;

  /// How a failure message names the run (`task \`prove\``, `insn_add_ch0`).
  final String subject;

  /// The remediation when the binary is not found.
  final String unavailableMessage;
}

/// What the run produced, before it is turned into metrics.
@immutable
class SbyRunFacts {
  /// Creates the facts.
  const SbyRunFacts({
    required this.outcome,
    required this.script,
    required this.reconciliation,
    required this.exitCode,
    required this.measured,
    required this.traceUnresolved,
    required this.exitCodeWithheld,
  });

  /// What the log said.
  final SbyOutcome outcome;

  /// What the `.sby` file configured, when it could be read.
  final SbyScript? script;

  /// The log's verdict reconciled with the per-property statuses.
  final FormalReconciliation reconciliation;

  /// The process exit code.
  final int? exitCode;

  /// The stopwatch around the job.
  final Duration measured;

  /// The first announced trace that could not be resolved inside the task
  /// directory, verbatim.
  final String? traceUnresolved;

  /// True when an exit code of 0 was withheld from the scheduler because
  /// the verdict was not `PASS`.
  final bool exitCodeWithheld;

  /// The verdict to report.
  FormalVerdict get verdict => reconciliation.verdict;
}

/// [SimulatorDriver] for **one SymbiYosys task per SimCrux test** (id `sby`).
///
/// The general driver the RISC-V track is built on: [RiscvFormalDriver]
/// is this driver plus the RISC-V layer (its metric names, its demo corpus,
/// its toolchain guidance).
///
/// ## The verdict comes from the log, never from the exit code
///
/// `sby` states its conclusion on a `DONE (…)` line, read by
/// [SbyLogReader]. The per-property statuses come from `sby --live jsonl`
/// on the same stream ([SbyStatusReader]) and from the task's
/// `status.sqlite` after the run ([SbyStatusDatabase]). The two are
/// reconciled by [FormalReconciliation.reconcile]: the more conservative
/// fact wins, a disagreement is recorded as `formal.verdict_disagreement`,
/// and nothing is ever resolved toward Proved. The exit code is recorded in
/// `formal.process_exit_code` and never decides anything; an exit code of 0
/// is withheld from the scheduler whenever the verdict is not `PASS`.
///
/// ## Containment
///
/// `sby -f` deletes its `-d` directory before it runs, so the driver alone
/// chooses it: `<test working dir>/<task>`, where `<task>` is the
/// `[tasks]` name or the job file's basename and must be one safe path
/// segment, or the run is refused before anything is spawned. Traces `sby`
/// announces are used only when they resolve inside the task directory.
/// `extra_args` may not choose the work directory either.
///
/// ## Tiering
///
/// **Never gated.** A formal verdict is correctness and is free.
class SbyDriver extends ProcessBackedSimulatorDriver {
  /// Creates an [SbyDriver]. [analyser] reads the finished task directory
  /// for the SVA diagnostic, the pre-trace marker and the dropped-property
  /// guard; tests pass one with a scripted Yosys.
  SbyDriver({
    super.launcher,
    super.reaper,
    super.killGrace,
    this._analyser = const FormalRunAnalyser(),
    this._statusReader = SbyStatusDatabase.readDetailed,
  });

  final FormalRunAnalyser _analyser;

  /// Reads a finished task's `status.sqlite`. Called only after `sby` has
  /// exited (a live run is read from the `jsonl` stream); tests pass one
  /// that records when it is called.
  final Future<SbyStatusRead> Function(String path, {String? task})
  _statusReader;

  /// Reads [path] and writes the reason to the run log when the database
  /// could not be used. A missing file is a run that never created one and
  /// needs no note; every other reason is one the log must carry, because
  /// the verdict then rests on the stream and the log alone.
  Future<SbyStatusSnapshot?> _readStatusDatabase(
    String path,
    String? task,
    StreamController<TestExecutionEvent> controller,
  ) async {
    final result = await _statusReader(path, task: task);
    final reason = result.unreadable;
    if (reason != null && reason != SbyStatusUnreadable.missing) {
      faultNotice(
        controller,
        'status.sqlite is unreadable (${reason.token}); the verdict is from '
        'the log and the status stream.',
      );
    }
    return result.snapshot;
  }

  /// Metric key: the frontend that read the design (`builtin`, `slang`,
  /// `verific`, `unknown`).
  static const String kMetricFrontend = 'formal.frontend';

  /// Metric key: why the row did not run, when SimCrux knows
  /// ([FormalNotRunReason]).
  static const String kMetricNotRunReason = 'formal.not_run_reason';

  /// Metric key: the refused construct's class ([SvaConstructClass]).
  static const String kMetricSvaClass = 'formal.sva.class';

  /// Metric key: the refused construct as written (`|=>`).
  static const String kMetricSvaConstruct = 'formal.sva.construct';

  /// Metric key: where the frontend refused it (`handshake.sv:42`).
  static const String kMetricSvaLocation = 'formal.sva.location';

  /// Metric key: `assert` or `cover`, for the first property whose result
  /// depends on state before the trace began. Absent when none does.
  static const String kMetricPretraceKind = 'formal.pretrace.kind';

  /// Metric key: that property's `$past` depth.
  static const String kMetricPretraceDepth = 'formal.pretrace.depth';

  /// Metric key: the step it fired at.
  static const String kMetricPretraceStep = 'formal.pretrace.step';

  /// Metric key: its location.
  static const String kMetricPretraceLocation = 'formal.pretrace.location';

  /// The `simulatorId` this driver claims.
  static const String kId = FormalConfig.kSbySimulatorId;

  /// Metric key: the tool, `sby`.
  static const String kMetricTool = 'formal.tool';

  /// Metric key: `normal` or `demo`. A demo row can never be mistaken for a
  /// real proof in an exported report.
  static const String kMetricRunMode = 'formal.run_mode';

  /// Metric key: the `[tasks]` name.
  static const String kMetricTask = 'formal.task';

  /// Metric key: the proof mode (`bmc`, `prove`, `cover`, `live`).
  static const String kMetricMode = 'formal.mode';

  /// Metric key: the reconciled verdict token.
  static const String kMetricVerdict = kFormalVerdictMetric;

  /// Metric key: `sby`'s `rc=`.
  static const String kMetricReturnCode = 'formal.rc';

  /// Metric key: the process exit code. Recorded, never the verdict.
  static const String kMetricProcessExitCode = 'formal.process_exit_code';

  /// Metric key: the configured bound.
  static const String kMetricDepthConfigured = 'formal.depth_configured';

  /// Metric key: the deepest step the log reported.
  static const String kMetricDepthReached = 'formal.depth_reached';

  /// Metric key: wall time in milliseconds.
  ///
  /// A real run reports the stopwatch around the `sby` process, to the
  /// millisecond. `sby`'s own "Elapsed clock time" is whole seconds, so
  /// times 1000 it read `0` for every proof shorter than a second; it is
  /// used only in `mode: demo`, where a stopwatch would time the replay.
  static const String kMetricWallTimeMs = 'formal.wall_time_ms';

  /// Metric key: `measured` (a stopwatch around the process, every real
  /// run) or `engine` (`sby`'s own clock, whole seconds, a demo replay).
  static const String kMetricWallTimeSource = 'formal.wall_time_source';

  /// Metric key: the engine (`smtbmc`, `abc`, …), the first word of the
  /// engine specification.
  static const String kMetricEngine = 'formal.engine';

  /// Metric key: the rest of the engine specification (`yices`, `pdr`).
  static const String kMetricSolver = 'formal.solver';

  /// Metric key: how many traces the log announced.
  static const String kMetricTraceCount = 'formal.trace_count';

  /// Metric key: an announced trace that did not resolve inside the task
  /// directory, verbatim.
  static const String kMetricTraceUnresolved = 'formal.trace_unresolved';

  /// Metric key: `noassert` or `ignore_assertions` when the task's
  /// `[script]` reads the design with assertions turned off
  /// ([SbyScript.assertionsDisabledFor]). Absent otherwise.
  static const String kMetricAssertionsDisabled = 'formal.assertions_disabled';

  /// Metric key: `1` when the task runs with `[options] multiclock on`.
  /// Absent otherwise. Its witness steps are not one sample of one formal
  /// clock, so a hand-off states no step for it.
  static const String kMetricMulticlock = 'formal.multiclock';

  /// Metric key: how many properties the mode checks.
  static const String kMetricProperties = 'formal.properties';

  /// Metric key: properties that ended as a counterexample or unreached.
  static const String kMetricPropertiesFailed = 'formal.properties_failed';

  /// Metric key: properties that ended undecided or did not run.
  static const String kMetricPropertiesUndecided =
      'formal.properties_undecided';

  /// Metric key: `1` when the sources disagreed, `0` when they agreed.
  static const String kMetricVerdictDisagreement =
      'formal.verdict_disagreement';

  /// Metric key: `1` when more properties existed than were recorded.
  static const String kMetricPropertiesTruncated =
      'formal.properties_truncated';

  /// Prefix of the indexed per-property keys:
  /// `formal.property.<n>.<field>`, `n` from 0, fields [kPropertyFields].
  static const String kPropertyPrefix = 'formal.property.';

  /// The per-property fields, in the order they are written.
  static const List<String> kPropertyFields = <String>[
    'kind',
    'location',
    'status',
    'label',
    'step',
    'trace',
    'id',
    'pretrace',
    'reads',
    'vacuous',
  ];

  /// `formal.property.<n>.vacuous` for an assertion whose enable is a
  /// constant false; otherwise the field holds the `file:line` of the
  /// assumption that holds the enable false.
  static const String kVacuousConstant = 'const';

  /// `file:line` of a Yosys `src` attribute (`vacuity.sv:10.3-10.52`), the
  /// first of several (`a.sv:1.2-1.3|b.sv:4.5-4.6`).
  static String _fileLine(String src) {
    final first = src.split('|').first;
    final match = RegExp(r'^(.*?):(\d+)').firstMatch(first);
    return match == null ? first : '${match.group(1)}:${match.group(2)}';
  }

  /// The most properties written as indexed metrics. The counts above
  /// cover every property; the rows stop here.
  static const int kMaxPropertyRows = 256;

  /// [kMetricWallTimeSource] value: `sby`'s own reported clock time.
  static const String kWallTimeSourceEngine = 'engine';

  /// [kMetricWallTimeSource] value: this driver's stopwatch.
  static const String kWallTimeSourceMeasured = 'measured';

  /// Filename the demo corpus gives its captured log when `case.json` does
  /// not name one.
  static const String kDefaultDemoLogName = 'sby.log';

  /// The `sby` options that choose a work directory or delete one. Only the
  /// driver passes them.
  static const Set<String> kReservedOptions = <String>{
    '-d',
    '--prefix',
    '-f',
    '-b',
    '-t',
    '-T',
    '--setup',
    '--statusreset',
  };

  @override
  String get id => kId;

  @override
  String get displayName => 'SymbiYosys';

  /// The prefix of every line this driver writes into the run log.
  @protected
  String get logTag => 'sby';

  /// Whether the spawn asks for `--live jsonl`. Every measured `sby`
  /// (0.68 to 0.70) supports it; the RISC-V track keeps its shipped
  /// command line.
  @protected
  bool get liveStatus => true;

  /// Whether a finished run's task directory is read for the frontend, the
  /// SVA diagnostic, the pre-trace marker and the dropped-property guard.
  @protected
  bool get analysesRuns => true;

  /// Declares no HDL languages: `sby` reads the sources its job file's
  /// `[files]` and `[script]` name, never `TestSpec.sources`.
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
      detectVersionOf(resolveBinary(config, FormalConfig.kDefaultSbyBinary));

  /// No-op: `sby` reads, elaborates and solves in one invocation.
  @override
  Future<CompileResult> compile(CompileRequest request) async =>
      const CompileResult(
        success: true,
        artifactPath: null,
        stdout: '',
        stderr: '',
      );

  // ── the job ────────────────────────────────────────────────────────

  /// Works out the job for [request] from its `formal:` block.
  @protected
  SbyJob prepareJob(ExecuteRequest request) {
    final cfg = request.test.formal ?? const FormalConfig();
    final sbyFile = resolveSbyFile(cfg.sbyFile);
    final task = cfg.task;
    final segment =
        task ??
        (sbyFile.isEmpty ? 'proof' : p.basenameWithoutExtension(sbyFile));
    final taskDir = p.join(request.workingDirectory, segment);
    final subject = task == null ? 'the proof' : 'task `$task`';
    final segmentProblem = FormalContainment.segmentProblem(segment);
    if (segmentProblem != null ||
        !p.isWithin(request.workingDirectory, taskDir)) {
      return SbyJob(
        taskDirectory: taskDir,
        subject: subject,
        problem:
            '`${task != null ? 'formal.task' : 'formal.sby_file'}` "$segment" '
            'cannot name the SymbiYosys task directory '
            '(${segmentProblem ?? 'it leaves the working directory'}). '
            '`sby -f` deletes its task directory before it runs, so the '
            'proof was not started.',
      );
    }
    if (cfg.effectiveMode == FormalRunMode.demo) {
      final root = cfg.demoOutputs;
      final caseName = cfg.demoCase ?? request.test.name;
      final caseProblem = FormalContainment.segmentProblem(caseName);
      if (caseProblem != null) {
        return SbyJob(
          taskDirectory: taskDir,
          subject: subject,
          problem:
              '$logTag: demo case "$caseName" is not a single directory '
              'name ($caseProblem), so nothing was replayed.',
        );
      }
      return SbyJob(
        taskDirectory: taskDir,
        task: task,
        demo: true,
        demoCaseDir: root == null || root.isEmpty
            ? null
            : p.join(root, caseName),
        projectRoot: cfg.projectRoot,
        subject: subject,
      );
    }
    final reserved = <String>[
      for (final arg in cfg.extraArgs ?? const <String>[])
        if (kReservedOptions.contains(arg) ||
            arg.startsWith('--prefix=') ||
            (arg.startsWith('-d') && arg.length > 2))
          arg,
    ];
    if (reserved.isNotEmpty) {
      return SbyJob(
        taskDirectory: taskDir,
        subject: subject,
        problem:
            '`formal.extra_args` may not pass ${reserved.join(', ')}: '
            'SimCrux alone chooses and clears the SymbiYosys work directory, '
            'so the proof was not started.',
      );
    }
    final binary =
        cfg.sbyBinary ??
        resolveBinary(request.binaryConfig, FormalConfig.kDefaultSbyBinary);
    final values = <String, String>{
      'sby_file': sbyFile,
      'task_dir': taskDir,
      'task': task ?? '',
      'name': request.test.name,
      'work_dir': request.workingDirectory,
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
            taskDir,
            if (liveStatus) ...<String>['--live', 'jsonl'],
            for (final MapEntry(:key, :value)
                in (cfg.tools ?? const <String, String>{}).entries) ...<String>[
              '--$key',
              value,
            ],
            ...?cfg.extraArgs,
            sbyFile,
            ?task,
          ];
    return SbyJob(
      taskDirectory: taskDir,
      validationProblems: cfg.validateForRun(),
      sbyFile: sbyFile,
      task: task,
      spawnDirectory: sbyFile.isEmpty ? null : p.dirname(sbyFile),
      argv: argv,
      projectRoot: cfg.projectRoot,
      subject: subject,
      unavailableMessage:
          'SymbiYosys (`$binary`) was not found. Put the directory holding '
          '`sby` (an OSS CAD Suite `bin/`, for example) on PATH, or give its '
          'path: Settings → Engines in the app, `formal.sby_binary` in the '
          'project file for a `--ci` run (with `--allow-project-tooling`).',
    );
  }

  /// [file] made absolute and normalised, or empty.
  @protected
  String resolveSbyFile(String? file) {
    if (file == null || file.isEmpty) return '';
    if (p.isAbsolute(file)) return p.normalize(file);
    return p.normalize(p.absolute(file));
  }

  /// The metrics a specialisation records before the `formal.*` set, in
  /// its own order. Empty here.
  @protected
  Map<String, String> trackMetrics(ExecuteRequest request, SbyRunFacts facts) =>
      const <String, String>{};

  // ── execute ────────────────────────────────────────────────────────

  @override
  Future<void> runExecute(
    ExecuteRequest request,
    StreamController<TestExecutionEvent> controller,
  ) async {
    final startedAt = DateTime.now().toUtc();
    final stopwatch = Stopwatch()..start();
    final job = prepareJob(request);
    if (job.problem != null) {
      await failBeforeRunning(controller, startedAt, job.problem!);
      return;
    }
    if (job.demo) {
      await _runDemo(request, job, controller, startedAt, stopwatch);
      return;
    }
    if (job.validationProblems.isNotEmpty) {
      await failBeforeRunning(
        controller,
        startedAt,
        job.validationProblems.join(' '),
      );
      return;
    }
    // A spawn into a folder that does not exist fails with the same
    // "No such file or directory" as a missing binary, which used to be
    // reported as "`sby` is not on PATH". Say what is actually missing.
    final spawnDirectory = job.spawnDirectory;
    if (spawnDirectory != null && !Directory(spawnDirectory).existsSync()) {
      await failBeforeRunning(
        controller,
        startedAt,
        missingSpawnDirectoryMessage(spawnDirectory),
      );
      return;
    }

    final script = _readScript(job.sbyFile);
    final reader = SbyLogReader();
    final live = SbyStatusReader(task: job.task);
    // SymbiYosys is Python: a crash arrives as a multi-frame traceback.
    final reducer = PythonTracebackReducer();
    // The lines a frontend refusal could be on, bounded.
    final errorLines = <String>[];

    await runProcessStreaming(
      request: request,
      executable: job.argv.first,
      args: job.argv.skip(1).toList(growable: false),
      environment: request.binaryConfig.extraEnv,
      startedAt: startedAt,
      controller: controller,
      unavailableBinaryLabel: job.argv.first,
      unavailableMessage: job.unavailableMessage,
      unavailableToolName: 'SymbiYosys',
      workingDirectoryOverride: job.spawnDirectory,
      onLine: (line, {required fromStderr}) {
        reader.addLine(line);
        live.addLine(line);
        reducer.addLine(line);
        if (errorLines.length < 200 &&
            (line.contains('ERROR') ||
                line.contains('error:') ||
                line.contains('Source line'))) {
          errorLines.add(line);
        }
      },
      buildFinished: (exitCode, process) async {
        stopwatch.stop();
        // `-d` is the task directory, and `sby` keeps its status database
        // there. Read only now that `sby` has exited.
        final database = await _readStatusDatabase(
          p.join(job.taskDirectory, 'status.sqlite'),
          job.task,
          controller,
        );
        final analysis = await _analyse(
          request,
          job,
          script,
          reader.outcome,
          errorLines,
        );
        for (final note in analysis.notes) {
          faultNotice(controller, note);
        }
        return await buildTerminalEvent(
          request: request,
          job: job,
          outcome: reader.outcome,
          live: live,
          database: database,
          script: script,
          exitCode: exitCode,
          startedAt: startedAt,
          measured: stopwatch.elapsed,
          killSignal: process.killSignal,
          tracebackSummary: reducer.summary,
          controller: controller,
          analysis: analysis,
        );
      },
    );
  }

  /// Reads the finished task directory: which frontend read the design,
  /// what it refused (a run that stopped before the design elaborated),
  /// and what the elaborated design holds (a run that reached a verdict).
  Future<FormalRunAnalysis> _analyse(
    ExecuteRequest request,
    SbyJob job,
    SbyScript? script,
    SbyOutcome outcome,
    List<String> errorLines,
  ) async {
    if (!analysesRuns) return FormalRunAnalysis.none;
    try {
      return await _analyser.analyse(
        taskDirectory: job.taskDirectory,
        task: job.task,
        script: script,
        logLines: errorLines,
        classify:
            outcome.verdict == FormalVerdict.error ||
            outcome.verdict == FormalVerdict.noOutcome,
        readDesign:
            outcome.verdict == FormalVerdict.pass ||
            outcome.verdict == FormalVerdict.fail,
        yosys: _yosysFor(request, job),
        environment: request.binaryConfig.extraEnv,
      );
    } on Object catch (e) {
      return FormalRunAnalysis(
        notes: <String>['the task directory could not be analysed ($e).'],
      );
    }
  }

  /// The Yosys `sby` ran with: the job's `formal.tools.yosys`, else the one
  /// beside an absolute `sby`, else `yosys` on PATH.
  String _yosysFor(ExecuteRequest request, SbyJob job) {
    final configured = request.test.formal?.tools?['yosys'];
    if (configured != null && configured.isNotEmpty) return configured;
    final sby = job.argv.isEmpty ? '' : job.argv.first;
    if (p.isAbsolute(sby)) {
      final name = Platform.isWindows ? 'yosys.exe' : 'yosys';
      final beside = p.join(p.dirname(sby), name);
      if (File(beside).existsSync()) return beside;
    }
    return 'yosys';
  }

  /// Ends the run as a `fail` before anything is spawned or staged.
  @protected
  Future<void> failBeforeRunning(
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

  /// Why the proof was not started when the folder `sby` runs in, the one
  /// holding the `.sby` file, does not exist.
  @protected
  String missingSpawnDirectoryMessage(String directory) =>
      'SymbiYosys was not started: the folder holding the `.sby` file, '
      '$directory, does not exist. Check `formal.sby_file` in the project '
      "file; a relative path resolves against the project file's folder.";

  /// The demo message when no capture corpus is configured.
  @protected
  String demoNotConfiguredMessage() =>
      '$logTag: `formal.demo_outputs` is not set, so there is no captured '
      'corpus to replay.';

  /// Demo execute: replay a committed capture. No spawn. Every line still
  /// reaches the same readers and the stream, and the terminal event is
  /// built by the same [buildTerminalEvent].
  Future<void> _runDemo(
    ExecuteRequest request,
    SbyJob job,
    StreamController<TestExecutionEvent> controller,
    DateTime startedAt,
    Stopwatch stopwatch,
  ) async {
    final caseDir = job.demoCaseDir;
    final reader = SbyLogReader();
    final live = SbyStatusReader(task: job.task);
    final reducer = PythonTracebackReducer();
    var exitCode = 0;
    SbyScript? script;
    SbyStatusSnapshot? database;

    if (caseDir == null) {
      controller.add(
        TestLogLine(
          line: demoNotConfiguredMessage(),
          fromStderr: true,
          timestamp: DateTime.now().toUtc(),
        ),
      );
    } else {
      final manifest = await _demoManifest(caseDir);
      // Checked before anything is staged or replayed: a manifest that
      // names a file outside its directories is refused as a whole, so a
      // passing log beside it cannot turn the case green.
      final traceProblem = _demoTraceProblem(
        manifest,
        caseDir,
        job.taskDirectory,
      );
      if (traceProblem != null) {
        controller.add(
          TestLogLine(
            line: traceProblem,
            fromStderr: true,
            timestamp: DateTime.now().toUtc(),
          ),
        );
        await failBeforeRunning(controller, startedAt, traceProblem);
        return;
      }
      script = SbyScript(proofMode: manifest.proofMode, depth: manifest.depth);
      exitCode = manifest.exitCode;
      controller.add(
        TestLogLine(
          line:
              '$logTag: mode=demo — replaying captured SymbiYosys output '
              'from $caseDir (no SymbiYosys, no subprocess).',
          fromStderr: false,
          timestamp: DateTime.now().toUtc(),
        ),
      );
      await _stageDemoTraces(manifest, caseDir, job.taskDirectory, controller);
      final logPath = FormalContainment.containedPath(caseDir, manifest.log);
      final log = logPath == null ? null : await _readOrNull(logPath);
      if (log == null) {
        controller.add(
          TestLogLine(
            line:
                '$logTag: demo corpus has no ${manifest.log} at '
                '$caseDir — the run proceeds and reports the absence of a '
                'verdict, exactly as a real run that produced none would.',
            fromStderr: true,
            timestamp: DateTime.now().toUtc(),
          ),
        );
      } else {
        for (final line in const LineSplitter().convert(log)) {
          reader.addLine(line);
          live.addLine(line);
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
      final statusDb = manifest.statusDb;
      if (statusDb != null) {
        final dbPath = FormalContainment.containedPath(caseDir, statusDb);
        if (dbPath != null) {
          database = await _readStatusDatabase(dbPath, job.task, controller);
        }
      }
    }

    stopwatch.stop();
    controller.add(
      await buildTerminalEvent(
        request: request,
        job: job,
        outcome: reader.outcome,
        live: live,
        database: database,
        script: script,
        exitCode: exitCode,
        startedAt: startedAt,
        measured: stopwatch.elapsed,
        killSignal: null,
        tracebackSummary: reducer.summary,
        controller: controller,
      ),
    );
    await controller.close();
  }

  // ── the shared tail: reconcile, resolve the trace, emit ────────────

  /// Builds the terminal event. **Every mode reaches this unchanged.**
  ///
  /// The status is always `pass` or `fail`, never `unknown` (which would
  /// hand the verdict back to the exit code) and never `vacuous` (which the
  /// scheduler treats as success and sweeps the counterexample with).
  @protected
  Future<TestExecutionFinished> buildTerminalEvent({
    required ExecuteRequest request,
    required SbyJob job,
    required SbyOutcome outcome,
    required SbyStatusReader live,
    required SbyStatusSnapshot? database,
    required SbyScript? script,
    required int? exitCode,
    required DateTime startedAt,
    required Duration measured,
    required KillSignal? killSignal,
    required String? tracebackSummary,
    required StreamController<TestExecutionEvent> controller,
    FormalRunAnalysis analysis = FormalRunAnalysis.none,
  }) async {
    final reconciled = FormalReconciliation.reconcile(
      taskVerdict: outcome.verdict,
      proofMode: script?.proofMode,
      live: live,
      database: database,
      files: script?.files ?? const <String, String>{},
      sbyDirectory: job.spawnDirectory,
      projectRoot: job.projectRoot,
    );
    // The id of an unlabelled property: a signature over its text, so it
    // is the same in the next run of the same design.
    final reconciliation = reconciled.withSignatures(
      await FormalPropertyIdentity.signatures(
        properties: reconciled.properties.take(kMaxPropertyRows),
        projectRoot: job.projectRoot,
        taskDirectory: job.taskDirectory,
        sbyDirectory: job.spawnDirectory,
        files: script?.files ?? const <String, String>{},
      ),
    );
    if (live.malformedCount > 0) {
      faultNotice(
        controller,
        '${live.malformedCount} status line(s) could not be read; the '
        'verdict is from the log and status.sqlite.',
      );
    }
    if (reconciliation.truncated) {
      faultNotice(
        controller,
        'more properties than SimCrux records; the counts cover the ones '
        'read.',
      );
    }

    // The hand-off to WaveCrux: the first announced trace that resolves
    // inside the task directory; else the first property trace that does.
    String? waveformPath;
    String? traceUnresolved;
    if (outcome.traces.isNotEmpty) {
      for (final trace in outcome.traces) {
        waveformPath = resolveTrace(trace, job.taskDirectory);
        if (waveformPath != null) break;
      }
      if (waveformPath == null) {
        traceUnresolved = outcome.traces.first;
        faultNotice(
          controller,
          'trace "${outcome.traces.first}" does not resolve to a file '
          'inside ${job.taskDirectory}; no counterexample is attached.',
        );
      }
    }
    if (waveformPath == null) {
      for (final property in reconciliation.properties) {
        final trace = property.trace;
        if (trace == null) continue;
        waveformPath = resolveTrace(trace, job.taskDirectory);
        if (waveformPath != null) break;
      }
    }

    final verdict = reconciliation.verdict;
    final withheld = !verdict.proved && exitCode == 0;
    final facts = SbyRunFacts(
      outcome: outcome,
      script: script,
      reconciliation: reconciliation,
      exitCode: exitCode,
      measured: measured,
      traceUnresolved: traceUnresolved,
      exitCodeWithheld: withheld,
    );
    final metrics = <String, String>{
      ...trackMetrics(request, facts),
      ..._formalMetrics(job, facts, live, database),
    };

    var status = verdict.status;
    var failureMessage = describe(
      verdict,
      outcome,
      job.subject,
      proofMode: metrics[kMetricMode] ?? script?.proofMode,
    );
    if (reconciliation.taskVerdict.proved && !verdict.proved) {
      final unproved = reconciliation.properties
          .where((r) => !r.status.verdict.proved)
          .toList(growable: false);
      final first = unproved.first;
      failureMessage =
          'SymbiYosys reported PASS for ${job.subject}, but '
          '${unproved.length} ${unproved.length == 1 ? 'property' : 'properties'} '
          'did not end proved (first: ${first.displayName}, '
          '${first.status.wireName}). The more conservative result stands.';
    }

    // `sby` said PASS but the process did not exit cleanly: a contradicted
    // pass is not a pass.
    if (verdict.proved && exitCode != null && exitCode != 0) {
      status = TestStatus.fail;
      failureMessage =
          'SymbiYosys reported PASS but exited $exitCode — the proof result '
          'is contradicted by the process outcome.';
    }

    final explained = _applyAnalysis(
      metrics: metrics,
      analysis: analysis,
      job: job,
      script: script,
      verdict: verdict,
      outcome: outcome,
      reconciliation: reconciliation,
    );
    if (explained != null) {
      status = TestStatus.fail;
      failureMessage = explained;
    }

    // The driver never hands the scheduler an exit code that contradicts its
    // own verdict: `0` is what every exit-code classifier reads as a pass.
    final dropped =
        metrics[kMetricNotRunReason] == FormalNotRunReason.dropped.wireName;
    final reportedExitCode = withheld || dropped ? null : exitCode;
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

  Map<String, String> _formalMetrics(
    SbyJob job,
    SbyRunFacts facts,
    SbyStatusReader live,
    SbyStatusSnapshot? database,
  ) {
    final outcome = facts.outcome;
    final reconciliation = facts.reconciliation;
    final engineSpec = outcome.engine?.trim();
    final engineWords = engineSpec == null || engineSpec.isEmpty
        ? const <String>[]
        : engineSpec.split(RegExp(r'\s+'));
    String? recordMode;
    if (live.mode != null) {
      recordMode = live.mode;
    } else {
      for (final record in database?.records ?? const <SbyStatusRecord>[]) {
        if (record.mode != null) {
          recordMode = record.mode;
          break;
        }
      }
    }
    final mode = recordMode ?? facts.script?.modeFor(job.task);
    final assertionsDisabled = facts.script?.assertionsDisabledFor(job.task);
    final metrics = <String, String>{
      kMetricTool: 'sby',
      kMetricRunMode: job.demo ? 'demo' : 'normal',
      kMetricTask: ?job.task,
      kMetricMode: ?mode,
      kMetricVerdict: facts.verdict.wireName,
      if (outcome.returnCode != null)
        kMetricReturnCode: '${outcome.returnCode}',
      if (facts.exitCode != null) kMetricProcessExitCode: '${facts.exitCode}',
      if (facts.script?.depth != null)
        kMetricDepthConfigured: '${facts.script!.depth}',
      if (outcome.depthReached != null)
        kMetricDepthReached: '${outcome.depthReached}',
      if (job.demo && outcome.elapsedSeconds != null) ...<String, String>{
        kMetricWallTimeMs: '${outcome.elapsedSeconds! * 1000}',
        kMetricWallTimeSource: kWallTimeSourceEngine,
      } else ...<String, String>{
        kMetricWallTimeMs: '${facts.measured.inMilliseconds}',
        kMetricWallTimeSource: kWallTimeSourceMeasured,
      },
      if (engineWords.isNotEmpty) kMetricEngine: engineWords.first,
      if (engineWords.length > 1) kMetricSolver: engineWords.skip(1).join(' '),
      if (outcome.traces.isNotEmpty)
        kMetricTraceCount: '${outcome.traces.length}',
      kMetricTraceUnresolved: ?facts.traceUnresolved,
      kMetricAssertionsDisabled: ?assertionsDisabled,
      if (facts.script?.multiclockFor(job.task) ?? false)
        kMetricMulticlock: '1',
    };
    if (reconciliation.disagreement != null) {
      metrics[kMetricProperties] = '${reconciliation.properties.length}';
      metrics[kMetricPropertiesFailed] = '${reconciliation.failedCount}';
      metrics[kMetricPropertiesUndecided] = '${reconciliation.undecidedCount}';
      metrics[kMetricVerdictDisagreement] = reconciliation.disagreement!
          ? '1'
          : '0';
    } else if (database != null) {
      // `status.sqlite` was read and lists no property the mode checks: the
      // task checked nothing, which a PASS alone does not say. Recorded so
      // the row can be shown as such instead of as a proof.
      metrics[kMetricProperties] = '0';
    }
    if (reconciliation.truncated ||
        reconciliation.properties.length > kMaxPropertyRows) {
      metrics[kMetricPropertiesTruncated] = '1';
    }
    var n = 0;
    for (final property in reconciliation.properties.take(kMaxPropertyRows)) {
      final prefix = '$kPropertyPrefix$n.';
      metrics['${prefix}kind'] = property.kind;
      metrics['${prefix}location'] = property.location;
      metrics['${prefix}status'] = property.status.wireName;
      if (property.label != null) metrics['${prefix}label'] = property.label!;
      if (property.step != null) metrics['${prefix}step'] = '${property.step}';
      final trace = property.trace;
      if (trace != null) {
        final resolved = resolveTrace(trace, job.taskDirectory);
        if (resolved != null) {
          metrics['${prefix}trace'] = p
              .relative(resolved, from: job.taskDirectory)
              .replaceAll(r'\', '/');
        }
      }
      final identity = property.crossRunIdentity;
      if (identity != null) metrics['${prefix}id'] = identity;
      n++;
    }
    return metrics;
  }

  /// Writes what [analysis] found into [metrics], and returns the failure
  /// message it explains, or null when it explains nothing.
  ///
  /// Never moves a row toward a proof: a refused construct annotates a row
  /// that is already Did not run; a dropped property turns a `PASS` that
  /// checked nothing into Did not run; a pre-trace exposure marks a row
  /// whose verdict stands.
  String? _applyAnalysis({
    required Map<String, String> metrics,
    required FormalRunAnalysis analysis,
    required SbyJob job,
    required SbyScript? script,
    required FormalVerdict verdict,
    required SbyOutcome outcome,
    required FormalReconciliation reconciliation,
  }) {
    if (analysis.frontend != FormalFrontend.unknown) {
      metrics[kMetricFrontend] = analysis.frontend.wireName;
    }
    String? message;
    final refusal = analysis.refusal;
    if (refusal != null && !verdict.proved) {
      final location = refusal.file == null
          ? null
          : FormalReconciliation.normaliseLocation(
              refusal.location!,
              files: script?.files ?? const <String, String>{},
              sbyDirectory: job.spawnDirectory,
              projectRoot: job.projectRoot,
            ).location;
      metrics[kMetricNotRunReason] = FormalNotRunReason.svaUnsupported.wireName;
      metrics[kMetricSvaClass] = refusal.constructClass.wireName;
      if (refusal.construct != null) {
        metrics[kMetricSvaConstruct] = refusal.construct!;
      }
      if (location != null) metrics[kMetricSvaLocation] = location;
      final what = refusal.construct == null
          ? 'An assertion'
          : '`${refusal.construct}`';
      final where = location == null ? '' : ' at $location';
      final frontend = switch (refusal.frontend) {
        FormalFrontend.slang => 'The yosys-slang frontend',
        FormalFrontend.builtin => "Yosys's built-in frontend",
        FormalFrontend.verific || FormalFrontend.unknown => 'The frontend',
      };
      message =
          '$what$where is ${_classPhrase(refusal.constructClass)}. '
          '$frontend does not support it, so SymbiYosys did not run '
          '${job.subject}; nothing was proved.';
    } else if (verdict == FormalVerdict.error &&
        outcome.errorLine == null &&
        analysis.frontendError != null) {
      message =
          'SymbiYosys could not read the design for ${job.subject}: '
          '${analysis.frontendError}';
    }

    final mode = metrics[kMetricMode];
    if (verdict == FormalVerdict.pass && analysis.droppedFor(mode)) {
      final cover = mode?.toLowerCase() == 'cover';
      final declared = cover ? analysis.sourceCovers : analysis.sourceAsserts;
      metrics[kMetricNotRunReason] = FormalNotRunReason.dropped.wireName;
      message =
          'The sources declare $declared ${cover ? 'cover' : 'assert'} '
          '${declared == 1 ? 'statement' : 'statements'}, but none reached '
          'the elaborated design: the frontend dropped '
          '${declared == 1 ? 'it' : 'them'}, so ${job.subject} checked '
          'nothing and did not run.';
    }

    final facts = analysis.facts;
    if (facts != null) {
      var n = 0;
      var flagged = false;
      for (final property in reconciliation.properties.take(
        kMaxPropertyRows,
      )) {
        final step = property.step;
        final fired =
            property.status == FormalPropertyStatus.reached ||
            property.status == FormalPropertyStatus.counterexample;
        final exposure = facts.at(property.rawLocation);
        // The signals the property reads, for the cross-probe filters and
        // "Show in NetCrux". Names only, comma-joined, nearest first.
        if (exposure != null && exposure.reads.isNotEmpty) {
          metrics['$kPropertyPrefix$n.reads'] = exposure.reads.join(',');
        }
        // An assertion whose enable no run can make true: the assumption
        // that holds it off (`file:line`), or `const` for a constant enable.
        if (exposure != null && exposure.neverEnabled) {
          metrics['$kPropertyPrefix$n.vacuous'] = exposure.disabledBy.isEmpty
              ? kVacuousConstant
              : _fileLine(exposure.disabledBy.first);
        }
        // Measured on both frontends: a property `sby` reports at step s
        // samples the design at step s - 1, so a chain of depth N reads
        // before step 0 while s <= N.
        if (fired &&
            step != null &&
            exposure != null &&
            exposure.pastDepth > 0 &&
            step <= exposure.pastDepth) {
          metrics['$kPropertyPrefix$n.pretrace'] = '${exposure.pastDepth}';
          if (!flagged) {
            flagged = true;
            metrics[kMetricPretraceKind] =
                property.kind.toUpperCase() == 'COVER' ? 'cover' : 'assert';
            metrics[kMetricPretraceDepth] = '${exposure.pastDepth}';
            metrics[kMetricPretraceStep] = '$step';
            metrics[kMetricPretraceLocation] = property.location;
          }
        }
        n++;
      }
    }
    return message;
  }

  static String _classPhrase(SvaConstructClass c) => switch (c) {
    SvaConstructClass.implication => 'a temporal implication',
    SvaConstructClass.delay => 'a cycle delay',
    SvaConstructClass.repetition => 'a sequence repetition',
    SvaConstructClass.sequenceOp => 'a sequence operator',
    SvaConstructClass.namedSequence => 'a named sequence or property',
    SvaConstructClass.defaultClocking => 'a default clocking declaration',
    SvaConstructClass.livenessOp => 'a liveness operator',
    SvaConstructClass.other => 'an assertion form',
  };

  /// `base: ERROR: …`: the `sby` step that printed an error, and the error.
  static final RegExp _stepError = RegExp(r'^([\w.-]+):\s+(ERROR:.*)$');

  /// The failure message for [verdict], naming [subject].
  ///
  /// [proofMode] is the task's mode: in `cover` mode a `FAIL` means a cover
  /// statement was not reached, which is not a counterexample.
  @protected
  String? describe(
    FormalVerdict verdict,
    SbyOutcome outcome,
    String subject, {
    String? proofMode,
  }) {
    final depth = outcome.depthReached;
    switch (verdict) {
      case FormalVerdict.pass:
        return null;
      case FormalVerdict.fail when proofMode?.toLowerCase() == 'cover':
        final unreached = outcome.unreachedCovers;
        final within = depth == null ? '' : ' within ${depth + 1} steps';
        if (unreached.isEmpty) {
          return 'cover not reached: SymbiYosys could not reach a cover '
              'statement of $subject$within. No trace exists for an '
              'unreached cover.';
        }
        final count = unreached.length == 1
            ? 'a cover statement'
            : '${unreached.length} cover statements';
        return 'cover not reached: SymbiYosys could not reach $count of '
            '$subject$within (first: ${unreached.first}). No trace exists '
            'for an unreached cover.';
      case FormalVerdict.fail:
        return depth == null
            ? 'property violated: SymbiYosys found a counterexample for '
                  '$subject'
            : 'property violated at step $depth: SymbiYosys found a '
                  'counterexample for $subject';
      case FormalVerdict.unknown:
        // Deliberately not the word "pass" in any form.
        return 'inconclusive: SymbiYosys returned UNKNOWN for $subject'
            '${depth == null ? '' : ' (reached step $depth)'} — the property '
            'was neither proved nor refuted.';
      case FormalVerdict.timeout:
        return 'inconclusive: SymbiYosys hit its own solver timeout for '
            '$subject${depth == null ? '' : ' at step $depth'} — the property '
            'was not proved.';
      case FormalVerdict.error:
        final error = outcome.errorLine;
        if (error == null) {
          return 'SymbiYosys errored out for $subject — the proof did not run.';
        }
        final inStep = _stepError.firstMatch(error);
        if (inStep == null) return error;
        return 'SymbiYosys stopped in its `${inStep.group(1)}` step for '
            '$subject, so the proof did not run: ${inStep.group(2)}';
      case FormalVerdict.noOutcome:
        return 'SymbiYosys produced no verdict for $subject — no '
            '`DONE (…)` line was reported, so nothing was proved.';
    }
  }

  /// Writes a driver fault to the run log and to this process's stderr:
  /// `developer.log` is invisible in a release build, and these are the
  /// notes someone debugging a wrong-looking row needs.
  @protected
  void faultNotice(
    StreamController<TestExecutionEvent> controller,
    String message,
  ) {
    final line = '$logTag: $message';
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

  // ── trace resolution ───────────────────────────────────────────────

  /// Resolves a trace `sby` announced to an existing file **inside**
  /// [taskDirectory], or null.
  ///
  /// `sby` spells traces relative to the task directory
  /// (`engine_0/trace.vcd`), relative to the job's parent
  /// (`<task_dir_name>/engine_0/trace.vcd`), or absolute when `-d` was
  /// absolute; a capture replayed from another machine carries the original
  /// task directory's name as its first segment. A `.yw` witness is mapped
  /// to the `.vcd` beside it. Every candidate must lie inside
  /// [taskDirectory] after symlinks are resolved: a trace that escapes it is
  /// refused, never followed.
  String? resolveTrace(String trace, String taskDirectory) {
    final vcd = trace.toLowerCase().endsWith('.yw')
        ? '${trace.substring(0, trace.length - 3)}.vcd'
        : trace;
    final segments = p.split(vcd.replaceAll(r'\', '/'));
    final candidates = <String>[
      if (p.isAbsolute(vcd)) vcd,
      if (!p.isAbsolute(vcd)) ...<String>[
        p.join(taskDirectory, vcd),
        p.join(p.dirname(taskDirectory), vcd),
        if (segments.length > 1)
          p.joinAll(<String>[
            taskDirectory,
            ...segments.skip(1),
          ]),
      ],
    ];
    for (final candidate in candidates) {
      final contained = FormalContainment.containedPath(
        taskDirectory,
        candidate,
      );
      if (contained != null && File(contained).existsSync()) return contained;
    }
    return null;
  }

  // ── demo corpus ────────────────────────────────────────────────────

  Future<SbyDemoCase> _demoManifest(String caseDir) async {
    const fallback = SbyDemoCase(log: kDefaultDemoLogName);
    try {
      final file = File(p.join(caseDir, 'case.json'));
      if (!file.existsSync()) return fallback;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) return fallback;
      final log = decoded['log'];
      final traces = decoded['traces'];
      final trace = decoded['trace'];
      final statusDb = decoded['status_db'];
      return SbyDemoCase(
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
        statusDb: statusDb is String && statusDb.isNotEmpty ? statusDb : null,
      );
    } on Object {
      return fallback;
    }
  }

  /// Why the case must be refused, or null when every trace entry reads
  /// from inside [caseDir] and writes inside [taskDirectory].
  String? _demoTraceProblem(
    SbyDemoCase manifest,
    String caseDir,
    String taskDirectory,
  ) {
    for (final relative in manifest.traces) {
      if (_lexicallyContained(caseDir, relative) != null &&
          _lexicallyContained(taskDirectory, relative) != null) {
        continue;
      }
      return '$logTag: demo case refused: case.json trace entry '
          '"$relative" resolves outside the case directory $caseDir or the '
          'task directory $taskDirectory. Trace entries must be relative '
          'paths inside the case, e.g. `engine_0/trace.vcd`.';
    }
    return null;
  }

  /// [relative] under [root], or null unless strictly inside it (a lexical
  /// check, for a destination that does not exist yet).
  static String? _lexicallyContained(String root, String relative) {
    if (p.isAbsolute(relative) || relative.contains('\u0000')) return null;
    final path = p.normalize(p.absolute(p.join(root, relative)));
    return p.isWithin(p.normalize(p.absolute(root)), path) ? path : null;
  }

  /// Copies the case's committed trace files into the task directory, so
  /// the same resolution the real path performs finds the same files.
  Future<void> _stageDemoTraces(
    SbyDemoCase manifest,
    String caseDir,
    String taskDirectory,
    StreamController<TestExecutionEvent> controller,
  ) async {
    for (final relative in manifest.traces) {
      final fromPath = FormalContainment.containedPath(caseDir, relative);
      final toPath = _lexicallyContained(taskDirectory, relative);
      if (fromPath == null || toPath == null) continue;
      final from = File(fromPath);
      if (!from.existsSync()) continue;
      try {
        final to = File(toPath);
        await to.parent.create(recursive: true);
        await to.writeAsBytes(await from.readAsBytes());
      } on FileSystemException catch (e) {
        controller.add(
          TestLogLine(
            line: '$logTag: could not stage demo trace $relative: $e',
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

/// A demo case's `case.json`.
@immutable
class SbyDemoCase {
  /// Creates a manifest.
  const SbyDemoCase({
    required this.log,
    this.traces = const <String>[],
    this.exitCode = 0,
    this.proofMode,
    this.depth,
    this.statusDb,
  });

  /// The captured log, relative to the case.
  final String log;

  /// Trace files to stage into the task directory.
  final List<String> traces;

  /// The exit code the captured run reported.
  final int exitCode;

  /// The proof mode the run was configured with.
  final String? proofMode;

  /// The bound the run was configured with.
  final int? depth;

  /// A captured `status.sqlite`, relative to the case.
  final String? statusDb;
}
