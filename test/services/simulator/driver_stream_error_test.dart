// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/job_scheduler/local_job_scheduler.dart';
import 'package:simcrux/services/simulator/icarus_driver.dart';

/// A process whose stdout stream emits an error and then never closes —
/// e.g. a decoder failure on a simulator that wrote a malformed byte
/// sequence, or a pipe that faulted mid-run.
///
/// Without an `onError` handler on the driver's `listen`, the drain
/// future gated on `onDone` is never released and `execute` hangs until
/// the scheduler's per-test timeout fires — turning an instant, clearly
/// diagnosable failure into a full-timeout stall per affected test.
class _ErroringStreamProcess implements TestProcess {
  _ErroringStreamProcess({this.exit = 0, this.errorOnStderr = false});

  final int exit;
  final bool errorOnStderr;
  bool killed = false;

  Stream<String> _erroring() => Stream<String>.multi((controller) {
    controller
      ..add('simulation starting')
      ..addError(const FormatException('malformed byte sequence'));
    // Never closed — the error is the only terminal signal.
  });

  @override
  Stream<String> get stdout =>
      errorOnStderr ? const Stream<String>.empty() : _erroring();

  @override
  Stream<String> get stderr =>
      errorOnStderr ? _erroring() : const Stream<String>.empty();

  @override
  Future<int> get exitCode async => exit;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    return true;
  }
}

Future<TestProcess> Function(
  String,
  List<String>, {
  Map<String, String>? environment,
  String? workingDirectory,
})
_launcherFor(TestProcess Function() build) {
  return (
    String executable,
    List<String> args, {
    Map<String, String>? environment,
    String? workingDirectory,
  }) async => build();
}

TestSpec _spec() => TestSpec(
  id: 'unit/dut',
  name: 'dut',
  suiteName: 'unit',
  simulatorId: 'icarus',
  top: 'tb',
);

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('simcrux_stream_err');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  ExecuteRequest request(Directory dir) => ExecuteRequest(
    test: _spec(),
    workingDirectory: dir.path,
    compileResult: const CompileResult(
      success: true,
      artifactPath: 'sim.vvp',
      stdout: '',
      stderr: '',
    ),
    binaryConfig: const SimulatorBinaryConfig(simulatorId: 'icarus'),
  );

  group('process-backed driver — log stream errors', () {
    test('a stdout stream error still reaches a terminal event', () async {
      final driver = IcarusDriver(
        launcher: _launcherFor(_ErroringStreamProcess.new),
      );

      final events = await driver
          .execute(request(tmp))
          .toList()
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () => fail(
              'the driver hung on a stdout stream error — the drain '
              'future was never released',
            ),
          );

      expect(
        events.whereType<TestExecutionFinished>(),
        hasLength(1),
        reason: 'the run must terminate rather than stall until timeout',
      );
    });

    test('a stderr stream error still reaches a terminal event', () async {
      final driver = IcarusDriver(
        launcher: _launcherFor(
          () => _ErroringStreamProcess(errorOnStderr: true),
        ),
      );

      final events = await driver
          .execute(request(tmp))
          .toList()
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () => fail('the driver hung on a stderr stream error'),
          );

      expect(events.whereType<TestExecutionFinished>(), hasLength(1));
    });
  });
}
