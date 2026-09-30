// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/riscv_run_mode.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/job_scheduler.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/regression_request.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/config/config_loader.dart';
import 'package:simcrux/services/job_scheduler/local_job_scheduler.dart';
import 'package:simcrux/services/simulator/riscv_arch_driver.dart';
import 'package:simcrux/services/simulator/riscv_formal_driver.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';

// The two shipped `examples/riscv-*-demo/simcrux.yaml` files, driven the
// way a user drives them: parsed by the REAL `ConfigLoader` and executed by
// the REAL `LocalJobScheduler` and the REAL drivers, with a process
// launcher that throws if anything is ever spawned.
//
// Why this test exists at all, in this shape:
//
//   1. Three committed `simcrux.yaml` fixtures in this repo were
//      unopenable for months because their guard asserted
//      `File(...).existsSync()` instead of parsing them (fixed in
//      `4024939`). Existence is not loadability. So every assertion below
//      goes through `ConfigLoader.load`, and zero warnings is part of the
//      contract, not only zero errors.
//   2. "Runs offline against committed fixtures with no RISC-V toolchain
//      installed" is a claim we make in public. The launcher that throws is
//      the strongest available statement of it — stronger than asserting
//      it, and only meaningful because demo mode is the SAME driver as the
//      real path rather than an env-gated stand-in.
//   3. A report that shows only green demonstrates nothing, so the spread
//      is asserted per test, by name, in both directions.
//
// MUTATION: point either config's demo-corpus key at a directory that does
// not exist, or delete a corpus case, and the spread assertions fail.

const String _compatConfig = 'examples/riscv-compatibility-demo/simcrux.yaml';
const String _formalConfig = 'examples/riscv-formal-demo/simcrux.yaml';

/// A launcher that refuses to spawn. Every example must reach a terminal
/// verdict without it ever being called.
Future<TestProcess> _refuseToSpawn(
  String executable,
  List<String> arguments, {
  Map<String, String>? environment,
  String? workingDirectory,
}) async => throw StateError(
  'demo mode must spawn nothing — asked for `$executable` '
  '${arguments.join(' ')}',
);

