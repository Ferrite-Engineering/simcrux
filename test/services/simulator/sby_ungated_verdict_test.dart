// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
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
import 'package:simcrux/services/simulator/riscv_formal_driver.dart';
import 'package:simcrux/services/simulator/sby_driver.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';

import '../../support/formal_fixture_checks.dart';

// The tier law for formal verdicts (VERIFICATION_GUIDE.md §26.6): at Open
// Core with the beta period over and no Pro overrides, every verdict,
// per-property row, metric and counterexample path of an `sby` run is
// produced exactly as at Pro. Nothing here may ever be gated. The Pro
// overlay's ungated_formal_verdict_test is the RISC-V precedent; this is
// its open-core generalisation to the `sby` driver.

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('sby_ungated_'));
  tearDown(() => root.deleteSync(recursive: true));

  /// A project with one demo `sby` test per handshake task, replaying the
  /// committed corpus, and one RISC-V check from the RISC-V corpus.
  String writeProject() {
    final corpus = p.absolute(kFormalFixtureRoot, 'sby', 'handshake_imm');
    final outputs = Directory(p.join(root.path, 'captures'))..createSync();
    for (final task in ['prove', 'prove_bug', 'cover']) {
      final caseDir = Directory(p.join(outputs.path, task))..createSync();
      File(
        p.join(corpus, 'captured', task, 'sby.log'),
      ).copySync(p.join(caseDir.path, 'sby.log'));
      File(
        p.join(corpus, 'captured', 'status.sqlite'),
      ).copySync(p.join(caseDir.path, 'status.sqlite'));
      final traces = <String>[];
      final engine = Directory(p.join(corpus, 'captured', task, 'engine_0'));
      if (engine.existsSync()) {
        Directory(p.join(caseDir.path, 'engine_0')).createSync();
        for (final f in engine.listSync().whereType<File>()) {
          f.copySync(p.join(caseDir.path, 'engine_0', p.basename(f.path)));
          traces.add('engine_0/${p.basename(f.path)}');
        }
      }
      File(p.join(caseDir.path, 'case.json')).writeAsStringSync(
        jsonEncode({
          'log': 'sby.log',
          'traces': traces,
          'status_db': 'status.sqlite',
          'exit_code': task == 'prove_bug' ? 2 : 0,
        }),
      );
    }
    final riscv = p.absolute('verification', 'fixtures', 'riscv_formal');
    final project = File(p.join(root.path, 'simcrux.yaml'))
      ..writeAsStringSync('''
version: "1"
defaults:
  simulator: sby
  formal: { mode: demo, demo_outputs: captures }
suites:
  formal:
    tests:
      - { name: prove, top: t, formal: { task: prove } }
      - { name: prove_bug, top: t, formal: { task: prove_bug } }
      - { name: cover, top: t, formal: { task: cover } }
  riscv:
    tests:
      - name: insn_sub_counterexample
        top: t
        simulator: riscv_formal
        riscv:
          mode: demo
          formal: { demo_outputs: $riscv, check: insn_sub_ch0 }
''');
    return project.path;
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
        SbyDriver.kId: SbyDriver(),
        RiscvFormalDriver.kId: RiscvFormalDriver(),
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

  test(
    'open core after the beta renders every verdict, row and path',
    () async {
      final results = await runAt(LicenseTier.openCore, betaPeriod: false);

      final prove = results['formal/prove']!;
      expect(prove.status, TestStatus.pass);
      expect(prove.metrics['formal.verdict'], 'PASS');
      expect(prove.metrics['formal.properties'], '3');

      final bug = results['formal/prove_bug']!;
      expect(bug.status, TestStatus.fail);
      expect(bug.metrics['formal.verdict'], 'FAIL');
      expect(bug.metrics['formal.properties_failed'], '1');
      expect(bug.waveformPath, isNotNull, reason: 'the counterexample');
      expect(File(bug.waveformPath!).existsSync(), isTrue);
      final rows = [
        for (var n = 0; n < 3; n++) bug.metrics['formal.property.$n.status'],
      ];
      expect(rows, containsAll(['counterexample', 'inconclusive']));

      final cover = results['formal/cover']!;
      expect(cover.status, TestStatus.pass);
      expect(cover.metrics['formal.property.0.status'], 'reached');
      expect(cover.metrics['formal.property.0.step'], '5');

      // The RISC-V row carries both metric sets: riscv.formal.* as shipped,
      // formal.* in addition.
      final riscv = results['riscv/insn_sub_counterexample']!;
      expect(riscv.metrics['riscv.formal.verdict'], 'FAIL');
      expect(riscv.metrics['formal.verdict'], 'FAIL');
      expect(riscv.metrics['formal.tool'], 'sby');
    },
  );

  test('Pro and Enterprise produce exactly the same results', () async {
    Map<String, Object?> shape(Map<String, TestResult> results) => {
      for (final MapEntry(:key, :value) in results.entries)
        key: {
          'status': value.status.name,
          'metrics': {
            for (final m in value.metrics.entries)
              if (m.key != 'formal.wall_time_ms' &&
                  m.key != 'riscv.formal.wall_time_ms')
                m.key: m.value,
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
