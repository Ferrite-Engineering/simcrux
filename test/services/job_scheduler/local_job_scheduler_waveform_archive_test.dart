// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/hdl_language.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/enums/waveform_capture_policy.dart';
import 'package:simcrux/domain/interfaces/job_scheduler.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/regression_request.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/domain/models/waveform_policy.dart';
import 'package:simcrux/services/job_scheduler/local_job_scheduler.dart';
import 'package:simcrux/services/job_scheduler/waveform_archive.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';

/// A passing test's work dir (and its waveform dump) is deleted the moment it
/// finishes, so without the archive "Debug in WaveCrux" would hand off a path
/// into an already-deleted temp directory. The scheduler must relocate a
/// passing dump into the durable archive and record the archived path, while
/// leaving a failing test's in-place (its work dir is retained).
class _WaveformDriver implements SimulatorDriver {
  _WaveformDriver({required this.exit});

  /// Exit code the fake reports — 0 ⇒ pass, non-zero ⇒ fail.
  final int exit;

  @override
  String get id => 'fake';

  @override
  String get displayName => 'Fake';

  @override
  SimulatorCapabilities get capabilities => SimulatorCapabilities(
    supportedLanguages: const {HdlLanguage.verilog},
    supportsVcd: true,
    supportsFst: false,
    supportsCocotb: false,
    requiresSeparateCompileStep: false,
    emitsStructuredOutput: false,
  );

  @override
  Future<String?> detectVersion(SimulatorBinaryConfig config) async => 'fake';

  @override
  Future<CompileResult> compile(CompileRequest request) async =>
      const CompileResult(
        success: true,
        artifactPath: 'noop',
        stdout: '',
        stderr: '',
      );

  @override
  Stream<TestExecutionEvent> execute(ExecuteRequest request) async* {
    final started = DateTime.now().toUtc();
    // Write a real dump into the work dir, exactly as a simulator would.
    final dumpPath = p.join(request.workingDirectory, 'dump.vcd');
    File(dumpPath).writeAsStringSync('VCD-BODY');
    yield TestExecutionFinished(
      status: exit == 0 ? TestStatus.pass : TestStatus.fail,
      exitCode: exit,
      startedAt: started,
      finishedAt: DateTime.now().toUtc(),
      waveformPath: dumpPath,
    );
  }

  @override
  void cancel(String testId) {}
}

RegressionConfig _emptyConfig() => RegressionConfig(
  projectFilePath: '/fake/simcrux.yaml',
  schemaVersion: '1',
  suites: const [],
  simulatorBinaries: const {},
);

TestSpec _spec(
  String id, {
  WaveformCapturePolicy capture = WaveformCapturePolicy.onFailure,
}) => TestSpec(
  id: id,
  name: id.split('/').last,
  suiteName: id.split('/').first,
  simulatorId: 'fake',
  top: 'tb',
  timeout: const Duration(seconds: 30),
  waveform: WaveformPolicy(capture: capture),
);

void main() {
  late Directory runRoot;
  late Directory poolRoot;

  setUp(() {
    runRoot = Directory.systemTemp.createTempSync('simcrux_sched_run_');
    poolRoot = Directory.systemTemp.createTempSync('simcrux_sched_pool_');
  });
  tearDown(() {
    for (final d in <Directory>[runRoot, poolRoot]) {
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
  });

  LocalJobScheduler scheduler({required int exit, bool archive = true}) =>
      LocalJobScheduler(
        driverRegistry: SimulatorDriverRegistry({
          'fake': _WaveformDriver(exit: exit),
        }),
        config: _emptyConfig(),
        runRoot: runRoot.path,
        passingWaveformArchive: archive
            ? WaveformArchive(resolveRoot: () async => poolRoot.path)
            : null,
        // Unbounded pool so this test isolates relocation from pruning.
      );

  Future<TestResult> runOne(LocalJobScheduler s, TestSpec spec) async {
    final events = await s
        .submit(RegressionRequest(runId: 'r1', tests: <TestSpec>[spec]))
        .toList();
    return events.whereType<TestFinished>().single.result;
  }

  test(
    'passing test: dump is relocated into the archive; work dir swept',
    () async {
      final result = await runOne(scheduler(exit: 0), _spec('s/a'));

      expect(result.status, TestStatus.pass);
      // Recorded path points at the durable pool, not the transient work dir...
      expect(result.waveformPath, isNotNull);
      final wf = result.waveformPath!;
      expect(p.isWithin(poolRoot.path, wf), isTrue);
      expect(File(wf).existsSync(), isTrue);
      expect(File(wf).readAsStringSync(), 'VCD-BODY');
      // ...and the per-test work dir was deleted with the dump gone from it.
      final workDir = Directory(p.join(runRoot.path, 'runs', 'r1', 's_a'));
      expect(workDir.existsSync(), isFalse);
    },
  );

  group('capture: always', () {
    test('a passing test keeps its dump in its retained work dir', () async {
      final result = await runOne(
        scheduler(exit: 0),
        _spec('s/c', capture: WaveformCapturePolicy.always),
      );
      expect(result.status, TestStatus.pass);
      final wf = result.waveformPath!;
      expect(p.isWithin(runRoot.path, wf), isTrue);
      expect(p.isWithin(poolRoot.path, wf), isFalse);
      expect(File(wf).readAsStringSync(), 'VCD-BODY');
    });

    test(
      'with no archive (the --ci shape) the passing dump survives',
      () async {
        final result = await runOne(
          scheduler(exit: 0, archive: false),
          _spec('s/d', capture: WaveformCapturePolicy.always),
        );
        expect(result.status, TestStatus.pass);
        expect(result.waveformPath, isNotNull);
        expect(File(result.waveformPath!).existsSync(), isTrue);
      },
    );

    test('on_failure with no archive still sweeps a passing dump', () async {
      final result = await runOne(
        scheduler(exit: 0, archive: false),
        _spec('s/e'),
      );
      expect(result.waveformPath, isNull);
      expect(
        Directory(p.join(runRoot.path, 'runs', 'r1', 's_e')).existsSync(),
        isFalse,
      );
    });
  });

  test(
    'failing test: dump stays in the retained work dir (not archived)',
    () async {
      final result = await runOne(scheduler(exit: 1), _spec('s/b'));

      expect(result.status, TestStatus.fail);
      expect(result.waveformPath, isNotNull);
      final wf = result.waveformPath!;
      // Failing test's work dir is retained, so the path stays in the run tree.
      expect(p.isWithin(runRoot.path, wf), isTrue);
      expect(p.isWithin(poolRoot.path, wf), isFalse);
      expect(File(wf).existsSync(), isTrue);
    },
  );
}