void main() {
  late Directory runRoot;

  setUp(() {
    runRoot = Directory.systemTemp.createTempSync('simcrux_examples_');
  });

  tearDown(() {
    if (runRoot.existsSync()) runRoot.deleteSync(recursive: true);
  });

  Future<RegressionConfig> load(String relativePath) =>
      ConfigLoader().load(p.absolute(relativePath));

  /// Runs every test in [config] through the real scheduler with both
  /// RISC-V drivers registered and nothing spawnable.
  Future<Map<String, TestResult>> run(RegressionConfig config) async {
    final arch = RiscvArchDriver(launcher: _refuseToSpawn);
    final formal = RiscvFormalDriver(launcher: _refuseToSpawn);
    final scheduler = LocalJobScheduler(
      driverRegistry: SimulatorDriverRegistry({
        arch.id: arch,
        formal.id: formal,
      }),
      config: config,
      runRoot: runRoot.path,
    );
    final tests = <TestSpec>[
      for (final suite in config.suites) ...suite.tests,
    ];
    final events = await scheduler
        .submit(RegressionRequest(runId: 'examples', tests: tests))
        .toList();
    return {
      for (final finished in events.whereType<TestFinished>())
        finished.result.testId: finished.result,
    };
  }

  /// Asserts `results` reports exactly [passing] passes and that every
  /// other test failed — never `unknown`, never `vacuous`, never
  /// `timeout`, and never missing.
  void expectSpread(
    Map<String, TestResult> results,
    Set<String> passing,
    Set<String> failing,
  ) {
    expect(
      results.keys.toSet(),
      {...passing, ...failing},
      reason: 'every declared test must reach a terminal event',
    );
    for (final id in passing) {
      expect(results[id]!.status, TestStatus.pass, reason: id);
    }
    for (final id in failing) {
      expect(results[id]!.status, TestStatus.fail, reason: id);
    }
  }

  group('examples/riscv-compatibility-demo', () {
    test('loads through the real ConfigLoader with no errors', () async {
      final config = await load(_compatConfig);
      expect(config.schemaVersion, '1');
      expect(config.suites.map((s) => s.name).toList(), [
        'I',
        'M',
        'C',
        'Zicsr',
      ]);
      expect(config.suites.expand((s) => s.tests).length, 8);
    });

    test('and with no warnings either', () async {
      // The tier gate that produces warnings covers `seeds:` /
      // `parameters:` sweeps. The example deliberately declares neither:
      // an Open Core user post-beta must see a clean load, not an advisory
      // telling them a block was dropped.
      final config = await load(_compatConfig);
      expect(
        config.loadWarnings.map((w) => w.toString()).toList(),
        isEmpty,
      );
    });

    test('every path in it resolves from its committed location', () async {
      final config = await load(_compatConfig);
      for (final test in config.suites.expand((s) => s.tests)) {
        final riscv = test.riscv!;
        expect(riscv.effectiveMode, RiscvRunMode.demo, reason: test.id);
        final corpus = riscv.demoSignatures!;
        final demoCase = riscv.demoCase;
        expect(p.isAbsolute(corpus), isTrue, reason: test.id);
        expect(demoCase, isNotNull, reason: test.id);
        expect(
          Directory(p.join(corpus, demoCase)).existsSync(),
          isTrue,
          reason: '${test.id}: no corpus case at $corpus/$demoCase',
        );
      }
    });

    test(
      'runs to completion with nothing spawned, three pass / five fail',
      () async {
        final results = await run(await load(_compatConfig));
        expectSpread(
          results,
          {
            'I/clean_pass',
            'Zicsr/format_variance_riscv',
            // The same bytes as `format_variance_generic`, which the corpus records
            // as `fail` under `profile: generic`. This driver is ISA-coupled
            // by construction and always compares under `riscv_signature`,
            // so both halves of the pair pass here — that is what makes the
            // profile observable from the driver's side.
            'Zicsr/format_variance_generic',
          },
          {
            'I/first_word_mismatch',
            'M/mid_file_mismatch',
            'M/length_mismatch',
            'C/empty_dut',
            'C/missing_dut',
          },
        );
      },
    );

    test('the two exit-0 traps stay failures in the shipped example', () async {
      final results = await run(await load(_compatConfig));
      // `unknown` hands the verdict back to the driver, whose exit code is
      // 0 here; `vacuous` is success-equivalent to the scheduler. Either
      // would turn a core that produced no signature at all green.
      for (final id in const ['C/missing_dut', 'C/empty_dut']) {
        expect(results[id]!.status, isNot(TestStatus.unknown), reason: id);
        expect(results[id]!.status, isNot(TestStatus.vacuous), reason: id);
        expect(results[id]!.status, isNot(TestStatus.pass), reason: id);
      }
    });

    test(
      'the metrics the Pro compatibility rollup groups on are emitted',
      () async {
        final results = await run(await load(_compatConfig));
        final byExtension = <String, List<TestStatus>>{};
        for (final entry in results.entries) {
          final metrics = entry.value.metrics;
          expect(
            metrics[RiscvArchDriver.kMetricMode],
            'demo',
            reason: '${entry.key}: a demo row must never pass as a real run',
          );
          expect(
            metrics[RiscvArchDriver.kMetricIsa],
            'rv32imc_zicsr_zifencei',
            reason: entry.key,
          );
          final extension = metrics[RiscvArchDriver.kMetricExtension];
          expect(extension, isNotNull, reason: entry.key);
          (byExtension[extension!] ??= []).add(entry.value.status);
        }
        // The rollup the Pro dashboard renders: four groups, one of them
        // mixed, so the report is not uniformly green or uniformly red.
        expect(byExtension.keys.toSet(), {'I', 'M', 'C', 'Zicsr'});
        expect(
          byExtension['I'],
          containsAll([TestStatus.pass, TestStatus.fail]),
        );
        expect(byExtension['Zicsr'], everyElement(TestStatus.pass));
        expect(byExtension['M'], everyElement(TestStatus.fail));
        expect(byExtension['C'], everyElement(TestStatus.fail));
      },
    );
  });

  group('examples/riscv-formal-demo', () {
    test('loads through the real ConfigLoader with no errors', () async {
      final config = await load(_formalConfig);
      expect(config.schemaVersion, '1');
      expect(config.suites.map((s) => s.name).toList(), [
        'insn',
        'pc_fwd',
        'reg',
        'causal',
        'liveness',
        'cover',
      ]);
      expect(config.suites.expand((s) => s.tests).length, 7);
    });

    test('and with no warnings either', () async {
      final config = await load(_formalConfig);
      expect(
        config.loadWarnings.map((w) => w.toString()).toList(),
        isEmpty,
      );
    });

    test('every path in it resolves from its committed location', () async {
      final config = await load(_formalConfig);
      for (final test in config.suites.expand((s) => s.tests)) {
        final riscv = test.riscv!;
        expect(riscv.effectiveMode, RiscvRunMode.demo, reason: test.id);
        // A separate key from the compatibility flow's `demo_signatures`
        // — the two corpora are different shapes.
        final corpus = riscv.formal!.demoOutputs!;
        final demoCase = riscv.demoCase;
        expect(p.isAbsolute(corpus), isTrue, reason: test.id);
        expect(demoCase, isNotNull, reason: test.id);
        expect(
          File(p.join(corpus, demoCase, 'case.json')).existsSync(),
          isTrue,
          reason: '${test.id}: no corpus case at $corpus/$demoCase',
        );
      }
    });

    test(
      'runs to completion with nothing spawned, two pass / five fail',
      () async {
        final results = await run(await load(_formalConfig));
        expectSpread(
          results,
          {'insn/insn_add_pass', 'cover/cover_multi_trace'},
          {
            'insn/insn_sub_counterexample',
            'pc_fwd/pc_fwd_unknown',
            'reg/reg_timeout',
            'causal/causal_error',
            'liveness/liveness_no_outcome',
          },
        );
      },
    );

    test(
      'the example covers all four verdicts plus the two edge cases',
      () async {
        final results = await run(await load(_formalConfig));
        final verdicts = {
          for (final entry in results.entries)
            entry.key: entry.value.metrics[RiscvFormalDriver.kMetricVerdict],
        };
        expect(verdicts['insn/insn_add_pass'], 'PASS');
        expect(verdicts['insn/insn_sub_counterexample'], 'FAIL');
        expect(verdicts['pc_fwd/pc_fwd_unknown'], 'UNKNOWN');
        expect(verdicts['reg/reg_timeout'], 'TIMEOUT');
        expect(verdicts['causal/causal_error'], 'ERROR');
        expect(verdicts['liveness/liveness_no_outcome'], 'NO_OUTCOME');
        expect(verdicts['cover/cover_multi_trace'], 'PASS');
        // The whole reason the four-way distinction is worth rendering: an
        // exit-code reading collapses UNKNOWN and TIMEOUT into "not pass"
        // and reads NO_OUTCOME's exit 0 as a pass.
        expect(verdicts.values.toSet().length, greaterThanOrEqualTo(5));
      },
    );

    test(
      "SymbiYosys's own timeout is a fail, not TestStatus.timeout",
      () async {
        // `TestStatus.timeout` means SimCrux killed the job. Nothing was
        // killed here — the solver gave up on its own budget.
        final results = await run(await load(_formalConfig));
        expect(results['reg/reg_timeout']!.status, TestStatus.fail);
        expect(results['reg/reg_timeout']!.status, isNot(TestStatus.timeout));
      },
    );

    test(
      'the metrics the Pro formal dashboard groups on are emitted',
      () async {
        final results = await run(await load(_formalConfig));
        final byGroup = <String, List<TestStatus>>{};
        for (final entry in results.entries) {
          final metrics = entry.value.metrics;
          expect(
            metrics[RiscvFormalDriver.kMetricMode],
            'demo',
            reason: entry.key,
          );
          expect(
            metrics[RiscvFormalDriver.kMetricCheck],
            isNotNull,
            reason: entry.key,
          );
          final group = metrics[RiscvFormalDriver.kMetricGroup];
          expect(group, isNotNull, reason: entry.key);
          (byGroup[group!] ??= []).add(entry.value.status);
        }
        expect(byGroup.keys.toSet(), {
          'insn',
          'pc_fwd',
          'reg',
          'causal',
          'liveness',
          'cover',
        });
        expect(
          byGroup['insn'],
          containsAll([TestStatus.pass, TestStatus.fail]),
        );
      },
    );

    test('the counterexample trace reaches the result', () async {
      // The hand-off to WaveCrux: "Debug in WaveCrux" needs a path that still
      // exists, and the scheduler only sweeps work dirs of *successful*
      // tests.
      final results = await run(await load(_formalConfig));
      final result = results['insn/insn_sub_counterexample']!;
      expect(result.metrics[RiscvFormalDriver.kMetricTraceCount], '1');
      final waveform = result.waveformPath;
      expect(waveform, isNotNull);
      expect(File(waveform!).existsSync(), isTrue, reason: waveform);
    });
  });
}
