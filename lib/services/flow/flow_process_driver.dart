// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:crux_flow/crux_flow.dart';
import 'package:crux_io/crux_io.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/kill_signal.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/flow_config.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/flow/flow_metric_keys.dart';
import 'package:simcrux/services/flow/flow_run_reading.dart';
import 'package:simcrux/services/formal/formal_containment.dart';
import 'package:simcrux/services/job_scheduler/process_reaper.dart';
import 'package:simcrux/services/simulator/process_backed_simulator_driver.dart';

/// How one flow tool spawn ended.
@immutable
class FlowSpawnOutcome {
  /// Creates the outcome.
  const FlowSpawnOutcome({this.exitCode, this.killSignal, this.notFound});

  /// The exit code, or null when the tool never started.
  final int? exitCode;

  /// The signal the reaper delivered, when a cancel or timeout ended it.
  final KillSignal? killSignal;

  /// Why the tool could not be started, when it could not.
  final ProcessException? notFound;
}

/// The extra metric keys a flow result carries beside [FlowMetricKeys].
abstract final class FlowDriverMetricKeys {
  /// The closed tool token a run could not start (`nextpnr`, `yosys`,
  /// `librelane`, `nix`, `docker`, `fusesoc`), for `flow.tool.missing`.
  static const String toolMissing = 'flow.tool_missing';
}

