// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:crux_flow/crux_flow.dart';
import 'package:crux_yosys/crux_yosys.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/flow_config.dart';
import 'package:simcrux/domain/models/flow_tool_settings.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/services/flow/flow_process_driver.dart';
import 'package:simcrux/services/flow/flow_run_reading.dart';

/// What [NextpnrFlowDriver.compile] left for [NextpnrFlowDriver.execute]:
/// the run directory and how synthesis went.
@immutable
class NextpnrJob {
  /// Creates the job.
  const NextpnrJob({
    required this.runDir,
    required this.tag,
    this.problem,
    this.toolMissing,
    this.stoppedAt,
  });

  /// The run directory: `<project>/runs/<entry>/<tag>/`, created by
  /// SimCrux, never reused.
  final String runDir;

  /// The run tag.
  final String tag;

  /// Why the run cannot go on, when it cannot.
  final String? problem;

  /// The tool token that was missing, when that is the problem.
  final String? toolMissing;

  /// The step the run stopped at (`synthesis`), when it stopped.
  final String? stoppedAt;

  /// The synthesised netlist (`synth.json`).
  String get netlist => p.join(runDir, 'synth.json');

  /// nextpnr's `--report`.
  String get report => p.join(runDir, 'report.json');

  /// nextpnr's `--write`, the placed and routed netlist.
  String get post => p.join(runDir, 'post.json');

  /// nextpnr's `--log`.
  String get log => p.join(runDir, 'pnr.log');
}

/// Runs a nextpnr entry: synthesis, then place and route.
///
/// - **compile** is synthesis: `synth_<family> -top <top>` through
///   `crux_yosys`'s [YosysRunner], the netlist written to the run
///   directory's `synth.json`;
/// - **execute** is `nextpnr-ARCH ... --json synth.json --report report.json
///   [--detailed-timing-report] --write post.json --log pnr.log`, from the
///   run directory.
///
/// A FuseSoC entry instead runs `fusesoc run --target=<t> <core>` with its
/// build root in the run directory and reads the report, or, when Edalize
/// did not pass `--report`, nextpnr's log ([NextpnrRunReader]).
///
/// **The verdict is the report's, never the exit code.** nextpnr exits 1 on
/// a timing FAIL and still writes the report, which makes the run
/// `violated`; an exit of 0 with no report is `notRun`. A synthesis that
/// failed is `stopped` at `synthesis`; a tool that could not be started is
/// `notRun`, with the tool named for `flow.tool.missing`.
///
/// The run directory is `<project>/runs/<entry>/<tag>/`: a fresh tag every
/// run, created inside the project (symlinks resolved), so a run never
/// overwrites another and nothing is deleted. `XDG_DATA_HOME` is set to the
/// test's own work directory when the environment has none.
///
/// **Never gated.** A flow verdict is correctness and is free.
class NextpnrFlowDriver extends FlowProcessDriver {
  /// Creates the driver. [yosysRunnerFor] builds the synthesis runner for a
  /// Yosys executable; tests pass a scripted one.
  NextpnrFlowDriver({
    super.launcher,
    super.reaper,
    super.killGrace,
    super.clock,
    YosysRunner Function(String executable)? yosysRunnerFor,
    this.reader = const NextpnrRunReader(),
  }) : _yosysRunnerFor =
           yosysRunnerFor ?? ((exe) => YosysRunner(executable: exe));

  /// The `simulatorId` this driver claims.
  static const String kId = 'nextpnr';

  final YosysRunner Function(String executable) _yosysRunnerFor;

  /// Reads the finished run.
  final NextpnrRunReader reader;

  final Map<String, NextpnrJob> _jobs = <String, NextpnrJob>{};
  final Map<String, Completer<void>> _synthesisCancels =
      <String, Completer<void>>{};

  @override
  String get id => kId;

  @override
  String get displayName => 'nextpnr';

  @override
  bool get requiresCompile => true;

  /// One `nextpnr-ice40 --version`: a short-lived spawn of one binary.
  @override
  Future<String?> detectVersion(SimulatorBinaryConfig config) =>
      detectVersionOf(flowBinary(config, NextpnrFamily.ice40.binary));

