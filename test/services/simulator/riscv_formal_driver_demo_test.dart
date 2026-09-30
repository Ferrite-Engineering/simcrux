// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/riscv_run_mode.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/job_scheduler.dart';
import 'package:simcrux/domain/models/pass_fail_config.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/regression_request.dart';
import 'package:simcrux/domain/models/riscv_config.dart';
import 'package:simcrux/domain/models/sby_outcome.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/job_scheduler/local_job_scheduler.dart';
import 'package:simcrux/services/simulator/riscv_formal_driver.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';

// Demo mode, driven through the REAL `LocalJobScheduler` and the REAL
// `RiscvFormalDriver` (VERIFICATION_GUIDE.md §18.3).
//
// Same design argument as the `riscv_arch` demo and the same reason it matters: an
// env-gated *separate* driver (the `SIMCRUX_DEMO_RUNNER` /
// `DemoSimulatorDriver` pattern) would make CI exercise a different code
// path than production, which is the one thing demo mode must not do. Only
// the spawn is skipped — the captured log is fed line by line into the
// same `SbyLogReader`, every line still reaches the stream as a
// `TestLogLine` so the `string_match` detector sees the text it would see
// in production, and the terminal event is built by the same
// `buildTerminalEvent`. So the assertions below are evidence about the
// production path.
//
// MUTATION: make the driver classify from the exit code instead of the
// verdict and `liveness_no_outcome reports fail` fails — that mutation is
// the exit-0 trap in its formal form, and that fixture exits 0.

const String _corpus = 'verification/fixtures/riscv_formal';