/// The shared base of the two flow drivers: the run tag and run directory,
/// the spawn that reports a missing tool as a verdict rather than an error,
/// `XDG_DATA_HOME`, and the terminal event that carries the verdict.
///
/// Process-tree reaping, SIGTERM then SIGKILL and cancel come from
/// [ProcessBackedSimulatorDriver]; nothing here deletes a file.
abstract class FlowProcessDriver extends ProcessBackedSimulatorDriver {
  /// Creates the driver. [clock] stamps run tags; tests pass a fixed one.
  FlowProcessDriver({
    super.launcher,
    super.reaper,
    super.killGrace,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

  /// The clock run tags are stamped from.
  @protected
  final DateTime Function() clock;

  /// Flow runs read their sources from their own configuration, never
  /// `TestSpec.sources` through the mixed-language check.
  @override
  SimulatorCapabilities get capabilities => SimulatorCapabilities(
    supportedLanguages: const {},
    supportsVcd: false,
    supportsFst: false,
    supportsCocotb: false,
    requiresSeparateCompileStep: requiresCompile,
    emitsStructuredOutput: true,
  );

  /// Whether the scheduler calls [compile] before [execute].
  @protected
  bool get requiresCompile;

  /// The run tag for [prefix] at [now]: `<prefix>-<yyyyMMddTHHmmssZ>`, one
  /// safe path segment.
  static String tagFor(String prefix, DateTime now) {
    final t = now.toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp =
        '${t.year.toString().padLeft(4, '0')}${two(t.month)}${two(t.day)}'
        'T${two(t.hour)}${two(t.minute)}${two(t.second)}Z';
    return '$prefix-$stamp';
  }

  /// A tag under [runsDir] no run uses yet, so nothing an earlier run wrote
  /// is ever reused or overwritten: [tagFor] at [now], then `-2`, `-3`, ...
  /// Returns null when [prefix] is not one safe segment.
  static String? freshTag(String runsDir, String prefix, DateTime now) {
    final base = tagFor(prefix, now);
    if (FormalContainment.segmentProblem(base) != null) return null;
    var tag = base;
    for (var n = 2; n < 1000; n++) {
      final type = FileSystemEntity.typeSync(
        p.join(runsDir, tag),
        followLinks: false,
      );
      if (type == FileSystemEntityType.notFound) return tag;
      tag = '$base-$n';
    }
    return null;
  }

  /// The environment a flow tool runs under: [base], with `XDG_DATA_HOME`
  /// set to a directory inside the test's own work directory when neither
  /// [base] nor this process sets one (nextpnr needs it, measured).
  static Map<String, String> flowEnvironment(
    String workingDirectory,
    Map<String, String> base, {
    Map<String, String>? hostEnvironment,
  }) {
    final env = <String, String>{...base};
    final host = hostEnvironment ?? Platform.environment;
    if (!env.containsKey('XDG_DATA_HOME') &&
        (host['XDG_DATA_HOME'] ?? '').isEmpty) {
      final xdg = p.join(workingDirectory, 'xdg');
      try {
        Directory(xdg).createSync(recursive: true);
      } on FileSystemException {
        // The tool reports its own failure if it needs the directory.
      }
      env['XDG_DATA_HOME'] = xdg;
    }
    return env;
  }

  /// Spawns [executable] for [request], streaming its lines to
  /// [controller], and returns how it ended. A tool that cannot be started
  /// comes back as [FlowSpawnOutcome.notFound], never as a stream error, so
  /// the caller still ends the run with a verdict.
  @protected
  Future<FlowSpawnOutcome> spawnTool({
    required ExecuteRequest request,
    required String executable,
    required List<String> args,
    required StreamController<TestExecutionEvent> controller,
    Map<String, String>? environment,
    String? workingDirectory,
    void Function(String line)? onLine,
  }) async {
    final ReapableProcess process;
    try {
      process = await reaper.spawnGrouped(
        executable,
        args,
        environment: augmentEnvironment(environment),
        workingDirectory: workingDirectory ?? request.workingDirectory,
      );
    } on ProcessException catch (e) {
      return FlowSpawnOutcome(notFound: e);
    }
    trackProcess(request.test.id, process);
    void emit(String line, {required bool fromStderr}) {
      onLine?.call(line);
      if (controller.isClosed) return;
      controller.add(
        TestLogLine(
          line: line,
          fromStderr: fromStderr,
          timestamp: DateTime.now().toUtc(),
        ),
      );
    }

    final drains = <ProcessStreamDrain<String>>[
      ProcessStreamDrain<String>(
        process.stdout,
        (line) => emit(line, fromStderr: false),
      ),
      ProcessStreamDrain<String>(
        process.stderr,
        (line) => emit(line, fromStderr: true),
      ),
    ];
    int exitCode;
    try {
      try {
        exitCode = await process.exitCode;
      } on Object {
        for (final drain in drains) {
          await drain.cancel();
        }
        rethrow;
      }
      try {
        await drainProcessOutput(
          exitCode: exitCode,
          drains: drains,
          terminatedByCaller: () => process.killSignal != null,
        );
      } on ProcessOutputIncompleteException catch (e) {
        emit('$executable: ${e.message}', fromStderr: true);
      }
    } finally {
      untrackProcess(request.test.id);
    }
    return FlowSpawnOutcome(
      exitCode: exitCode,
      killSignal: process.killSignal,
    );
  }

  /// The terminal event for [reading]: `pass` when the verdict is `met`,
  /// `fail` for every other verdict, the verdict and the run in the
  /// metrics. The exit code is recorded and never decides.
  @protected
  TestExecutionFinished finishedFor(
    FlowReading reading, {
    required DateTime startedAt,
    int? exitCode,
    KillSignal? killSignal,
    String? toolMissing,
    String? message,
  }) {
    final verdict = reading.verdict;
    return TestExecutionFinished(
      status: verdict == FlowVerdict.met ? TestStatus.pass : TestStatus.fail,
      exitCode: exitCode,
      startedAt: startedAt,
      finishedAt: DateTime.now().toUtc(),
      killSignal: killSignal,
      failureMessage: verdict == FlowVerdict.met
          ? null
          : message ?? describeVerdict(reading),
      metrics: <String, String>{
        ...reading.toMetrics(exitCode: exitCode),
        FlowDriverMetricKeys.toolMissing: ?toolMissing,
      },
    );
  }

  /// One line saying what [reading]'s verdict means. Results are findings,
  /// not signoff.
  static String describeVerdict(FlowReading reading) {
    final problem = reading.problem;
    final detail = problem == null ? '' : ' ($problem)';
    return switch (reading.verdict) {
      FlowVerdict.met => 'Flow verdict: met.',
      FlowVerdict.violated =>
        'Flow verdict: violated. The run completed and reports violations; '
            'these are findings, not signoff.',
      FlowVerdict.stopped =>
        'Flow verdict: stopped'
            '${reading.stoppedStep == null ? '' : ' at ${reading.stoppedStep}'}'
            '$detail.',
      FlowVerdict.notRun => 'Flow verdict: not run$detail.',
      FlowVerdict.unrecognised =>
        'Flow verdict: unrecognised; the run could not be read$detail.',
    };
  }

  /// Ends the run before anything is spawned, with [verdict] (normally
  /// `notRun`) and [problem] as the reason.
  @protected
  Future<void> failBeforeRunning(
    StreamController<TestExecutionEvent> controller, {
    required DateTime startedAt,
    required FlowKind kind,
    required String root,
    required String tag,
    required String problem,
    String? toolMissing,
    String target = 'other',
  }) async {
    final reading = FlowReading(
      run: FlowRun(
        ref: FlowRunRef(
          kind: kind,
          root: root,
          tag: tag,
          readerVersion: 'none',
          verified: false,
        ),
        verdict: FlowVerdict.notRun,
      ),
      reader: kind == FlowKind.librelane
          ? FlowReaderIds.librelane
          : FlowReaderIds.nextpnrReport,
      problem: problem,
      target: target,
    );
    controller.add(
      finishedFor(
        reading,
        startedAt: startedAt,
        toolMissing: toolMissing,
        message: problem,
      ),
    );
    await controller.close();
  }

  /// The entry [test] runs, when it is one of [kind].
  @protected
  FlowEntry? entryOf(TestSpec test, FlowKind kind) {
    final entry = test.flow;
    return entry != null && entry.kind == kind ? entry : null;
  }

  /// [config]'s executable for [defaultBinary]: a Settings path that names
  /// a directory holds it, a path that names a file is it.
  @protected
  String flowBinary(SimulatorBinaryConfig config, String defaultBinary) {
    final custom = config.customPath;
    if (config.source == SimulatorBinarySource.custom &&
        custom != null &&
        custom.isNotEmpty &&
        Directory(custom).existsSync()) {
      return p.join(custom, _exe(defaultBinary));
    }
    return resolveBinary(config, defaultBinary);
  }

  /// A sibling tool beside [binary] when [binary] is a path and the sibling
  /// exists there (an OSS CAD Suite keeps them in one `bin/`), else [name].
  @protected
  String sibling(String binary, String name) {
    if (!p.isAbsolute(binary)) return name;
    final beside = p.join(p.dirname(binary), _exe(name));
    return File(beside).existsSync() ? beside : name;
  }

  static String _exe(String name) => Platform.isWindows ? '$name.exe' : name;
}
