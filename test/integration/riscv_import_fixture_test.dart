// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/riscv_import_kind.dart';
import 'package:simcrux/domain/enums/riscv_run_mode.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/job_scheduler.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/regression_request.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/config/config_loader.dart';
import 'package:simcrux/services/import/riscv_import_cli.dart';
import 'package:simcrux/services/job_scheduler/local_job_scheduler.dart';
import 'package:simcrux/services/simulator/riscv_arch_driver.dart';
import 'package:simcrux/services/simulator/riscv_formal_driver.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';

// The two RISC-V importers driven the way a user drives them — through the
// `simcrux import-riscv-…` sub-command — and then the file they wrote driven
// the way a user drives THAT: parsed by the REAL `ConfigLoader` and, where the
// committed corpora make it possible, executed by the REAL
// `LocalJobScheduler` and the REAL drivers with a process launcher that throws
// if anything is ever spawned.
//
// Why this test exists, in this shape:
//
//   1. The failure mode being ruled out is an importer that emits *plausible*
//      YAML the loader rejects. Both importers were fully implemented, fully
//      unit-tested, and completely unreachable from the application — nothing
//      had ever parsed their output. Three committed `simcrux.yaml` fixtures
//      in this repo were unopenable for months for exactly that reason
//      (existence is not loadability), so every assertion below goes through
//      `ConfigLoader.load`, and **zero warnings** is part of the contract,
//      not only zero errors.
//   2. `mode: normal` cannot reach the scheduler without spawning a
//      cross-compiler and a DUT, so the run-it-for-real half uses
//      `--mode demo` over the SAME committed corpora `examples/riscv-*-demo`
//      replay. That is not a weaker test of the importer: the emitted YAML is
//      produced by the same `_emit` path, and it is the only variant where
//      "nothing was spawned" is assertable rather than asserted.
//   3. `riscv.target.command` is the one input an importer cannot derive from
//      a checkout, and the loader requires it in `mode: normal`. Both halves
//      of that — supplied, it loads clean; omitted, the importer says so and
//      the loader refuses — are pinned below, because a wiring change that
//      quietly dropped the flag would otherwise look green.
//
// MUTATION: drop `--target-command` from the arch-test invocation, or point
// either `--mode demo` invocation at a directory that is not a corpus, and
// these fail.

const String _archFixture = 'test/fixtures/riscv_arch_test';
const String _formalFixture = 'test/fixtures/riscv_formal_checks';
const String _archDemoCorpus = 'verification/fixtures/golden_compare';
const String _formalDemoCorpus = 'verification/fixtures/riscv_formal';

/// A launcher that refuses to spawn. Every demo-mode import must reach a
/// terminal verdict without it ever being called.
Future<TestProcess> _refuseToSpawn(
  String executable,
  List<String> arguments, {
  Map<String, String>? environment,
  String? workingDirectory,
}) async => throw StateError(
  'demo mode must spawn nothing — asked for `$executable` '
  '${arguments.join(' ')}',
);

/// A loader that honors project-defined tooling.
///
/// The importer's whole job is to write a `simcrux.yaml` carrying
/// `riscv.target.command` — the argv list `riscv_arch_driver` spawns —
/// from a command the user typed at `--target-command`. The default
/// loader refuses that key, because an arbitrary downloaded project file
/// may not choose what SimCrux executes. These cases are about what the
/// importer emits, so they load as a user who has trusted the file they
/// just generated (Settings → Simulators → "Let project files choose
/// simulator binaries and environment", or `--allow-project-tooling`). The
/// gate itself is
/// `test/services/config/config_loader_project_tooling_test.dart`.
ConfigLoader _trustingLoader() =>
    ConfigLoader(allowProjectDefinedTooling: true);