void main() {
  late Directory runRoot;

  setUp(() {
    runRoot = Directory.systemTemp.createTempSync('simcrux_formal_demo_');
  });

  tearDown(() {
    if (runRoot.existsSync()) runRoot.deleteSync(recursive: true);
  });

  List<String> corpusCases() =>
      Directory(_corpus)
          .listSync()
          .whereType<Directory>()
          .map((d) => p.basename(d.path))
          .toList()
        ..sort();

  Map<String, Object?> caseJson(String caseName) =>
      jsonDecode(
            File(p.join(_corpus, caseName, 'case.json')).readAsStringSync(),
          )
          as Map<String, Object?>;

  Map<String, Object?> expectedFor(String caseName) =>
      jsonDecode(
            File(p.join(_corpus, caseName, 'expected.json')).readAsStringSync(),
          )
          as Map<String, Object?>;

  TestSpec demoSpec(String caseName, {String? group}) {
    final decl = caseJson(caseName);
    return TestSpec(
      id: 'formal/$caseName',
      name: caseName,
      suiteName: 'formal',
      simulatorId: RiscvFormalDriver.kId,
      top: caseName,
      timeout: const Duration(seconds: 30),
      // Exactly what the importer emits. A required pass string that
      // never appears is a FAIL by the detector's own documented
      // semantics — never an `unknown` that would fall back to the
      // driver's exit code. The literal is the parser's own constant.
      passFail: const StringMatchPassFailConfig(
        passString: SbyLogReader.kPassMarker,
      ),
      riscv: RiscvConfig(
        isa: 'rv32imc_zicsr',
        mode: RiscvRunMode.demo,
        demoCase: caseName,
        formal: RiscvFormalConfig(
          demoOutputs: p.absolute(_corpus),
          check: decl['check'] as String?,
          group: group,
        ),
      ),
    );
  }

  Future<Map<String, TestResult>> run(
    List<TestSpec> specs, {
    bool retainWorkDirs = false,
  }) async {
    final driver = RiscvFormalDriver();
    final scheduler = LocalJobScheduler(
      driverRegistry: SimulatorDriverRegistry({driver.id: driver}),
      config: RegressionConfig(
        projectFilePath: '/fake/simcrux.yaml',
        schemaVersion: '1',
        suites: const [],
        simulatorBinaries: const {},
      ),
      runRoot: runRoot.path,
      retainSuccessfulWorkDirs: retainWorkDirs,
    );
    final events = await scheduler
        .submit(RegressionRequest(runId: 'r1', tests: specs))
        .toList();
    return {
      for (final f in events.whereType<TestFinished>())
        f.result.testId: f.result,
    };
  }

  group('the whole flow, with no SymbiYosys present', () {
    test('every committed case replays to its committed verdict', () async {
      final cases = corpusCases();
      expect(
        cases,
        containsAll(<String>[
          'insn_add_pass',
          'insn_sub_counterexample',
          'pc_fwd_unknown',
          'reg_timeout',
          'causal_error',
          'liveness_no_outcome',
          'cover_multi_trace',
        ]),
        reason:
            'the §18.3 required case list — a case disappearing silently '
            'narrows this coverage',
      );
      final results = await run(cases.map(demoSpec).toList());
      for (final caseName in cases) {
        final expected = expectedFor(caseName);
        expect(
          results['formal/$caseName']!.status.name,
          expected['status'],
          reason: 'case $caseName',
        );
        expect(
          results['formal/$caseName']!.metrics[RiscvFormalDriver
              .kMetricVerdict],
          expected['verdict'],
          reason: 'case $caseName verdict',
        );
      }
    });

    test('no subprocess is spawned — the driver never touches PATH', () async {
      // The strongest available statement of "no SymbiYosys needed": the
      // driver is constructed with a launcher that throws if it is ever
      // asked to spawn anything.
      final driver = RiscvFormalDriver(
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
            RegressionRequest(runId: 'r1', tests: [demoSpec('insn_add_pass')]),
          )
          .toList();
      expect(
        events.whereType<TestFinished>().single.result.status,
        TestStatus.pass,
      );
    });

    test('a clean proof really passes', () async {
      final results = await run([demoSpec('insn_add_pass')]);
      expect(results['formal/insn_add_pass']!.status, TestStatus.pass);
      expect(results['formal/insn_add_pass']!.failureMessage, isNull);
    });
  });

  group('the status traps — an unproven property is not a pass', () {
    test('NO_OUTCOME on an exit-0 run reports fail', () async {
      // The sharpest case in the corpus: the log ends before any
      // `DONE (…)` line and the process exits 0. Classifying from the
      // exit code reports a proof that never happened as green.
      final result = (await run([
        demoSpec('liveness_no_outcome'),
      ])).values.single;
      expect(caseJson('liveness_no_outcome')['exit_code'], 0);
      expect(result.status, TestStatus.fail);
      expect(result.status, isNot(TestStatus.pass));
      expect(result.status, isNot(TestStatus.unknown));
      expect(result.status, isNot(TestStatus.vacuous));
      expect(result.failureMessage, contains('no verdict'));
    });

    test('UNKNOWN reports fail and says so honestly', () async {
      final result = (await run([demoSpec('pc_fwd_unknown')])).values.single;
      expect(result.status, TestStatus.fail);
      expect(result.status, isNot(TestStatus.vacuous));
      expect(result.failureMessage, contains('inconclusive'));
      expect(result.failureMessage, isNot(contains('pass')));
      expect(
        result.metrics[RiscvFormalDriver.kMetricVerdict],
        'UNKNOWN',
        reason: 'the distinction survives in the metric, not in the status',
      );
    });

    test(
      "sby's own TIMEOUT reports fail, not TestStatus.timeout",
      () async {
        // `TestStatus.timeout` means SimCrux killed the job. Conflating
        // the two makes one dashboard filter mean two things.
        final result = (await run([demoSpec('reg_timeout')])).values.single;
        expect(result.status, TestStatus.fail);
        expect(result.status, isNot(TestStatus.timeout));
        expect(result.metrics[RiscvFormalDriver.kMetricVerdict], 'TIMEOUT');
      },
    );

    test('ERROR reports fail and surfaces sby own error line', () async {
      final result = (await run([demoSpec('causal_error')])).values.single;
      expect(result.status, TestStatus.fail);
      expect(result.failureMessage, contains("Can't open input file"));
    });

    test(
      'the trap stays closed under the DEFAULT exit-code detector',
      () async {
        // A `TestSpec` with no `pass_fail:` block gets
        // `ExitCodePassFailConfig`, and a decisive detector overrides the
        // driver. `liveness_no_outcome` exits **0**, so an honest exit
        // code here would report a proof that never happened as green no
        // matter how carefully the driver classified it. The driver
        // therefore withholds a 0 that contradicts its verdict, and keeps
        // it in a metric instead.
        final results = await run([
          TestSpec(
            id: 'formal/default_detector',
            name: 'liveness_no_outcome',
            suiteName: 'formal',
            simulatorId: RiscvFormalDriver.kId,
            top: 'liveness_no_outcome',
            timeout: const Duration(seconds: 30),
            riscv: RiscvConfig(
              mode: RiscvRunMode.demo,
              demoCase: 'liveness_no_outcome',
              formal: RiscvFormalConfig(demoOutputs: p.absolute(_corpus)),
            ),
          ),
        ]);
        final result = results['formal/default_detector']!;
        expect(result.status, TestStatus.fail);
        expect(result.exitCode, isNull);
        expect(
          result.metrics[RiscvFormalDriver.kMetricProcessExitCode],
          '0',
          reason: 'withheld, not discarded',
        );
      },
    );

    test('a passing run reports its exit code normally', () async {
      final result = (await run([demoSpec('insn_add_pass')])).values.single;
      expect(result.exitCode, 0);
      expect(
        result.metrics[RiscvFormalDriver.kMetricProcessExitCode],
        isNull,
      );
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

    test('the detector and the driver agree on every case', () async {
      // They key off the same literal — `SbyLogReader.kPassMarker` — so
      // this is agreement by construction, and the assertion is the
      // regression guard for it. The final status IS the detector's,
      // because a decisive detector wins over the driver.
      final results = await run(corpusCases().map(demoSpec).toList());
      for (final caseName in corpusCases()) {
        final log = File(p.join(_corpus, caseName, 'sby.log'));
        // The existence check is an assertion, not a guard clause. Folding
        // "the log is missing" into "it does not contain the pass marker"
        // makes both halves of this comparison degrade together: the
        // driver reports NO_OUTCOME → fail, this side computes
        // passes == false, and the two agree — on nothing.
        expect(
          log.existsSync(),
          isTrue,
          reason: '$caseName: sby.log is not on disk (is it committed?)',
        );
        final passes = log.readAsStringSync().contains(
          SbyLogReader.kPassMarker,
        );
        expect(
          results['formal/$caseName']!.status,
          passes ? TestStatus.pass : TestStatus.fail,
          reason: caseName,
        );
      }
    });
  });

  group('the counterexample VCD — the hand-off to WaveCrux', () {
    test('a failing proof records an absolute, existing VCD path', () async {
      final result = (await run([
        demoSpec('insn_sub_counterexample'),
      ])).values.single;
      expect(result.status, TestStatus.fail);
      final path = result.waveformPath;
      expect(
        path,
        isNotNull,
        reason: 'this is what the hand-off gives WaveCrux',
      );
      expect(p.isAbsolute(path!), isTrue);
      expect(File(path).existsSync(), isTrue);
      expect(p.extension(path), '.vcd');
    });

    test(
      'the VCD survives on disk — the scheduler sweeps only SUCCESSFUL '
      'work dirs',
      () async {
        // Load-bearing for the hand-off: `_maybeCleanup` returns early unless
        // the run succeeded, so a failing proof's evidence is still there
        // when the Pro dashboard or the CXP producer asks for it. If
        // UNKNOWN or TIMEOUT ever became `vacuous`, this file would be
        // deleted — which is half of why they are `fail`.
        final result = (await run([
          demoSpec('insn_sub_counterexample'),
        ])).values.single;
        final path = result.waveformPath!;
        expect(File(path).existsSync(), isTrue);
        expect(
          path,
          contains(runRoot.path),
          reason: "it lives in the scheduler's work dir, not in the corpus",
        );
      },
    );

    test('the VCD reaches the result unchanged — no new field needed', () {
      // `TestExecutionFinished.waveformPath` → `TestResult.waveformPath`
      // already round-trips NDJSON as `waveform_path`, so the CXP
      // producer's existing coordinate is the one that carries it.
      expect(
        TestResult(
          testId: 't',
          runId: 'r',
          status: TestStatus.fail,
          startedAt: DateTime.now(),
          finishedAt: DateTime.now(),
          waveformPath: '/tmp/trace.vcd',
        ).waveformPath,
        '/tmp/trace.vcd',
      );
    });

    test('a passing proof records no counterexample', () async {
      final result = (await run([demoSpec('insn_add_pass')])).values.single;
      expect(result.waveformPath, isNull);
      expect(
        result.metrics[RiscvFormalDriver.kMetricTraceCount],
        isNull,
      );
    });

    test('a cover run reports every trace it announced', () async {
      final results = await run([
        demoSpec('cover_multi_trace'),
      ], retainWorkDirs: true);
      final result = results.values.single;
      expect(result.status, TestStatus.pass);
      expect(result.metrics[RiscvFormalDriver.kMetricTraceCount], '2');
      // Retained work dirs mean the path is left in place rather than
      // archived or dropped, so it still resolves.
      expect(File(result.waveformPath!).existsSync(), isTrue);
    });

    test(
      "a passing run's path is dropped rather than left dangling",
      () async {
        // The scheduler sweeps a successful work dir and, with no
        // waveform archive configured, drops the path instead of
        // recording one that points at a deleted file. That existing rule
        // is why this driver hands the path over rather than
        // special-casing the pass case.
        final result = (await run([
          demoSpec('cover_multi_trace'),
        ])).values.single;
        expect(result.waveformPath, isNull);
        expect(result.metrics[RiscvFormalDriver.kMetricTraceCount], '2');
      },
    );
  });

  group('per-property metrics', () {
    test('verdict, depth and wall time all reach TestResult', () async {
      final result = (await run([demoSpec('insn_add_pass')])).values.single;
      final metrics = result.metrics;
      final expected = expectedFor('insn_add_pass');
      expect(metrics[RiscvFormalDriver.kMetricVerdict], 'PASS');
      expect(
        metrics[RiscvFormalDriver.kMetricDepthReached],
        '${expected['depth_reached']}',
      );
      expect(metrics[RiscvFormalDriver.kMetricDepthConfigured], '20');
      expect(
        metrics[RiscvFormalDriver.kMetricWallTimeMs],
        '${(expected['elapsed_seconds']! as int) * 1000}',
      );
      expect(metrics[RiscvFormalDriver.kMetricProofMode], 'bmc');
      expect(metrics[RiscvFormalDriver.kMetricEngine], 'smtbmc boolector');
      expect(metrics[RiscvFormalDriver.kMetricReturnCode], '0');
    });

    test(
      'the wall time is attributed to the engine, not to a stopwatch',
      () async {
        // A stopwatch in demo mode would report how long it took to read
        // a file. An exported report must be able to say which number it
        // is looking at.
        final result = (await run([demoSpec('insn_add_pass')])).values.single;
        expect(
          result.metrics[RiscvFormalDriver.kMetricWallTimeSource],
          'engine',
        );
      },
    );

    test('a log with no elapsed line falls back to a measured time', () async {
      final result = (await run([
        demoSpec('liveness_no_outcome'),
      ])).values.single;
      expect(
        result.metrics[RiscvFormalDriver.kMetricWallTimeSource],
        'measured',
      );
      expect(result.metrics[RiscvFormalDriver.kMetricWallTimeMs], isNotNull);
    });

    test('the group tag rides into metrics for the Pro rollup', () async {
      final result = (await run([demoSpec('pc_fwd_unknown')])).values.single;
      expect(result.metrics[RiscvFormalDriver.kMetricGroup], 'pc_fwd');
      expect(result.metrics[RiscvFormalDriver.kMetricCheck], 'pc_fwd_ch0');
      expect(result.metrics[RiscvFormalDriver.kMetricChannel], '0');
      expect(result.metrics[RiscvFormalDriver.kMetricIsa], 'rv32imc_zicsr');
    });

    test('an explicit group tag wins — the user owns the YAML', () async {
      final result = (await run([
        demoSpec('insn_add_pass', group: 'arithmetic'),
      ])).values.single;
      expect(result.metrics[RiscvFormalDriver.kMetricGroup], 'arithmetic');
    });

    test(
      'the mode is recorded so a demo row cannot pass as a real proof',
      () async {
        final result = (await run([demoSpec('insn_add_pass')])).values.single;
        expect(result.metrics[RiscvFormalDriver.kMetricMode], 'demo');
      },
    );

    test(
      'metrics survive to TestResult, which only the driver feeds',
      () async {
        // `TestResult.metrics` is fed solely from
        // `TestExecutionFinished.metrics`; a detector structurally cannot
        // write them. These arriving on the result IS the proof that the
        // driver emitted them.
        final result = (await run([
          demoSpec('insn_sub_counterexample'),
        ])).values.single;
        expect(result.metrics[RiscvFormalDriver.kMetricVerdict], 'FAIL');
        expect(result.metrics[RiscvFormalDriver.kMetricDepthReached], '7');
        expect(result.metrics[RiscvFormalDriver.kMetricTraceCount], '1');
      },
    );
  });

  group('failure messages are dashboard-row sized', () {
    test('a counterexample names the step and the check', () async {
      final message = (await run([
        demoSpec('insn_sub_counterexample'),
      ])).values.single.failureMessage!;
      expect(message, contains('counterexample'));
      expect(message, contains('insn_sub_ch0'));
      expect(message, contains('step 7'));
      expect(message, isNot(contains('\n')));
      expect(message.length, lessThan(160));
    });

    test('every failure message is one line', () async {
      final results = await run(corpusCases().map(demoSpec).toList());
      for (final entry in results.entries) {
        final message = entry.value.failureMessage;
        if (message == null) continue;
        expect(message, isNot(contains('\n')), reason: entry.key);
      }
    });
  });

  group('demo mode is config-declared, not environment-gated', () {
    test('the driver id is the ordinary one, not a demo variant', () {
      expect(RiscvFormalDriver.kId, 'riscv_formal');
      expect(RiscvFormalDriver.kId, RiscvConfig.kFormalSimulatorId);
    });

    test('the captured log still streams as ordinary log lines', () async {
      // Not cosmetic: it is how the `string_match` detector sees the same
      // text in demo mode that it sees in production.
      final driver = RiscvFormalDriver();
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
            RegressionRequest(runId: 'r1', tests: [demoSpec('insn_add_pass')]),
          )
          .toList();
      final lines = events.whereType<TestLog>().map((e) => e.line).toList();
      expect(lines.any((l) => l.contains(SbyLogReader.kPassMarker)), isTrue);
      expect(lines.any((l) => l.contains('mode=demo')), isTrue);
    });

    test('a spec with no riscv block at all does not silently pass', () async {
      // Defaults to `mode: normal`, which the loader refuses — but a
      // programmatically-built spec can still reach the driver, and it
      // must fail loudly rather than report green.
      final results = await run([
        TestSpec(
          id: 'formal/naked',
          name: 'naked',
          suiteName: 'formal',
          simulatorId: RiscvFormalDriver.kId,
          top: 'naked',
          timeout: const Duration(seconds: 30),
        ),
      ]);
      expect(results['formal/naked']!.status, isNot(TestStatus.pass));
      expect(results['formal/naked']!.status, isNot(TestStatus.vacuous));
    });

    test('a demo spec with no corpus fails rather than passing', () async {
      final results = await run([
        TestSpec(
          id: 'formal/nocorpus',
          name: 'nocorpus',
          suiteName: 'formal',
          simulatorId: RiscvFormalDriver.kId,
          top: 'nocorpus',
          timeout: const Duration(seconds: 30),
          riscv: const RiscvConfig(mode: RiscvRunMode.demo),
        ),
      ]);
      expect(results['formal/nocorpus']!.status, TestStatus.fail);
    });
  });

  group('the corpus manifest cannot reach outside its directories', () {
    // `case.json` travels with a shared project, so every name in it is an
    // untrusted string. Before this the trace names were joined onto the task
    // directory and written wherever they pointed — `../` walked out of the
    // run root, and an absolute path won outright.
    late Directory corpusRoot;

    setUp(() {
      corpusRoot = Directory.systemTemp.createTempSync(
        'simcrux_formal_corpus_',
      );
    });

    tearDown(() {
      if (corpusRoot.existsSync()) corpusRoot.deleteSync(recursive: true);
    });

    /// A corpus case named [caseName] whose `case.json` is [manifest], with
    /// the committed `insn_add_pass` log beside it unless [log] says otherwise.
    Directory corpusCase(
      String caseName,
      Map<String, Object?> manifest, {
      String? log,
    }) {
      final dir = Directory(p.join(corpusRoot.path, caseName))
        ..createSync(recursive: true);
      File(
        p.join(dir.path, 'case.json'),
      ).writeAsStringSync(jsonEncode(manifest));
      File(p.join(dir.path, 'sby.log')).writeAsStringSync(
        log ??
            File(
              p.join(_corpus, 'insn_add_pass', 'sby.log'),
            ).readAsStringSync(),
      );
      return dir;
    }

    TestSpec specFor(String caseName) => TestSpec(
      id: 'formal/$caseName',
      name: caseName,
      suiteName: 'formal',
      simulatorId: RiscvFormalDriver.kId,
      top: caseName,
      timeout: const Duration(seconds: 30),
      passFail: const StringMatchPassFailConfig(
        passString: SbyLogReader.kPassMarker,
      ),
      riscv: RiscvConfig(
        isa: 'rv32imc_zicsr',
        mode: RiscvRunMode.demo,
        demoCase: caseName,
        formal: RiscvFormalConfig(
          demoOutputs: corpusRoot.path,
          check: 'insn_add_ch0',
        ),
      ),
    );

    Future<List<RegressionEvent>> runWithEvents(TestSpec spec) {
      final driver = RiscvFormalDriver();
      final scheduler = LocalJobScheduler(
        driverRegistry: SimulatorDriverRegistry({driver.id: driver}),
        config: RegressionConfig(
          projectFilePath: '/fake/simcrux.yaml',
          schemaVersion: '1',
          suites: const [],
          simulatorBinaries: const {},
        ),
        runRoot: runRoot.path,
        retainSuccessfulWorkDirs: true,
      );
      return scheduler
          .submit(RegressionRequest(runId: 'r1', tests: [spec]))
          .toList();
    }

    List<String> filesNamed(Directory root, String name) => root
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => p.basename(f.path) == name)
        .map((f) => f.path)
        .toList();

    test('a trace name that escapes is refused, not staged', () async {
      // Two escapes and one honest trace. The honest one must still be
      // staged — refusing everything would be a fix that also removes the
      // feature.
      final escapedSource = File(p.join(corpusRoot.path, 'escaped.vcd'))
        ..writeAsStringSync('outside the case');
      final absoluteSource = File(p.join(runRoot.path, 'absolute.vcd'))
        ..writeAsStringSync('outside the task directory');
      final caseDir = corpusCase('escape', <String, Object?>{
        'log': 'sby.log',
        'traces': <String>[
          '../escaped.vcd',
          absoluteSource.path,
          'engine_0/trace.vcd',
        ],
        'exit_code': 0,
      });
      File(p.join(caseDir.path, 'engine_0', 'trace.vcd'))
        ..createSync(recursive: true)
        ..writeAsStringSync('honest');

      final events = await runWithEvents(specFor('escape'));
      final lines = events.whereType<TestLog>().map((e) => e.line).toList();

      expect(
        filesNamed(runRoot, 'escaped.vcd'),
        isEmpty,
        reason: '`../escaped.vcd` must not be written next to the task dir',
      );
      expect(
        absoluteSource.readAsStringSync(),
        'outside the task directory',
        reason: 'an absolute trace must not be written back over itself',
      );
      expect(escapedSource.readAsStringSync(), 'outside the case');
      expect(
        filesNamed(runRoot, 'trace.vcd'),
        hasLength(1),
        reason: 'the honest trace inside the case is still staged',
      );
      expect(
        lines.where((l) => l.contains('refused to stage demo trace')),
        hasLength(2),
      );
      expect(
        lines.any(
          (l) => l.contains('refused to stage demo trace "../escaped.vcd"'),
        ),
        isTrue,
      );
    });

    test('a log name that escapes reads nothing', () async {
      // The same string in the `log` slot would have streamed any file on the
      // machine into the run as SymbiYosys output. A passing log outside the
      // case must not turn into a pass.
      File(p.join(corpusRoot.path, 'outside.log')).writeAsStringSync(
        File(p.join(_corpus, 'insn_add_pass', 'sby.log')).readAsStringSync(),
      );
      corpusCase(
        'escape_log',
        <String, Object?>{'log': '../outside.log', 'traces': <String>[]},
        log: 'no verdict here',
      );

      final events = await runWithEvents(specFor('escape_log'));
      final lines = events.whereType<TestLog>().map((e) => e.line).toList();
      final result = events.whereType<TestFinished>().single.result;

      expect(lines.any((l) => l.contains(SbyLogReader.kPassMarker)), isFalse);
      expect(result.status, isNot(TestStatus.pass));
    });
  });
}
