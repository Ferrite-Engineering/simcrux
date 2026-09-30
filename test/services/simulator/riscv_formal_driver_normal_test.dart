// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/riscv_host_platform.dart';
import 'package:simcrux/domain/enums/riscv_run_mode.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/riscv_config.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/job_scheduler/local_job_scheduler.dart';
import 'package:simcrux/services/simulator/riscv_formal_driver.dart';

// `mode: normal`, driven against a scripted launcher so no SymbiYosys is
// needed to test the argv construction, the working-directory override,
// the traceback reduction and the missing-binary guidance
// (VERIFICATION_GUIDE.md §18.3).
//
// The classification TAIL is identical to demo mode's and is covered
// there, end to end through the real scheduler. What is asserted here is
// the part demo mode skips: the spawn.

class _FakeProcess implements TestProcess {
  _FakeProcess({
    this.stdoutLines = const <String>[],
    this.stderrLines = const <String>[],
    this.exit = 0,
  });

  final List<String> stdoutLines;
  final List<String> stderrLines;
  final int exit;

  @override
  Stream<String> get stdout => Stream<String>.fromIterable(stdoutLines);

  @override
  Stream<String> get stderr => Stream<String>.fromIterable(stderrLines);

  @override
  Future<int> get exitCode async => exit;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}

class _Recorder {
  _Recorder({this.process, this.missing = const <String>{}});

  final _FakeProcess? process;
  final Set<String> missing;

  final List<({String executable, List<String> args, String? cwd})> spawns = [];

  Future<TestProcess> launch(
    String executable,
    List<String> args, {
    Map<String, String>? environment,
    String? workingDirectory,
  }) async {
    spawns.add((
      executable: executable,
      args: args,
      cwd: workingDirectory,
    ));
    if (missing.contains(p.basename(executable))) {
      throw ProcessException(executable, args, 'No such file or directory', 2);
    }
    return process ?? _FakeProcess();
  }
}