void main() {
  late Directory tmp;
  late Directory runRoot;
  late List<String> printed;
  late RiscvImportCli cli;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('simcrux_riscv_import_');
    runRoot = Directory.systemTemp.createTempSync('simcrux_riscv_import_run_');
    printed = <String>[];
    cli = RiscvImportCli(stdoutWriter: printed.add);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    if (runRoot.existsSync()) runRoot.deleteSync(recursive: true);
  });

  /// Runs the sub-command and returns the path it wrote.
  Future<String> import(
    RiscvImportKind kind,
    List<String> args, {
    String outName = 'simcrux.yaml',
  }) async {
    final out = p.join(tmp.path, outName);
    final result = await cli.run(kind, [...args, '--out', out]);
    expect(result.outputPath, out);
    expect(File(out).existsSync(), isTrue, reason: 'nothing was written');
    return out;
  }

  /// Runs every test in [config] through the real scheduler with both RISC-V
  /// drivers registered and nothing spawnable.
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
        .submit(RegressionRequest(runId: 'import', tests: tests))
        .toList();
    return {
      for (final finished in events.whereType<TestFinished>())
        finished.result.testId: finished.result,
    };
  }

  group('simcrux import-riscv-arch-test over a riscv-arch-test layout', () {
    /// The complete invocation a user copies out of the docs: the checkout,
    /// plus the DUT command the loader requires and no importer can derive.
    Future<String> importSuite({List<String> extra = const []}) => import(
      RiscvImportKind.archTest,
      [
        p.absolute(_archFixture),
        '--target-command',
        './my_core --elf {elf} --signature {signature}',
        '--isa',
        'rv32imc_zicsr',
        '--toolchain-prefix',
        'riscv64-unknown-elf-',
        '--reference-model',
        'spike',
        '--word-size',
        '4',
        ...extra,
      ],
    );

    test('emits one test per .S file, grouped by extension', () async {
      final config = await _trustingLoader().load(await importSuite());
      expect(config.schemaVersion, '1');
      expect(config.suites.map((s) => s.name).toList(), ['C', 'I', 'M']);
      expect(
        config.suites.expand((s) => s.tests).map((t) => t.id).toList(),
        [
          'C/cadd-01',
          'I/add-01',
          'I/addi-01',
          'M/mul-01',
        ],
      );
    });

    test('the emitted config loads with zero errors AND zero warnings', () {
      // The whole point. A tier gate produces load warnings for `seeds:` /
      // `parameters:` sweeps; the importer emits neither, so an evaluator
      // pointing SimCrux at a checkout must see a clean load, not an
      // advisory telling them a block was dropped.
      expect(
        importSuite().then(_trustingLoader().load).then((c) => c.loadWarnings),
        completion(isEmpty),
      );
    });

    test('every emitted test carries the plumbing the driver needs', () async {
      final config = await _trustingLoader().load(await importSuite());
      for (final test in config.suites.expand((s) => s.tests)) {
        final riscv = test.riscv!;
        expect(test.simulatorId, 'riscv_arch', reason: test.id);
        // `top:` is mandatory on every TestSpec and an architectural test
        // has no HDL top level, so the base name stands in. An importer
        // that omitted it would emit a config the loader refuses.
        expect(test.top, isNotEmpty, reason: test.id);
        expect(riscv.effectiveMode, RiscvRunMode.normal, reason: test.id);
        expect(riscv.target!.command, isNotEmpty, reason: test.id);
        expect(riscv.extension, isNotNull, reason: test.id);
        expect(riscv.isa, 'rv32imc_zicsr', reason: test.id);
        expect(riscv.signature!.wordSize, 4, reason: test.id);
      }
    });

    test(
      'every emitted test path resolves against the SUITE, not the cwd',
      () async {
        // The emitted `riscv.test` is relative to `arch_test.suite_path`,
        // which the importer pins absolute — so the written file resolves
        // from wherever it is opened rather than from wherever the importer
        // ran. A GUI build launched from Finder has cwd `/`.
        final config = await _trustingLoader().load(await importSuite());
        for (final test in config.suites.expand((s) => s.tests)) {
          final riscv = test.riscv!;
          final suitePath = riscv.archTest!.suitePath!;
          final testPath = riscv.testPath!;
          expect(p.isAbsolute(suitePath), isTrue, reason: test.id);
          expect(p.isAbsolute(testPath), isFalse, reason: test.id);
          expect(
            File(p.join(suitePath, testPath)).existsSync(),
            isTrue,
            reason: '${test.id}: no source at $suitePath/$testPath',
          );
        }
      },
    );

    test('--extensions restricts the import', () async {
      final config = await _trustingLoader().load(
        await importSuite(extra: const ['--extensions', 'i,M']),
      );
      // Case-insensitive, and the excluded extension leaves no empty suite
      // behind.
      expect(config.suites.map((s) => s.name).toList(), ['I', 'M']);
      expect(config.suites.expand((s) => s.tests), hasLength(3));
    });

    test(
      'without --target-command the importer warns AND the loader refuses',
      () async {
        // The one input neither importer can derive from a checkout. The
        // honest behaviour is to say so twice — once from the importer, once
        // from the loader — rather than emit a file that silently cannot run.
        final result = await cli.run(RiscvImportKind.archTest, [
          p.absolute(_archFixture),
          '--out',
          p.join(tmp.path, 'no_target.yaml'),
        ]);
        expect(
          result.warnings.map((w) => w.code),
          contains('missing_target_command'),
        );
        await expectLater(
          _trustingLoader().load(p.join(tmp.path, 'no_target.yaml')),
          throwsA(
            isA<Object>().having(
              (e) => '$e',
              'message',
              contains('riscv.target.command'),
            ),
          ),
        );
      },
    );
  });

  group('simcrux import-riscv-formal over a genchecks.py checks/ dir', () {
    Future<String> importChecks({List<String> extra = const []}) => import(
      RiscvImportKind.formal,
      [p.absolute(_formalFixture), '--isa', 'rv32imc', ...extra],
    );

    test('emits one test per proof, grouped by property group', () async {
      final config = await _trustingLoader().load(await importChecks());
      expect(config.suites.map((s) => s.name).toList(), [
        'cover',
        'insn',
        'pc_fwd',
        'reg',
      ]);
      // Six, not five: `cover_ch0.sby` declares two tasks and one `sby`
      // invocation over both would print two `DONE (…)` lines into one
      // result row.
      expect(config.suites.expand((s) => s.tests), hasLength(6));
    });

    test('the emitted config loads with zero errors AND zero warnings', () {
      expect(
        importChecks().then(_trustingLoader().load).then((c) => c.loadWarnings),
        completion(isEmpty),
      );
    });

    test('a multi-task .sby becomes one test per task, and says so', () async {
      final result = await cli.run(RiscvImportKind.formal, [
        p.absolute(_formalFixture),
        '--out',
        p.join(tmp.path, 'formal.yaml'),
      ]);
      expect(result.warnings.map((w) => w.code), contains('multi_task_sby'));
      final config = await _trustingLoader().load(
        p.join(tmp.path, 'formal.yaml'),
      );
      final cover = config.suites.firstWhere((s) => s.name == 'cover');
      expect(
        cover.tests.map((t) => t.riscv!.formal!.task).toList(),
        ['liveness', 'reach'],
      );
      // Both tasks still point at the one generated job file.
      expect(
        cover.tests.map((t) => t.riscv!.formal!.sbyFile).toSet(),
        {'cover_ch0.sby'},
      );
    });

    test('every emitted proof carries the plumbing the driver needs', () async {
      final config = await _trustingLoader().load(await importChecks());
      for (final test in config.suites.expand((s) => s.tests)) {
        final formal = test.riscv!.formal!;
        expect(test.simulatorId, 'riscv_formal', reason: test.id);
        expect(test.top, isNotEmpty, reason: test.id);
        expect(formal.sbyFile, isNotNull, reason: test.id);
        // `checks_dir` is absolute and `sby_file` is relative to it, so the
        // written file resolves from wherever it is opened.
        final checksDir = formal.checksDir!;
        final sbyFile = formal.sbyFile!;
        expect(p.isAbsolute(checksDir), isTrue, reason: test.id);
        expect(p.isAbsolute(sbyFile), isFalse, reason: test.id);
        expect(
          File(p.join(checksDir, sbyFile)).existsSync(),
          isTrue,
          reason: '${test.id}: no job at $checksDir/$sbyFile',
        );
      }
    });

    test('--groups restricts the import', () async {
      final config = await _trustingLoader().load(
        await importChecks(extra: const ['--groups', 'insn,REG']),
      );
      expect(config.suites.map((s) => s.name).toList(), ['insn', 'reg']);
      expect(config.suites.expand((s) => s.tests), hasLength(3));
    });
  });

  group('--mode demo imports run end to end with nothing spawned', () {
    test('the arch-test corpus imports, loads and runs', () async {
      final out = await import(RiscvImportKind.archTest, [
        p.absolute(_archDemoCorpus),
        '--mode',
        'demo',
        '--isa',
        'rv32imc_zicsr_zifencei',
        '--word-size',
        '4',
      ]);
      final config = await _trustingLoader().load(out);
      expect(config.loadWarnings, isEmpty);
      expect(config.suites.expand((s) => s.tests), hasLength(8));

      final results = await run(config);
      expect(results, hasLength(8));
      // The corpus is deliberately not all-green; a report that shows only
      // green would demonstrate nothing. Three of the corpus's eight cases compare
      // identical (or format-variant) signatures under `riscv_signature`.
      final passing = results.values
          .where((r) => r.status == TestStatus.pass)
          .length;
      expect(passing, 3);
      // The two exit-0 traps must never read as anything but a failure.
      for (final entry in results.entries) {
        expect(
          entry.value.status,
          anyOf(TestStatus.pass, TestStatus.fail),
          reason: '${entry.key}: never unknown, vacuous or timeout',
        );
        expect(
          entry.value.metrics[RiscvArchDriver.kMetricMode],
          'demo',
          reason: '${entry.key}: a demo row must never pass as a real run',
        );
      }
    });

    test('the riscv-formal corpus imports, loads and runs', () async {
      final out = await import(RiscvImportKind.formal, [
        p.absolute(_formalDemoCorpus),
        '--mode',
        'demo',
        '--isa',
        'rv32imc_zicsr',
      ]);
      final config = await _trustingLoader().load(out);
      expect(config.loadWarnings, isEmpty);
      expect(config.suites.expand((s) => s.tests), hasLength(7));

      final results = await run(config);
      expect(results, hasLength(7));
      expect(
        results.values.where((r) => r.status == TestStatus.pass).length,
        2,
      );
      // The four-way PASS / FAIL / UNKNOWN / TIMEOUT distinction plus the
      // two edge cases is exactly what an exit-code reading collapses, and
      // it has to survive an imported config as intact as a hand-written one.
      final verdicts = results.values
          .map((r) => r.metrics[RiscvFormalDriver.kMetricVerdict])
          .toSet();
      expect(verdicts.length, greaterThanOrEqualTo(5));
    });
  });

  test('the CLI reports what it wrote', () async {
    await import(RiscvImportKind.formal, [p.absolute(_formalFixture)]);
    expect(printed.first, contains('wrote'));
    expect(printed.first, contains('6 test(s) across 4 group(s)'));
    // Warnings reach stdout as well as the emitted file's header comment.
    expect(printed.any((l) => l.contains('[multi_task_sby]')), isTrue);
  });
}