  @override
  void cancel(String testId) {
    final synthesis = _synthesisCancels.remove(testId);
    if (synthesis != null && !synthesis.isCompleted) synthesis.complete();
    super.cancel(testId);
  }

  /// The run directory and tag for [entry], created, or a job carrying the
  /// reason it could not be.
  @visibleForTesting
  NextpnrJob prepareRun(FlowEntry entry) {
    final root = entry.projectRoot;
    if (root == null) {
      return const NextpnrJob(
        runDir: '',
        tag: '',
        problem: 'the entry has no project directory',
      );
    }
    final containment = FlowContainment(<String>[root]);
    try {
      final runs = containment.require(p.join(root, 'runs', entry.name));
      final tag = FlowProcessDriver.freshTag(runs, entry.tagPrefix, clock());
      if (tag == null) {
        return const NextpnrJob(
          runDir: '',
          tag: '',
          problem: 'no free run tag could be made',
        );
      }
      final runDir = containment.require(p.join(runs, tag));
      Directory(runDir).createSync(recursive: true);
      // Judged again once it exists: a link planted on the way is refused.
      return NextpnrJob(runDir: containment.require(runDir), tag: tag);
    } on FlowContainmentException catch (e) {
      return NextpnrJob(
        runDir: '',
        tag: '',
        problem: 'the run directory: ${e.reason}',
      );
    } on FileSystemException catch (e) {
      return NextpnrJob(
        runDir: '',
        tag: '',
        problem: 'the run directory could not be created: ${e.message}',
      );
    }
  }

  /// The Yosys statement that synthesises [entry] for its family.
  static String synthCommand(FlowEntry entry) {
    final top = entry.top!;
    return switch (entry.family!) {
      NextpnrFamily.ice40 => 'synth_ice40 -top $top',
      NextpnrFamily.ecp5 => 'synth_ecp5 -top $top',
      NextpnrFamily.gowin => 'synth_gowin -top $top',
      // `-luttree`: the GateMate flow nextpnr-himbaechel places (measured).
      NextpnrFamily.gatemate => 'synth_gatemate -top $top -luttree',
    };
  }

  /// nextpnr's arguments for [entry] and [job].
  static List<String> nextpnrArgs(FlowEntry entry, NextpnrJob job) {
    final family = entry.family!;
    final device = entry.device!;
    final package = entry.package;
    final constraints = entry.constraints;
    final freq = entry.freqMhz;
    return <String>[
      ...switch (family) {
        NextpnrFamily.ice40 => <String>[
          '--$device',
          if (package != null) ...['--package', package],
          if (constraints != null) ...['--pcf', constraints],
        ],
        NextpnrFamily.ecp5 => <String>[
          '--$device',
          if (package != null) ...['--package', package],
          if (constraints != null) ...['--lpf', constraints],
        ],
        NextpnrFamily.gowin => <String>[
          '--device',
          device,
          if (constraints != null) ...['--vopt', 'cst=$constraints'],
        ],
        NextpnrFamily.gatemate => <String>[
          '--device',
          device,
          if (constraints != null) ...['--vopt', 'ccf=$constraints'],
        ],
      },
      '--json',
      job.netlist,
      if (freq != null) ...['--freq', _number(freq)],
      '--report',
      job.report,
      if (entry.detailedTiming) '--detailed-timing-report',
      '--write',
      job.post,
      '--log',
      job.log,
      ...entry.extraArgs,
    ];
  }

  static String _number(double value) =>
      value == value.roundToDouble() ? '${value.toInt()}' : '$value';

  static YosysSourceFile _source(String path) {
    final ext = p.extension(path).toLowerCase();
    if (ext == '.vhd' || ext == '.vhdl') return YosysSourceFile.vhdl(path);
    if (ext == '.sv') return YosysSourceFile.systemVerilog(path);
    return YosysSourceFile(path);
  }