void main() {
  late Directory workDir;
  late Directory checksDir;

  const passLog = <String>[
    'SBY 11:02:17 [t] engine_0: smtbmc boolector',
    'SBY 11:02:24 [t] engine_0: ## Checking assertions in step 19..',
    'SBY 11:02:24 [t] summary: Elapsed clock time [H:MM:SS]: 0:00:07 (7)',
    'SBY 11:02:24 [t] DONE (PASS, rc=0)',
  ];

  setUp(() {
    workDir = Directory.systemTemp.createTempSync('simcrux_formal_normal_');
    checksDir = Directory(p.join(workDir.path, 'checks'))
      ..createSync(recursive: true);
    File(p.join(checksDir.path, 'insn_add_ch0.sby')).writeAsStringSync('''
[options]
mode bmc
depth 20

[engines]
smtbmc boolector

[script]
read -formal democore.v

[files]
democore.v
''');
  });

  tearDown(() {
    if (workDir.existsSync()) workDir.deleteSync(recursive: true);
  });

  RiscvConfig normalConfig({
    List<String>? command,
    String? sbyBinary,
    String? task,
  }) => RiscvConfig(
    isa: 'rv32imc',
    formal: RiscvFormalConfig(
      checksDir: checksDir.path,
      sbyFile: 'insn_add_ch0.sby',
      check: 'insn_add_ch0',
      command: command,
      sbyBinary: sbyBinary,
      task: task,
    ),
  );

  TestSpec specFor(RiscvConfig cfg) => TestSpec(
    id: 'formal/insn_add_ch0',
    name: 'insn_add_ch0',
    suiteName: 'formal',
    simulatorId: RiscvFormalDriver.kId,
    top: 'insn_add_ch0',
    riscv: cfg,
  );

  ExecuteRequest executeRequest(RiscvConfig cfg) => ExecuteRequest(
    test: specFor(cfg),
    workingDirectory: workDir.path,
    compileResult: null,
    binaryConfig: const SimulatorBinaryConfig(
      simulatorId: RiscvFormalDriver.kId,
    ),
  );

  Future<List<TestExecutionEvent>> execute(
    RiscvFormalDriver driver,
    RiscvConfig cfg,
  ) => driver.execute(executeRequest(cfg)).toList();

  group('identity', () {
    test('claims the bare `riscv_formal` id', () {
      final driver = RiscvFormalDriver();
      expect(driver.id, 'riscv_formal');
      expect(driver.id, isNot(RiscvConfig.kSimulatorId));
    });

    test('declares no HDL languages and no separate compile step', () {
      // `sby` reads HDL, but not from `TestSpec.sources` — the `.sby` job
      // file declares its own `[files]`. Claiming a language set here
      // would make the mixed-language validator police a list this driver
      // never consumes.
      final driver = RiscvFormalDriver();
      expect(driver.capabilities.supportedLanguages, isEmpty);
      expect(driver.capabilities.requiresSeparateCompileStep, isFalse);
      // It CAN hand back a VCD: the counterexample trace.
      expect(driver.capabilities.supportsVcd, isTrue);
    });

    test('compile is a no-op that produces no artifact', () async {
      final result = await RiscvFormalDriver().compile(
        CompileRequest(
          test: specFor(normalConfig()),
          workingDirectory: workDir.path,
          binaryConfig: const SimulatorBinaryConfig(
            simulatorId: RiscvFormalDriver.kId,
          ),
        ),
      );
      expect(result.success, isTrue);
      expect(result.artifactPath, isNull);
    });
  });

  group('the sby command line', () {
    test('is `sby -f -d <task_dir> <sby_file>`', () async {
      final recorder = _Recorder(
        process: _FakeProcess(stdoutLines: passLog),
      );
      await execute(
        RiscvFormalDriver(launcher: recorder.launch),
        normalConfig(),
      );
      final spawn = recorder.spawns.single;
      expect(spawn.executable, 'sby');
      expect(spawn.args.first, '-f');
      expect(spawn.args[1], '-d');
      // `-d` is what puts every artifact — including the counterexample
      // VCD — inside the test's working directory, where the scheduler's
      // retain-on-failure rule protects it.
      expect(spawn.args[2], p.join(workDir.path, 'insn_add_ch0'));
      expect(spawn.args.last, endsWith('insn_add_ch0.sby'));
      expect(p.isAbsolute(spawn.args.last), isTrue);
    });

    test('runs in the checks directory, not in the work directory', () async {
      // riscv-formal's generated jobs reference their sources relative to
      // `checks/`, and its own Makefile runs `sby` from there. Spawning
      // in the work directory instead would break every `[files]` entry.
      final recorder = _Recorder(
        process: _FakeProcess(stdoutLines: passLog),
      );
      await execute(
        RiscvFormalDriver(launcher: recorder.launch),
        normalConfig(),
      );
      expect(recorder.spawns.single.cwd, checksDir.path);
      expect(recorder.spawns.single.cwd, isNot(workDir.path));
    });

    test('appends the task name for a multi-task job file', () async {
      final recorder = _Recorder(
        process: _FakeProcess(stdoutLines: passLog),
      );
      await execute(
        RiscvFormalDriver(launcher: recorder.launch),
        normalConfig(task: 'induction'),
      );
      expect(recorder.spawns.single.args.last, 'induction');
    });

    test('honors an explicit sby binary path', () async {
      final recorder = _Recorder(
        process: _FakeProcess(stdoutLines: passLog),
      );
      await execute(
        RiscvFormalDriver(launcher: recorder.launch),
        normalConfig(sbyBinary: '/opt/oss-cad-suite/bin/sby'),
      );
      expect(
        recorder.spawns.single.executable,
        '/opt/oss-cad-suite/bin/sby',
      );
    });

    test('a command override replaces the derived line entirely', () async {
      final recorder = _Recorder(
        process: _FakeProcess(stdoutLines: passLog),
      );
      await execute(
        RiscvFormalDriver(launcher: recorder.launch),
        normalConfig(
          command: ['./run-proof.sh', '{check}', '{task_dir}', '{sby_file}'],
        ),
      );
      final spawn = recorder.spawns.single;
      expect(spawn.executable, './run-proof.sh');
      expect(spawn.args.first, 'insn_add_ch0');
      expect(spawn.args[1], p.join(workDir.path, 'insn_add_ch0'));
      expect(spawn.args[2], endsWith('insn_add_ch0.sby'));
      expect(spawn.args, isNot(contains('-f')));
    });

    test('an unknown placeholder is left verbatim, not blanked', () async {
      // A typo must surface in the spawned command line and the log
      // rather than silently becoming an empty argument.
      final recorder = _Recorder(
        process: _FakeProcess(stdoutLines: passLog),
      );
      await execute(
        RiscvFormalDriver(launcher: recorder.launch),
        normalConfig(command: ['./run.sh', '{tsak_dir}']),
      );
      expect(recorder.spawns.single.args.single, '{tsak_dir}');
    });
  });

  group('the .sby file is read for what it configured', () {
    test('proof mode and depth reach the metrics', () async {
      final recorder = _Recorder(
        process: _FakeProcess(stdoutLines: passLog),
      );
      final events = await execute(
        RiscvFormalDriver(launcher: recorder.launch),
        normalConfig(),
      );
      final finished = events.whereType<TestExecutionFinished>().single;
      expect(
        finished.metrics[RiscvFormalDriver.kMetricProofMode],
        'bmc',
      );
      expect(
        finished.metrics[RiscvFormalDriver.kMetricDepthConfigured],
        '20',
      );
      expect(
        finished.metrics[RiscvFormalDriver.kMetricDepthReached],
        '19',
      );
    });

    test('an unreadable .sby costs metrics, not the verdict', () async {
      final recorder = _Recorder(
        process: _FakeProcess(stdoutLines: passLog),
      );
      final cfg = RiscvConfig(
        formal: RiscvFormalConfig(
          checksDir: checksDir.path,
          sbyFile: 'not_there.sby',
          check: 'insn_add_ch0',
        ),
      );
      final events = await execute(
        RiscvFormalDriver(launcher: recorder.launch),
        cfg,
      );
      final finished = events.whereType<TestExecutionFinished>().single;
      expect(finished.status, TestStatus.pass);
      expect(
        finished.metrics[RiscvFormalDriver.kMetricDepthConfigured],
        isNull,
      );
    });
  });

  group('the counterexample VCD is resolved from the log', () {
    test('a summary-relative path resolves against the work dir', () async {
      final traceDir = Directory(
        p.join(workDir.path, 'insn_add_ch0', 'engine_0'),
      )..createSync(recursive: true);
      File(p.join(traceDir.path, 'trace.vcd')).writeAsStringSync('$dateLine\n');
      final recorder = _Recorder(
        process: _FakeProcess(
          stdoutLines: const [
            'SBY 11:05:02 [t] engine_0: ## Checking assertions in step 7..',
            summaryTraceLine,
            'SBY 11:05:02 [t] DONE (FAIL, rc=2)',
          ],
          exit: 2,
        ),
      );
      final events = await execute(
        RiscvFormalDriver(launcher: recorder.launch),
        normalConfig(),
      );
      final finished = events.whereType<TestExecutionFinished>().single;
      expect(finished.status, TestStatus.fail);
      expect(finished.waveformPath, p.join(traceDir.path, 'trace.vcd'));
      expect(File(finished.waveformPath!).existsSync(), isTrue);
    });

    test('an engine-relative path resolves against the task dir', () async {
      final traceDir = Directory(
        p.join(workDir.path, 'insn_add_ch0', 'engine_0'),
      )..createSync(recursive: true);
      File(p.join(traceDir.path, 'trace.vcd')).writeAsStringSync('$dateLine\n');
      final recorder = _Recorder(
        process: _FakeProcess(
          stdoutLines: const [
            engineTraceLine,
            'SBY [t] DONE (FAIL, rc=2)',
          ],
          exit: 2,
        ),
      );
      final events = await execute(
        RiscvFormalDriver(launcher: recorder.launch),
        normalConfig(),
      );
      final finished = events.whereType<TestExecutionFinished>().single;
      expect(finished.waveformPath, p.join(traceDir.path, 'trace.vcd'));
    });

    test(
      'a trace that is not on disk is reported as unresolved, not recorded',
      () async {
        // "Debug in WaveCrux" and the CXP producer both open the recorded
        // path. A path that does not exist is worse than an honest
        // absence — so it goes into a metric instead.
        final recorder = _Recorder(
          process: _FakeProcess(
            stdoutLines: const [
              ghostTraceLine,
              'SBY [t] DONE (FAIL, rc=2)',
            ],
            exit: 2,
          ),
        );
        final events = await execute(
          RiscvFormalDriver(launcher: recorder.launch),
          normalConfig(),
        );
        final finished = events.whereType<TestExecutionFinished>().single;
        expect(finished.waveformPath, isNull);
        expect(
          finished.metrics[RiscvFormalDriver.kMetricTraceUnresolved],
          endsWith('ghost.vcd'),
        );
        expect(finished.metrics[RiscvFormalDriver.kMetricTraceCount], '1');
      },
    );
  });

  group('contradictions are failures', () {
    test('PASS with a non-zero exit is a fail', () async {
      final recorder = _Recorder(
        process: _FakeProcess(stdoutLines: passLog, exit: 3),
      );
      final events = await execute(
        RiscvFormalDriver(launcher: recorder.launch),
        normalConfig(),
      );
      final finished = events.whereType<TestExecutionFinished>().single;
      expect(finished.status, TestStatus.fail);
      expect(finished.failureMessage, contains('contradicted'));
    });

    test('a non-PASS verdict never reports exit code 0', () async {
      // `0` is the one value every exit-code-shaped classifier reads as a
      // pass, and a decisive detector overrides the driver.
      final recorder = _Recorder(
        process: _FakeProcess(
          stdoutLines: const ['SBY [t] DONE (UNKNOWN, rc=4)'],
        ),
      );
      final events = await execute(
        RiscvFormalDriver(launcher: recorder.launch),
        normalConfig(),
      );
      final finished = events.whereType<TestExecutionFinished>().single;
      expect(finished.status, TestStatus.fail);
      expect(finished.exitCode, isNull);
      expect(
        finished.metrics[RiscvFormalDriver.kMetricProcessExitCode],
        '0',
      );
    });
  });

  group('SymbiYosys is Python — tracebacks never reach the row', () {
    test('a crash is reduced to its final exception line', () async {
      final recorder = _Recorder(
        process: _FakeProcess(
          stderrLines: const [
            'Traceback (most recent call last):',
            '  File "/usr/local/bin/sby", line 8, in <module>',
            '    sys.exit(main())',
            '  File "/usr/local/lib/sby/sby_core.py", line 412, in run',
            '    p = subprocess.Popen(cmd, shell=True)',
            "FileNotFoundError: [Errno 2] No such file: 'yosys'",
          ],
          exit: 1,
        ),
      );
      final events = await execute(
        RiscvFormalDriver(launcher: recorder.launch),
        normalConfig(),
      );
      final finished = events.whereType<TestExecutionFinished>().single;
      expect(finished.status, TestStatus.fail);
      // The reducer is generic by construction, so the formal driver wires it to the
      // same `onLine` hook rather than writing a second one.
      expect(
        finished.failureMessage,
        "FileNotFoundError: [Errno 2] No such file: 'yosys'",
      );
      // The full trace is not discarded: every line still reached the
      // stream as a log line and lands in the retained stderr log.
      final logged = events
          .whereType<TestLogLine>()
          .map((e) => e.line)
          .toList();
      expect(logged, contains('Traceback (most recent call last):'));
      expect(logged.where((l) => l.startsWith('  File')), hasLength(2));
    });
  });

  group('SymbiYosys missing — detect and guide, never bundle', () {
    test('the failure message is the actionable remediation', () async {
      final recorder = _Recorder(missing: {'sby'});
      final events =
          await RiscvFormalDriver(
                launcher: recorder.launch,
                platform: RiscvHostPlatform.linux,
              )
              .execute(executeRequest(normalConfig()))
              .handleError((Object _) {})
              .toList();
      final finished = events.whereType<TestExecutionFinished>().single;
      expect(finished.failureMessage, contains('SymbiYosys'));
      expect(finished.failureMessage, contains('OSS CAD Suite'));
      expect(
        finished.failureMessage,
        isNot(contains('No such file or directory')),
        reason: 'an errno is not a remediation',
      );
    });

    test('nothing anywhere offers to install or bundle a toolchain', () async {
      for (final platform in RiscvHostPlatform.values) {
        final recorder = _Recorder(missing: {'sby'});
        final events =
            await RiscvFormalDriver(
                  launcher: recorder.launch,
                  platform: platform,
                )
                .execute(executeRequest(normalConfig()))
                .handleError((Object _) {})
                .toList();
        final message = events
            .whereType<TestExecutionFinished>()
            .single
            .failureMessage!;
        expect(message.toLowerCase(), isNot(contains('simcrux will')));
        expect(message.toLowerCase(), isNot(contains('downloading')));
      }
    });
  });

  // `sby -f` deletes the `-d` directory before it runs. The task
  // directory is named after `formal.check`, so a check that joins to
  // anywhere but a child of the work dir would have SymbiYosys delete
  // that directory instead. The loader refuses such a name; this is the
  // second layer, for a config built in code.
  group('the task directory stays inside the work directory', () {
    RiscvConfig withCheck(String? check, {String sbyFile = 'x.sby'}) =>
        RiscvConfig(
          formal: RiscvFormalConfig(
            checksDir: checksDir.path,
            sbyFile: sbyFile,
            check: check,
          ),
        );

    test('a riscv-formal check name is a child of the work dir', () {
      expect(
        RiscvFormalDriver().taskDirectoryFor(
          withCheck('insn_add_ch0'),
          workDir.path,
        ),
        p.join(workDir.path, 'insn_add_ch0'),
      );
    });

    test('with no check, the .sby basename names it', () {
      expect(
        RiscvFormalDriver().taskDirectoryFor(
          withCheck(null, sbyFile: '/elsewhere/sub/reg_ch0.sby'),
          workDir.path,
        ),
        p.join(workDir.path, 'reg_ch0'),
      );
    });

    const escapes = <String>[
      '..',
      '../..',
      '../../victim',
      'sub/../..',
      '.',
      '',
      '/Users/x/Documents',
    ];

    for (final check in escapes) {
      test('check "$check" is refused, never handed to sby -f -d', () {
        final driver = RiscvFormalDriver();
        final cfg = withCheck(check);
        final escapesWorkDir = throwsA(
          isA<ArgumentError>().having(
            (e) => e.message.toString(),
            'message',
            allOf(contains('riscv.formal.check'), contains('sby -f')),
          ),
        );
        expect(
          () => driver.taskDirectoryFor(cfg, workDir.path),
          escapesWorkDir,
        );
        expect(
          () => driver.buildArgv(
            cfg: cfg,
            workingDirectory: workDir.path,
            testName: 't',
          ),
          escapesWorkDir,
        );
      });
    }

    test('a .sby basename of ".." is refused as well', () {
      // `...sby` has the basename `..` once its extension is stripped.
      expect(
        () => RiscvFormalDriver().taskDirectoryFor(
          withCheck(null, sbyFile: '...sby'),
          workDir.path,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message.toString(),
            'message',
            contains('riscv.formal.sby_file'),
          ),
        ),
      );
    });

    test('execute fails the test and spawns nothing', () async {
      final recorder = _Recorder(
        process: _FakeProcess(stdoutLines: passLog),
      );
      final events = await execute(
        RiscvFormalDriver(launcher: recorder.launch),
        withCheck('../..'),
      );
      final finished = events.whereType<TestExecutionFinished>().single;
      expect(recorder.spawns, isEmpty, reason: 'sby must never be started');
      expect(finished.status, TestStatus.fail);
      expect(finished.failureMessage, contains('riscv.formal.check'));
      expect(finished.failureMessage, contains('outside'));
    });

    test('demo mode stages nothing outside the work dir either', () async {
      // Demo replays copy the corpus's traces into the task directory, so
      // the same name would write outside the work dir.
      final corpus = Directory(p.join(workDir.path, 'corpus', 'case'))
        ..createSync(recursive: true);
      File(p.join(corpus.path, 'case.json')).writeAsStringSync(
        '{"traces": ["engine_0/trace.vcd"]}',
      );
      File(p.join(corpus.path, 'engine_0', 'trace.vcd'))
        ..createSync(recursive: true)
        ..writeAsStringSync(dateLine);
      final inner = Directory(p.join(workDir.path, 'inner'))..createSync();
      final cfg = RiscvConfig(
        mode: RiscvRunMode.demo,
        demoCase: 'case',
        formal: RiscvFormalConfig(
          demoOutputs: p.join(workDir.path, 'corpus'),
          check: '..',
        ),
      );
      final events = await RiscvFormalDriver()
          .execute(
            ExecuteRequest(
              test: specFor(cfg),
              workingDirectory: inner.path,
              compileResult: null,
              binaryConfig: const SimulatorBinaryConfig(
                simulatorId: RiscvFormalDriver.kId,
              ),
            ),
          )
          .toList();
      final finished = events.whereType<TestExecutionFinished>().single;
      expect(finished.status, TestStatus.fail);
      expect(
        File(p.join(workDir.path, 'engine_0', 'trace.vcd')).existsSync(),
        isFalse,
        reason: 'a trace was staged into the parent of the work dir',
      );
    });
  });

  group('a misconfigured spec fails loudly', () {
    test('no sby file and no command override', () async {
      // The loader refuses this, so reaching the driver means a
      // programmatically-built spec — and it must not report green.
      final recorder = _Recorder();
      final events = await execute(
        RiscvFormalDriver(launcher: recorder.launch),
        const RiscvConfig(),
      );
      final finished = events.whereType<TestExecutionFinished>().single;
      expect(finished.status, TestStatus.fail);
      expect(finished.failureMessage, contains('riscv.formal.sby_file'));
      expect(recorder.spawns, isEmpty);
    });
  });
}

const String dateLine = r'$date Feb 01 2026 $end';

/// `sby`'s own final word, spelled relative to its invocation directory.
const String summaryTraceLine =
    'SBY [t] summary: counterexample trace: '
    'insn_add_ch0/engine_0/trace.vcd';

/// The engine's spelling, relative to the task directory.
const String engineTraceLine =
    'SBY [t] engine_0: ## Writing trace to VCD file: '
    'engine_0/trace.vcd';

/// A trace `sby` announced that is not on disk.
const String ghostTraceLine =
    'SBY [t] summary: counterexample trace: '
    'insn_add_ch0/engine_0/ghost.vcd';
