// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_license/crux_license_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/job_scheduler.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/regression_request.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/services/config/config_loader.dart';
import 'package:simcrux/services/job_scheduler/local_job_scheduler.dart';
import 'package:simcrux/services/simulator/eqy_driver.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';

import '../../support/eqy_workdir_fixture.dart';

// The tier law for equivalence results: at Open Core with the beta period
// over and no Pro overrides, every EQY verdict, every partition row and
// every counterexample path is produced exactly as at Pro and Enterprise.
// Nothing here may ever be gated; the partition explorer is a separate Pro
// screen over these same rows.

class _Process implements TestProcess {
  _Process(this.lines, this.exit);

  final List<String> lines;
  final int exit;

  @override
  Stream<String> get stdout => Stream<String>.fromIterable(lines);

  @override
  Stream<String> get stderr => const Stream<String>.empty();

  @override
  Future<int> get exitCode async => exit;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}

/// Plays `eqy` from the corpus: the run is the work directory's name.
Future<TestProcess> _playEqy(
  String executable,
  List<String> args, {
  Map<String, String>? environment,
  String? workingDirectory,
}) async {
  final workDir = args[args.indexOf('-d') + 1];
  final run = p.basename(workDir);
  stageEqyWorkdir(run, workDir);
  return _Process(capturedEqyLog(run), capturedEqyExit(run));
}

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('eqy_ungated_'));
  tearDown(() => root.deleteSync(recursive: true));

  String writeProject() {
    for (final f in Directory(eqyCorpus).listSync().whereType<File>()) {
      if (f.path.endsWith('.eqy') || f.path.endsWith('.v')) {
        f.copySync(p.join(root.path, p.basename(f.path)));
      }
    }
    return (File(p.join(root.path, 'simcrux.yaml'))..writeAsStringSync('''
version: "1"
defaults:
  simulator: eqy
suites:
  eqy:
    tests:
      - { name: alu_pass, top: alu, formal: { eqy_file: alu_pass.eqy } }
      - { name: alu_pass2, top: alu, formal: { eqy_file: alu_pass2.eqy } }
      - { name: alu_fail2, top: alu, formal: { eqy_file: alu_fail2.eqy } }
'''))
        .path;
  }

  Future<Map<String, TestResult>> runAt(
    LicenseTier tier, {
    required bool betaPeriod,
  }) async {
    final config = await ConfigLoader(
      licenseTier: tier,
      betaPeriod: betaPeriod,
    ).load(writeProject());
    final work = Directory(p.join(root.path, 'runs-${tier.name}-$betaPeriod'))
      ..createSync();
    final scheduler = LocalJobScheduler(
      driverRegistry: SimulatorDriverRegistry({
        EqyDriver.kId: EqyDriver(launcher: _playEqy),
      }),
      config: RegressionConfig(
        projectFilePath: config.projectFilePath,
        schemaVersion: '1',
        suites: const [],
        simulatorBinaries: const {},
      ),
      runRoot: work.path,
      retainSuccessfulWorkDirs: true,
    );
    final tests = [for (final s in config.suites) ...s.tests];
    final events = await scheduler
        .submit(RegressionRequest(runId: 'r', tests: tests))
        .toList();
    return {
      for (final f in events.whereType<TestFinished>())
        f.result.testId: f.result,
    };
  }

  test('open core after the beta renders every verdict, partition and '
      'counterexample', () async {
    final results = await runAt(LicenseTier.openCore, betaPeriod: false);

    final falseFail = results['eqy/alu_pass']!;
    expect(falseFail.status, TestStatus.fail);
    expect(falseFail.metrics['formal.verdict'], 'FAIL');
    expect(falseFail.metrics['formal.properties'], '3');
    expect(falseFail.waveformPath, isNotNull);
    expect(File(falseFail.waveformPath!).existsSync(), isTrue);

    final pass = results['eqy/alu_pass2']!;
    expect(pass.status, TestStatus.pass);
    expect(pass.metrics['formal.verdict'], 'PASS');
    expect(pass.metrics['formal.property.0.status'], 'proved');
    expect(pass.metrics['formal.property.1.status'], 'proved');

    final mutant = results['eqy/alu_fail2']!;
    expect(mutant.metrics['formal.properties_failed'], '2');
    for (final n in [0, 1]) {
      expect(mutant.metrics['formal.property.$n.status'], 'counterexample');
      expect(mutant.metrics['formal.property.$n.trace'], isNotNull);
    }
  });

  test('Pro and Enterprise produce exactly the same results', () async {
    Map<String, Object?> shape(Map<String, TestResult> results) => {
      for (final MapEntry(:key, :value) in results.entries)
        key: {
          'status': value.status.name,
          'metrics': {
            for (final m in value.metrics.entries)
              if (m.key != 'formal.wall_time_ms') m.key: m.value,
          },
          'trace': value.waveformPath == null
              ? null
              : p.basename(value.waveformPath!),
        },
    };
    final open = shape(await runAt(LicenseTier.openCore, betaPeriod: false));
    expect(shape(await runAt(LicenseTier.pro, betaPeriod: false)), open);
    expect(shape(await runAt(LicenseTier.enterprise, betaPeriod: false)), open);
  });
}