  /// Synthesis. Never fails the compile stage: whatever happens is carried
  /// to [execute], which ends the run with a verdict.
  @override
  Future<CompileResult> compile(CompileRequest request) async {
    const ok = CompileResult(
      success: true,
      artifactPath: null,
      stdout: '',
      stderr: '',
    );
    final entry = entryOf(request.test, FlowKind.nextpnr);
    if (entry == null) {
      return const CompileResult(
        success: false,
        artifactPath: null,
        stdout: '',
        stderr: 'nextpnr: this test has no nextpnr flow entry.',
      );
    }
    final job = prepareRun(entry);
    _jobs[request.test.id] = job;
    if (job.problem != null || entry.isFusesoc) return ok;

    final nextpnr = flowBinary(request.binaryConfig, entry.family!.binary);
    final yosys = sibling(nextpnr, 'yosys');
    final cancel = Completer<void>();
    _synthesisCancels[request.test.id] = cancel;
    final YosysRunResult result;
    try {
      result = await _yosysRunnerFor(yosys).run(
        YosysRunRequest(
          sources: entry.sources.map(_source).toList(growable: false),
          topModule: entry.top,
          extraCommands: <String>[synthCommand(entry)],
        ),
        cancelSignal: cancel.future,
        onStderrLine: request.stderrCapture?.addLine,
      );
    } finally {
      _synthesisCancels.remove(request.test.id);
    }
    request.stdoutCapture?.addBlob(result.stdout);
    switch (result) {
      case YosysRunSuccess(:final rawJson):
        try {
          File(job.netlist).writeAsStringSync(rawJson);
        } on FileSystemException catch (e) {
          _jobs[request.test.id] = NextpnrJob(
            runDir: job.runDir,
            tag: job.tag,
            problem: 'the netlist could not be written: ${e.message}',
            stoppedAt: 'synthesis',
          );
        }
      case YosysRunFailure(:final kind, :final stderr):
        request.stderrCapture?.addBlob(stderr);
        _jobs[request.test.id] = NextpnrJob(
          runDir: job.runDir,
          tag: job.tag,
          problem: kind == YosysFailureKind.launch
              ? 'Yosys (`$yosys`) was not found. Set the nextpnr path in '
                    'Settings > Engines to the directory holding nextpnr and '
                    'yosys (an OSS CAD Suite bin/), or put it on PATH.'
              : 'synthesis failed: ${_firstLine(stderr)}',
          toolMissing: kind == YosysFailureKind.launch ? 'yosys' : null,
          stoppedAt: kind == YosysFailureKind.launch ? null : 'synthesis',
        );
      case YosysRunTimeout() || YosysRunCancelled():
        _jobs[request.test.id] = NextpnrJob(
          runDir: job.runDir,
          tag: job.tag,
          problem: 'synthesis was stopped',
          stoppedAt: 'synthesis',
        );
    }
    return ok;
  }

  static String _firstLine(String text) {
    for (final line in text.split('\n')) {
      final t = line.trim();
      if (t.isNotEmpty) return t.length > 300 ? '${t.substring(0, 300)}...' : t;
    }
    return 'Yosys printed nothing';
  }

  @override
  Future<void> runExecute(
    ExecuteRequest request,
    StreamController<TestExecutionEvent> controller,
  ) async {
    final startedAt = DateTime.now().toUtc();
    final entry = entryOf(request.test, FlowKind.nextpnr);
    if (entry == null) {
      await failBeforeRunning(
        controller,
        startedAt: startedAt,
        kind: FlowKind.nextpnr,
        root: '',
        tag: '',
        problem: 'this test has no nextpnr flow entry',
      );
      return;
    }
    final job = _jobs.remove(request.test.id) ?? prepareRun(entry);
    final target = entry.family?.wireName ?? 'other';
    if (job.problem != null) {
      if (job.stoppedAt != null) {
        controller.add(
          finishedFor(
            FlowReading(
              run: FlowRun(
                ref: FlowRunRef(
                  kind: FlowKind.nextpnr,
                  root: job.runDir,
                  tag: job.tag,
                  readerVersion: 'none',
                  verified: false,
                ),
                verdict: FlowVerdict.stopped,
              ),
              reader: 'nextpnr_report',
              problem: job.problem,
              stoppedStep: job.stoppedAt,
              target: target,
            ),
            startedAt: startedAt,
          ),
        );
        await controller.close();
        return;
      }
      await failBeforeRunning(
        controller,
        startedAt: startedAt,
        kind: FlowKind.nextpnr,
        root: job.runDir,
        tag: job.tag,
        problem: job.problem!,
        toolMissing: job.toolMissing,
        target: target,
      );
      return;
    }

    if (entry.isFusesoc) {
      await _runFusesoc(request, controller, entry, job, startedAt);
      return;
    }

    final binary = flowBinary(request.binaryConfig, entry.family!.binary);
    final outcome = await spawnTool(
      request: request,
      executable: binary,
      args: nextpnrArgs(entry, job),
      controller: controller,
      environment: FlowProcessDriver.flowEnvironment(
        request.workingDirectory,
        request.binaryConfig.extraEnv,
      ),
      workingDirectory: job.runDir,
    );
    if (outcome.notFound != null) {
      await failBeforeRunning(
        controller,
        startedAt: startedAt,
        kind: FlowKind.nextpnr,
        root: job.runDir,
        tag: job.tag,
        problem:
            '`$binary` was not found. Set the nextpnr path in Settings > '
            'Engines, or put the directory holding nextpnr on PATH.',
        toolMissing: 'nextpnr',
        target: target,
      );
      return;
    }
    final reading = await reader.readRunDir(
      job.runDir,
      tag: job.tag,
      family: entry.family,
    );
    controller.add(
      finishedFor(
        reading,
        startedAt: startedAt,
        exitCode: outcome.exitCode,
        killSignal: outcome.killSignal,
      ),
    );
    await controller.close();
  }

