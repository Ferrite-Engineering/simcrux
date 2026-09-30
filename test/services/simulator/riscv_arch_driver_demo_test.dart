// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/golden_compare_profile.dart';
import 'package:simcrux/domain/enums/riscv_run_mode.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/job_scheduler.dart';
import 'package:simcrux/domain/models/golden_comparator.dart';
import 'package:simcrux/domain/models/pass_fail_config.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/regression_request.dart';
import 'package:simcrux/domain/models/riscv_config.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/job_scheduler/local_job_scheduler.dart';
import 'package:simcrux/services/simulator/riscv_arch_driver.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';

// Demo mode, driven through the REAL `LocalJobScheduler` and the REAL
// `RiscvArchDriver`.
//
// This is simultaneously the offline-demo path and the CI test path, and
// that is the whole design argument: an env-gated *separate* driver (the
// `SIMCRUX_DEMO_RUNNER` / `DemoSimulatorDriver` pattern) would make CI
// exercise a different code path than production, which is the one thing
// demo mode must not do. So the assertions below are evidence about the
// production path — the same signature reading, the same GoldenComparator
// call, the same metric emission, the same event construction. Only the
// spawn steps are skipped.
//
// The corpus is the `golden_compare` detector's, unchanged:
// `verification/fixtures/golden_compare/` already covers all six required
// cases plus the format-variance pair, and
// authoring a second fixture set would give the two halves somewhere to
// drift apart.
//
// MUTATION: make the driver report `unknown` (or `vacuous`) for a missing
// DUT dump and `missing_dut reports fail` fails — that mutation is exactly
// the exit-0 trap that turns a broken core green.

const String _corpus = 'verification/fixtures/golden_compare';

