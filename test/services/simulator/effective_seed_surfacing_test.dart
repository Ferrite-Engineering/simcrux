// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/job_scheduler/local_job_scheduler.dart';
import 'package:simcrux/services/simulator/ghdl_driver.dart';
import 'package:simcrux/services/simulator/icarus_driver.dart';
import 'package:simcrux/services/simulator/verilator_driver.dart';

/// Determinism. Every driver must surface the seed it **actually ran
/// with** on `TestExecutionFinished.effectiveSeed`: the requested seed when
/// pinned, or the clock-derived value when none was — so the run is
/// reproducible and a flaky retry can replay it.
class _FakeProcess implements TestProcess {
  @override
  Stream<String> get stdout => const Stream<String>.empty();
  @override
  Stream<String> get stderr => const Stream<String>.empty();
  @override
  Future<int> get exitCode async => 0;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}

class _Recorder {
  final List<List<String>> argLists = <List<String>>[];
  final List<Map<String, String>?> envs = <Map<String, String>?>[];

  Future<TestProcess> launch(
    String executable,
    List<String> args, {
    Map<String, String>? environment,
    String? workingDirectory,
  }) async {
    argLists.add(List<String>.unmodifiable(args));
    envs.add(environment);
    return _FakeProcess();
  }
}

TestSpec _spec({int? seed}) => TestSpec(
  id: 'unit/tb',
  name: 'tb',
  suiteName: 'unit',
  simulatorId: 'sim',
  top: 'tb',
  seed: seed,
);

const _cfg = SimulatorBinaryConfig(simulatorId: 'sim');

Future<TestExecutionFinished> _run(
  SimulatorDriver driver,
  TestSpec spec,
) async {
  final events = await driver
      .execute(
        ExecuteRequest(
          test: spec,
          workingDirectory: '/wd',
          compileResult: const CompileResult(
            success: true,
            artifactPath: '/wd/artifact',
            stdout: '',
            stderr: '',
          ),
          binaryConfig: _cfg,
        ),
      )
      .toList();
  return events.whereType<TestExecutionFinished>().single;
}

void main() {
  group('IcarusDriver surfaces + injects the effective seed', () {
    test('requested seed is reported and passed as +seed=', () async {
      final rec = _Recorder();
      final driver = IcarusDriver(launcher: rec.launch);
      final finished = await _run(driver, _spec(seed: 42));
      expect(finished.effectiveSeed, 42);
      expect(rec.argLists.single, contains('+seed=42'));
    });

    test('no requested seed ⇒ a derived seed is surfaced + injected', () async {
      final rec = _Recorder();
      final driver = IcarusDriver(launcher: rec.launch);
      final finished = await _run(driver, _spec());
      expect(finished.effectiveSeed, isNotNull);
      expect(rec.argLists.single, contains('+seed=${finished.effectiveSeed}'));
    });
  });

  group('VerilatorDriver surfaces + injects the effective seed', () {
    test('requested seed reported and passed via +verilator+seed+', () async {
      final rec = _Recorder();
      final driver = VerilatorDriver(launcher: rec.launch);
      final finished = await _run(driver, _spec(seed: 7));
      expect(finished.effectiveSeed, 7);
      expect(rec.argLists.single, contains('+verilator+seed+7'));
    });

    test('derived seed surfaced when none requested', () async {
      final rec = _Recorder();
      final driver = VerilatorDriver(launcher: rec.launch);
      final finished = await _run(driver, _spec());
      expect(finished.effectiveSeed, isNotNull);
    });
  });

  group('GhdlDriver surfaces the effective seed (report-only)', () {
    test('requested seed is reported even without injection', () async {
      final rec = _Recorder();
      final driver = GhdlDriver(launcher: rec.launch);
      final finished = await _run(driver, _spec(seed: 99));
      expect(finished.effectiveSeed, 99);
    });

    test('derived seed is reported when none requested', () async {
      final rec = _Recorder();
      final driver = GhdlDriver(launcher: rec.launch);
      final finished = await _run(driver, _spec());
      expect(finished.effectiveSeed, isNotNull);
    });
  });
}