  /// `fusesoc run --target=<t> <core>`, spawned from the project directory
  /// (so its `fusesoc.conf` applies) with `--build-root` in the run
  /// directory.
  Future<void> _runFusesoc(
    ExecuteRequest request,
    StreamController<TestExecutionEvent> controller,
    FlowEntry entry,
    NextpnrJob job,
    DateTime startedAt,
  ) async {
    final fusesoc = entry.fusesoc!;
    final settings = FlowToolSettings.fromOptions(request.binaryConfig.options);
    final binary =
        fusesoc.binary ??
        (settings.fusesocPath.isEmpty ? 'fusesoc' : settings.fusesocPath);
    final outcome = await spawnTool(
      request: request,
      executable: binary,
      args: <String>[
        'run',
        '--build-root',
        job.runDir,
        '--target=${fusesoc.target}',
        fusesoc.core,
      ],
      controller: controller,
      environment: FlowProcessDriver.flowEnvironment(
        request.workingDirectory,
        request.binaryConfig.extraEnv,
      ),
      workingDirectory: entry.projectRoot,
    );
    if (outcome.notFound != null) {
      await failBeforeRunning(
        controller,
        startedAt: startedAt,
        kind: FlowKind.nextpnr,
        root: job.runDir,
        tag: job.tag,
        problem:
            'FuseSoC (`$binary`) was not found. Set its path in Settings > '
            'Engines, or put it on PATH.',
        toolMissing: 'fusesoc',
      );
      return;
    }
    final reading = await _readFusesocBuild(job);
    controller.add(
      finishedFor(
        reading,
        startedAt: startedAt,
        exitCode: outcome.exitCode,
        killSignal: outcome.killSignal,
      ),
    );
    await controller.close();
  }

  /// The report or nextpnr log Edalize left under the run directory: the
  /// shallowest `report.json`, else the shallowest `next.log`.
  Future<FlowReading> _readFusesocBuild(NextpnrJob job) async {
    String? report;
    String? log;
    var reportDepth = 1 << 30;
    var logDepth = 1 << 30;
    try {
      await for (final entity in Directory(
        job.runDir,
      ).list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final rel = p.relative(entity.path, from: job.runDir);
        final depth = p.split(rel).length;
        if (depth > 6) continue;
        final name = p.basename(entity.path);
        if (name == 'report.json' && depth < reportDepth) {
          report = entity.path;
          reportDepth = depth;
        } else if (name == 'next.log' && depth < logDepth) {
          log = entity.path;
          logDepth = depth;
        }
      }
    } on FileSystemException {
      // Read below as not run.
    }
    final containment = FlowContainment(<String>[job.runDir]);
    if (report != null) {
      return await reader.readReport(
        report,
        root: job.runDir,
        tag: job.tag,
        containment: containment,
      );
    }
    if (log != null) {
      return await reader.readLog(
        log,
        root: job.runDir,
        tag: job.tag,
        containment: containment,
      );
    }
    return await reader.readRunDir(
      job.runDir,
      tag: job.tag,
      logFallback: true,
    );
  }
}