void main() {
  late Directory runRoot;

  setUp(() {
    runRoot = Directory.systemTemp.createTempSync('simcrux_riscv_demo_');
  });

  tearDown(() {
    if (runRoot.existsSync()) runRoot.deleteSync(recursive: true);
  });

  List<String> corpusCases() =>
      Directory(_corpus)
          .listSync()
          .whereType<Directory>()
          .map(
            (d) => p.basename(d.path),
          )
          .toList()
        ..sort();

  TestSpec demoSpec(
    String caseName, {
    String extension = 'I',
    int? wordSize,
    String? isa,
  }) => TestSpec(
    id: 'arch/$caseName',
    name: caseName,
    suiteName: 'arch',
    simulatorId: RiscvArchDriver.kId,
    top: caseName,
    timeout: const Duration(seconds: 30),
    // What the importer emits alongside the `riscv:` block. With
    // `profile: riscv_signature` and no explicit paths this resolves to
    // `signature.dut.sig` / `signature.ref.sig` — exactly what the driver
    // writes. The detector's config is self-contained and never sees the
    // `riscv:` block; that shared convention is what keeps them agreeing.
    passFail: GoldenComparePassFailConfig.forProfile(
      GoldenCompareProfile.riscvSignature,
    ),
    riscv: RiscvConfig(
      isa: isa ?? 'rv32imc_zicsr_zifencei',
      mode: RiscvRunMode.demo,
      demoSignatures: p.absolute(_corpus),
      demoCase: caseName,
      extension: extension,
      signature: wordSize == null
          ? null
          : RiscvSignatureConfig(wordSize: wordSize),
    ),
  );

  Future<Map<String, TestResult>> run(List<TestSpec> specs) async {
    final driver = RiscvArchDriver();
    final scheduler = LocalJobScheduler(
      driverRegistry: SimulatorDriverRegistry({driver.id: driver}),
      config: RegressionConfig(
        projectFilePath: '/fake/simcrux.yaml',
        schemaVersion: '1',
        suites: const [],
        simulatorBinaries: const {},
      ),
      runRoot: runRoot.path,
    );
    final events = await scheduler
        .submit(RegressionRequest(runId: 'r1', tests: specs))
        .toList();
    return {
      for (final f in events.whereType<TestFinished>())
        f.result.testId: f.result,
    };
  }

  Map<String, Object?> expectedFor(String caseName) =>
      jsonDecode(
            File(p.join(_corpus, caseName, 'expected.json')).readAsStringSync(),
          )
          as Map<String, Object?>;

  group('the whole flow, with no RISC-V toolchain present', () {
    test('every committed case replays to its golden_compare verdict', () async {
      final cases = corpusCases();
      expect(
        cases,
        containsAll(<String>[
          'clean_pass',
          'first_word_mismatch',
          'mid_file_mismatch',
          'length_mismatch',
          'empty_dut',
          'missing_dut',
        ]),
        reason:
            'the required case list — demo mode consumes the golden_compare corpus, so '
            'a case disappearing there silently narrows this coverage',
      );
      final results = await run(cases.map(demoSpec).toList());
      for (final caseName in cases) {
        // `format_variance_generic` is the corpus's counter-case: the same bytes
        // read under `profile: generic`, which reports fail. This driver is
        // RISC-V by definition and always compares under
        // `profile: riscv_signature`, so its verdict there is `pass` — see
        // the dedicated test below, which is what makes the profile
        // observable from the driver's side.
        if (expectedFor(caseName)['profile'] !=
            GoldenCompareProfile.riscvSignature.wireName) {
          continue;
        }
        final expected = expectedFor(caseName)['status']! as String;
        expect(
          results['arch/$caseName']!.status.name,
          expected,
          reason: 'case $caseName',
        );
      }
    });

    test(
      'the driver always compares under the riscv_signature profile',
      () async {
        // The format-variance pair shares its bytes: under `generic` it
        // fails at offset 0, under `riscv_signature` it passes. The driver
        // is ISA-coupled by construction, so it must report pass — if it
        // ever reported the generic verdict, the profile is not in force.
        final generic = expectedFor('format_variance_generic');
        expect(
          generic['status'],
          'fail',
          reason: "the corpus's generic verdict",
        );
        final results = await run([
          demoSpec('format_variance_generic'),
          demoSpec('format_variance_riscv'),
        ]);
        expect(
          results['arch/format_variance_generic']!.status,
          TestStatus.pass,
        );
        expect(results['arch/format_variance_riscv']!.status, TestStatus.pass);
      },
    );

    test('a clean pass really passes', () async {
      final results = await run([demoSpec('clean_pass')]);
      expect(results['arch/clean_pass']!.status, TestStatus.pass);
      expect(results['arch/clean_pass']!.failureMessage, isNull);
    });

    test('no subprocess is spawned — the driver never touches PATH', () async {
      // The strongest available statement of "no toolchain needed": the
      // driver is constructed with a launcher that throws if it is ever
      // asked to spawn anything.
      final driver = RiscvArchDriver(
        launcher:
            (
              executable,
              args, {
              environment,
              workingDirectory,
            }) async =>
                throw StateError('demo mode must not spawn $executable'),
      );
      final scheduler = LocalJobScheduler(
        driverRegistry: SimulatorDriverRegistry({driver.id: driver}),
        config: RegressionConfig(
          projectFilePath: '/fake/simcrux.yaml',
          schemaVersion: '1',
          suites: const [],
          simulatorBinaries: const {},
        ),
        runRoot: runRoot.path,
      );
      final events = await scheduler
          .submit(
            RegressionRequest(runId: 'r1', tests: [demoSpec('clean_pass')]),
          )
          .toList();
      final result = events.whereType<TestFinished>().single.result;
      expect(result.status, TestStatus.pass);
    });
  });

  group('the two exit-0 status traps', () {
    test('missing DUT dump reports fail — never unknown', () async {
      // `unknown` hands the verdict back to the driver, and the driver's
      // own exit code here is 0. A core that produced no signature would
      // report pass.
      final results = await run([demoSpec('missing_dut')]);
      final status = results['arch/missing_dut']!.status;
      expect(status, TestStatus.fail);
      expect(status, isNot(TestStatus.unknown));
      expect(status, isNot(TestStatus.vacuous));
      expect(
        results['arch/missing_dut']!.failureMessage,
        contains('signature.dut.sig'),
      );
    });

    test('empty DUT dump reports fail — never vacuous', () async {
      // `vacuous` is success-equivalent to the scheduler: no retry, and
      // the work dir holding the evidence is deleted.
      final results = await run([demoSpec('empty_dut')]);
      final status = results['arch/empty_dut']!.status;
      expect(status, TestStatus.fail);
      expect(status, isNot(TestStatus.vacuous));
    });

    test('no case in the corpus ever produces unknown or vacuous', () async {
      final results = await run(corpusCases().map(demoSpec).toList());
      for (final entry in results.entries) {
        expect(
          entry.value.status,
          anyOf(TestStatus.pass, TestStatus.fail),
          reason: entry.key,
        );
      }
    });
  });

  group('metrics — the driver emits them, the detector cannot', () {
    test("golden.* metrics match the corpus's committed expectation", () async {
      final results = await run([demoSpec('mid_file_mismatch')]);
      final metrics = results['arch/mid_file_mismatch']!.metrics;
      final expected =
          expectedFor('mid_file_mismatch')['metrics']! as Map<String, Object?>;
      for (final entry in expected.entries) {
        expect(metrics[entry.key], entry.value, reason: entry.key);
      }
    });

    test('the offset comes from the shared GoldenComparator', () async {
      final results = await run([demoSpec('first_word_mismatch')]);
      // Offset 0 is the boundary an off-by-one hides.
      expect(
        results['arch/first_word_mismatch']!.metrics[GoldenComparator
            .kMetricMismatchOffset],
        '0',
      );
    });

    test('riscv.signature.byte_offset scales the word offset', () async {
      // The one key that has a real consumer HERE that it did not have on
      // the detector: locating the divergent instruction for the Pro diff
      // viewer needs a width, and the comparator deliberately has none.
      final wide = await run([
        demoSpec('mid_file_mismatch', wordSize: 8),
      ]);
      final words = int.parse(
        wide['arch/mid_file_mismatch']!.metrics[GoldenComparator
            .kMetricMismatchOffset]!,
      );
      expect(
        wide['arch/mid_file_mismatch']!.metrics[RiscvArchDriver
            .kMetricSignatureByteOffset],
        '${words * 8}',
      );
      expect(
        wide['arch/mid_file_mismatch']!.metrics[RiscvArchDriver
            .kMetricSignatureWordSize],
        '8',
      );
    });

    test('the byte offset is absent when nothing diverged', () async {
      final results = await run([demoSpec('clean_pass')]);
      expect(
        results['arch/clean_pass']!.metrics[RiscvArchDriver
            .kMetricSignatureByteOffset],
        isNull,
      );
    });

    test('the extension tag rides into metrics for the Pro rollup', () async {
      final results = await run([
        demoSpec('clean_pass', extension: 'Zicsr'),
      ]);
      expect(
        results['arch/clean_pass']!.metrics[RiscvArchDriver.kMetricExtension],
        'Zicsr',
      );
      expect(
        results['arch/clean_pass']!.metrics[RiscvArchDriver.kMetricIsa],
        'rv32imc_zicsr_zifencei',
      );
    });

    test(
      'the mode is recorded so a demo row cannot pass as a real run',
      () async {
        final results = await run([demoSpec('clean_pass')]);
        final metrics = results['arch/clean_pass']!.metrics;
        expect(metrics[RiscvArchDriver.kMetricMode], 'demo');
        // No reference model ran, so none is attributed — an exported
        // compatibility report must not claim a model that never executed.
        expect(metrics[RiscvArchDriver.kMetricReferenceModel], isNull);
      },
    );

    test(
      'metrics survive to TestResult, which is fed only by the driver',
      () async {
        // `TestResult.metrics` is fed solely from
        // `TestExecutionFinished.metrics`; a detector structurally cannot
        // write them. These arriving on the result IS the proof that
        // the driver, not the detector, emitted them.
        final results = await run([demoSpec('length_mismatch')]);
        final metrics = results['arch/length_mismatch']!.metrics;
        expect(metrics[GoldenComparator.kMetricDutWords], isNotNull);
        expect(metrics[GoldenComparator.kMetricRefWords], isNotNull);
        expect(
          metrics[GoldenComparator.kMetricDutWords],
          isNot(metrics[GoldenComparator.kMetricRefWords]),
        );
      },
    );
  });

  group('failure messages are dashboard-row sized', () {
    test('a word divergence names the offset and both values', () async {
      final results = await run([demoSpec('mid_file_mismatch')]);
      final message = results['arch/mid_file_mismatch']!.failureMessage!;
      expect(message, contains('signature mismatch at word'));
      expect(message, contains('byte'));
      expect(message, isNot(contains('\n')));
      expect(message.length, lessThan(160));
    });

    test('a length divergence says so, with both word counts', () async {
      final results = await run([demoSpec('length_mismatch')]);
      final message = results['arch/length_mismatch']!.failureMessage!;
      expect(message, contains('length mismatch'));
      expect(message, contains('words'));
    });

    test('an empty dump says empty, not "mismatch at word 0"', () async {
      final results = await run([demoSpec('empty_dut')]);
      expect(
        results['arch/empty_dut']!.failureMessage,
        contains('empty'),
      );
    });
  });

  group('demo mode is config-declared, not environment-gated', () {
    test('the driver id is the ordinary one, not a demo variant', () {
      // Explicitly NOT the SIMCRUX_DEMO_RUNNER pattern: there is one
      // driver id and one code path.
      expect(RiscvArchDriver.kId, 'riscv_arch');
      expect(RiscvArchDriver.kId, RiscvConfig.kSimulatorId);
    });

    test('a spec with no riscv block at all does not silently pass', () async {
      // Defaults to `mode: normal`, which the loader refuses — but a
      // programmatically-built spec can still reach the driver, and it must
      // fail loudly rather than report green.
      final spec = TestSpec(
        id: 'arch/naked',
        name: 'naked',
        suiteName: 'arch',
        simulatorId: RiscvArchDriver.kId,
        top: 'naked',
        timeout: const Duration(seconds: 30),
      );
      final results = await run([spec]);
      expect(results['arch/naked']!.status, isNot(TestStatus.pass));
      expect(results['arch/naked']!.status, isNot(TestStatus.vacuous));
    });
  });
}
