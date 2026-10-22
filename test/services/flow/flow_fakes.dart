// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:crux_yosys/crux_yosys.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/services/job_scheduler/local_job_scheduler.dart';
import 'package:simcrux/services/job_scheduler/process_reaper.dart';

/// A scripted process: lines, then an exit code (or never, until killed).
class FakeFlowProcess implements TestProcess {
  /// Creates the process.
  FakeFlowProcess({
    this.stdoutLines = const <String>[],
    this.stderrLines = const <String>[],
    this.exit = 0,
    this.hang = false,
  });

  /// Lines on stdout.
  final List<String> stdoutLines;

  /// Lines on stderr.
  final List<String> stderrLines;

  /// The exit code.
  final int exit;

  /// Whether the process runs until killed.
  final bool hang;

  final Completer<int> _killed = Completer<int>();

  /// Signals the process received.
  final List<ProcessSignal> signals = <ProcessSignal>[];

  @override
  Stream<String> get stdout => Stream<String>.fromIterable(stdoutLines);

  @override
  Stream<String> get stderr => Stream<String>.fromIterable(stderrLines);

  @override
  Future<int> get exitCode => hang ? _killed.future : Future<int>.value(exit);

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    signals.add(signal);
    if (!_killed.isCompleted) _killed.complete(-15);
    return true;
  }
}

/// One recorded spawn.
typedef FlowSpawn = ({
  String executable,
  List<String> args,
  Map<String, String>? environment,
  String? cwd,
});

/// A launcher that records every spawn and plays the tool through [onSpawn].
class FlowSpawnRecorder {
  /// Creates the recorder. [missing] names executables that "do not exist".
  FlowSpawnRecorder({
    this.onSpawn,
    this.missing = const <String>{},
  });

  /// Plays the tool: writes what it would leave, returns its process.
  final FakeFlowProcess Function(FlowSpawn spawn)? onSpawn;

  /// Executables whose spawn throws as a missing binary does.
  final Set<String> missing;

  /// Every spawn, in order.
  final List<FlowSpawn> spawns = <FlowSpawn>[];

  /// The launcher to inject.
  Future<TestProcess> launch(
    String executable,
    List<String> args, {
    Map<String, String>? environment,
    String? workingDirectory,
  }) async {
    final spawn = (
      executable: executable,
      args: args,
      environment: environment,
      cwd: workingDirectory,
    );
    spawns.add(spawn);
    if (missing.any((m) => executable.endsWith(m))) {
      throw ProcessException(executable, args, 'No such file or directory', 2);
    }
    return onSpawn?.call(spawn) ?? FakeFlowProcess();
  }
}

/// A reaper that records every tree it is asked to terminate.
class RecordingReaper extends NoopProcessReaper {
  /// Creates the reaper over [launch].
  RecordingReaper(ProcessLauncher launch) : super(launcher: launch);

  /// Every handle terminated.
  final List<ReapableProcess> terminated = <ReapableProcess>[];

  @override
  Future<void> terminateTree(
    ReapableProcess handle, {
    Duration grace = const Duration(seconds: 5),
  }) {
    terminated.add(handle);
    return super.terminateTree(handle, grace: grace);
  }
}

/// A Yosys runner that answers with [result] and records requests.
class FakeYosysRunner extends YosysRunner {
  /// Creates the runner.
  FakeYosysRunner(this.result, {this.hangUntilCancelled = false});

  /// What every run returns.
  final YosysRunResult result;

  /// Whether a run waits for its cancel signal.
  final bool hangUntilCancelled;

  /// Every request.
  final List<YosysRunRequest> requests = <YosysRunRequest>[];

  @override
  Future<YosysRunResult> run(
    YosysRunRequest request, {
    Duration? timeout,
    Future<void>? cancelSignal,
    void Function(String line)? onStderrLine,
  }) async {
    requests.add(request);
    if (hangUntilCancelled) {
      await cancelSignal;
      return const YosysRunCancelled(stdout: '', stderr: '');
    }
    return result;
  }
}

/// Collects a driver's events to the terminal one.
Future<TestExecutionFinished> finishedOf(
  Stream<TestExecutionEvent> events,
) async {
  TestExecutionFinished? finished;
  await for (final event in events) {
    if (event is TestExecutionFinished) finished = event;
  }
  return finished!;
}
