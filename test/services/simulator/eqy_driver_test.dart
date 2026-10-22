// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/job_scheduler.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/formal_config.dart';
import 'package:simcrux/domain/models/pass_fail_config.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/regression_request.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/job_scheduler/local_job_scheduler.dart';
import 'package:simcrux/services/simulator/eqy_driver.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';
import 'package:simcrux/services/simulator/simulator_not_available_exception.dart';

import '../../support/eqy_workdir_fixture.dart';

// The eqy driver against a scripted launcher that plays eqy from the
// committed corpus: the command line, refusals before spawn, the verdict
// through the real scheduler, each partition on the row, the counterexample,
// and the exit-code rule. The live run against a real eqy is
// test/integration/eqy_driver_live_test.dart.

class _FakeProcess implements TestProcess {
  _FakeProcess({this.stdoutLines = const <String>[], this.exit = 0});

  final List<String> stdoutLines;
  final int exit;

  @override
  Stream<String> get stdout => Stream<String>.fromIterable(stdoutLines);

  @override
  Stream<String> get stderr => const Stream<String>.empty();

  @override
  Future<int> get exitCode async => exit;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}

class _Recorder {
  _Recorder({this.run, this.exit, this.missing = false});

  /// The corpus run to play, or null to leave the work directory empty.
  final String? run;
  final int? exit;
  final bool missing;

  final List<({String executable, List<String> args, String? cwd})> spawns = [];

  Future<TestProcess> launch(
    String executable,
    List<String> args, {
    Map<String, String>? environment,
    String? workingDirectory,
  }) async {
    spawns.add((executable: executable, args: args, cwd: workingDirectory));
    if (missing) {
      throw ProcessException(executable, args, 'No such file or directory', 2);
    }
    final run = this.run;
    if (run == null) return _FakeProcess(exit: exit ?? 1);
    stageEqyWorkdir(run, args[args.indexOf('-d') + 1]);
    return _FakeProcess(
      stdoutLines: capturedEqyLog(run),
      exit: exit ?? capturedEqyExit(run),
    );
  }
}

void main() {
  late Directory root;
  late Directory workDir;
  late String project;

  setUp(() {
    root = Directory.systemTemp.createTempSync('simcrux_eqy_driver_');
    workDir = Directory(p.join(root.path, 'work'))..createSync();
    project = Directory(p.join(root.path, 'project')).path;
    Directory(project).createSync();
    for (final f in Directory(eqyCorpus).listSync().whereType<File>()) {
      if (f.path.endsWith('.eqy') || f.path.endsWith('.v')) {
        f.copySync(p.join(project, p.basename(f.path)));
      }
    }
  });
  tearDown(() => root.deleteSync(recursive: true));

  String eqy(String run) => p.join(project, '$run.eqy');

  TestSpec spec(FormalConfig formal, {PassFailConfig? passFail}) => TestSpec(
    id: 'eqy/t',
    name: 't',
    suiteName: 'eqy',
    simulatorId: EqyDriver.kId,
    top: 't',
    passFail: passFail ?? const ExitCodePassFailConfig(),
    formal: formal,
  );

  ExecuteRequest request(FormalConfig formal) => ExecuteRequest(
    test: spec(formal),
    workingDirectory: workDir.path,
    compileResult: null,
    binaryConfig: const SimulatorBinaryConfig(simulatorId: EqyDriver.kId),
  );

  Future<TestExecutionFinished> finished(
    EqyDriver driver,
    ExecuteRequest req,
  ) async => (await driver.execute(req).toList())
      .whereType<TestExecutionFinished>()
      .single;

  group('identity', () {
    test('claims `eqy` and declares no HDL languages', () {
      final driver = EqyDriver();
      expect(driver.id, 'eqy');
      expect(driver.capabilities.supportedLanguages, isEmpty);
    });
  });

  group('the command line', () {
    test(
      'is `eqy -f -d <work>/<file name> <file.eqy>` beside the file',
      () async {
        final recorder = _Recorder(run: 'alu_pass2');
        await finished(
          EqyDriver(launcher: recorder.launch),
          request(FormalConfig(eqyFile: eqy('alu_pass2'))),
        );
        final spawn = recorder.spawns.single;
        expect(spawn.executable, 'eqy');
        expect(spawn.args, [
          '-f',
          '-d',
          p.join(workDir.path, 'alu_pass2'),
          eqy('alu_pass2'),
        ]);
        expect(spawn.cwd, project);
      },
    );

    test('passes only the tool options eqy takes, and the binary', () async {
      final recorder = _Recorder(run: 'alu_pass2');
      final events = await EqyDriver(launcher: recorder.launch)
          .execute(
            request(
              FormalConfig(
                eqyFile: eqy('alu_pass2'),
                eqyBinary: '/opt/suite/bin/eqy',
                tools: const {'yosys': '/opt/y', 'witness': '/opt/w'},
                extraArgs: const ['-j', '4'],
              ),
            ),
          )
          .toList();
      final spawn = recorder.spawns.single;
      expect(spawn.executable, '/opt/suite/bin/eqy');
      expect(spawn.args.sublist(3), [
        '--yosys',
        '/opt/y',
        '-j',
        '4',
        eqy('alu_pass2'),
      ]);
      expect(
        events.whereType<TestLogLine>().map((l) => l.line),
        contains(contains('formal.tools.witness')),
      );
    });

    test('the command override expands its placeholders', () async {
      final recorder = _Recorder(run: 'alu_pass2');
      await finished(
        EqyDriver(launcher: recorder.launch),
        request(
          FormalConfig(
            eqyFile: eqy('alu_pass2'),
            command: const ['wrap', '{eqy_file}', '{task_dir}'],
          ),
        ),
      );
      expect(recorder.spawns.single.executable, 'wrap');
      expect(recorder.spawns.single.args, [
        eqy('alu_pass2'),
        p.join(workDir.path, 'alu_pass2'),
      ]);
    });
  });

  group('refused before anything is spawned', () {
    Future<void> refused(FormalConfig cfg, Matcher message) async {
      final recorder = _Recorder(run: 'alu_pass2');
      final result = await finished(
        EqyDriver(launcher: recorder.launch),
        request(cfg),
      );
      expect(recorder.spawns, isEmpty);
      expect(result.status, TestStatus.fail);
      expect(result.exitCode, isNull);
      expect(result.failureMessage, message);
    }

    for (final arg in const [
      '-d',
      '-dother',
      '-f',
      '--force',
      '-b',
      '-t',
      '-c',
      '--continue',
      '--setup',
      '-m',
      '-P',
      '--purge=x',
      '-p',
      '--init-config-file',
    ]) {
      test('extra_args $arg', () async {
        await refused(
          FormalConfig(eqyFile: eqy('alu_pass2'), extraArgs: [arg]),
          contains('may not pass $arg'),
        );
      });
    }

    for (final name in const ['bad:name', 'two\nlines']) {
      test('a file name that cannot name the work dir: "$name"', () async {
        await refused(
          FormalConfig(eqyFile: p.join(project, '$name.eqy')),
          contains('cannot name the EQY work directory'),
        );
      });
    }

    test('demo mode', () async {
      await refused(
        FormalConfig(eqyFile: eqy('alu_pass2'), mode: FormalRunMode.demo),
        contains('not available for the eqy driver'),
      );
    });

    test('no eqy_file', () async {
      await refused(
        const FormalConfig(),
        contains('`formal.eqy_file` is required'),
      );
    });

    test('VHDL through the GHDL Yosys plugin', () async {
      final file = File(p.join(project, 'vhdl.eqy'))
        ..writeAsStringSync(
          '[gold]\nghdl --std=08 alu.vhd -e alu\nprep -top alu\n'
          '[gate]\nread_verilog gate.v\n[strategy sby]\nuse sby\n',
        );
      await refused(
        FormalConfig(eqyFile: file.path),
        allOf(contains('GHDL Yosys plugin'), contains('--synth')),
      );
    });
  });

  test('a missing eqy is "not available", never a verdict', () async {
    final events = <Object>[];
    final done = Completer<void>();
    EqyDriver(launcher: _Recorder(missing: true).launch)
        .execute(request(FormalConfig(eqyFile: eqy('alu_pass2'))))
        .listen(events.add, onError: events.add, onDone: done.complete);
    await done.future;
    expect(events.whereType<SimulatorNotAvailableException>(), hasLength(1));
    final last = events.whereType<TestExecutionFinished>().single;
    expect(last.status, TestStatus.unknown);
    expect(last.failureMessage, contains('Settings → Engines'));
  });

  group('the verdict, through the real scheduler', () {
    Future<TestResult> run(
      String corpus, {
      int? exit,
      PassFailConfig? passFail,
    }) async {
      final runRoot = Directory(p.join(root.path, 'runs-$corpus'))
        ..createSync();
      final scheduler = LocalJobScheduler(
        driverRegistry: SimulatorDriverRegistry({
          EqyDriver.kId: EqyDriver(
            launcher: _Recorder(
              run: corpus == 'none' ? null : corpus,
              exit: exit,
            ).launch,
          ),
        }),
        config: RegressionConfig(
          projectFilePath: '/p/simcrux.yaml',
          schemaVersion: '1',
          suites: const [],
          simulatorBinaries: const {},
        ),
        runRoot: runRoot.path,
        retainSuccessfulWorkDirs: true,
      );
      final events = await scheduler
          .submit(
            RegressionRequest(
              runId: 'r',
              tests: [
                spec(FormalConfig(eqyFile: eqy(corpus)), passFail: passFail),
              ],
            ),
          )
          .toList();
      return events.whereType<TestFinished>().single.result;
    }

    Map<String, String> partitionRows(TestResult result) => {
      for (
        var n = 0;
        result.metrics.containsKey('formal.property.$n.kind');
        n++
      )
        result.metrics['formal.property.$n.label']!:
            result.metrics['formal.property.$n.status']!,
    };

    test(
      'alu_pass: a correct netlist EQY FAILs is a Counterexample row',
      () async {
        final result = await run('alu_pass');
        expect(result.status, TestStatus.fail);
        expect(result.metrics['formal.verdict'], 'FAIL');
        expect(result.metrics['formal.tool'], 'eqy');
        expect(result.metrics['formal.mode'], 'equiv');
        expect(result.metrics['formal.properties'], '3');
        expect(result.metrics['formal.properties_failed'], '1');
        expect(partitionRows(result), {
          'alu.z': 'counterexample',
          'alu.y': 'proved',
          'alu.r': 'proved',
        });
        expect(result.waveformPath, isNotNull);
        expect(result.waveformPath, contains('alu.z'));
        expect(
          result.metrics['formal.property.0.trace'],
          endsWith('trace.vcd'),
        );
        // Says which partitions were proved and that the whole was not.
        expect(result.failureMessage, contains('alu.z (not equivalent'));
        expect(result.failureMessage, contains('alu.y, alu.r were proved'));
        expect(
          result.failureMessage,
          contains('not proved equivalent as a whole'),
        );
      },
    );

    test('alu_pass2: every partition proved is a PASS row', () async {
      final result = await run('alu_pass2');
      expect(result.status, TestStatus.pass);
      expect(result.metrics['formal.verdict'], 'PASS');
      expect(result.metrics['formal.verdict_disagreement'], '0');
      expect(partitionRows(result), {'alu.z': 'proved', 'alu.y': 'proved'});
      expect(result.waveformPath, isNull);
      expect(result.metrics['formal.engine'], 'smtbmc');
      expect(result.metrics['formal.solver'], 'yices');
    });

    test('alu_fail2: the mutant fails 2 of 2 partitions, each with its '
        'counterexample', () async {
      final result = await run('alu_fail2');
      expect(result.metrics['formal.verdict'], 'FAIL');
      expect(partitionRows(result), {
        'alu.z': 'counterexample',
        'alu.y': 'counterexample',
      });
      expect(result.metrics['formal.trace_count'], '2');
      for (final n in [0, 1]) {
        final trace = result.metrics['formal.property.$n.trace']!;
        expect(trace, startsWith('strategies/'));
        expect(trace, endsWith('/engine_0/trace.vcd'));
      }
      expect(result.failureMessage, contains('No partition was proved'));
    });

    test('an exit 0 under a FAIL is withheld from the scheduler', () async {
      final result = await run('alu_fail', exit: 0);
      expect(result.status, TestStatus.fail);
      expect(result.exitCode, isNull);
      expect(result.metrics['formal.process_exit_code'], '0');
    });

    test('a PASS the process contradicts is not a pass', () async {
      final result = await run('alu_pass2', exit: 3);
      expect(result.status, TestStatus.fail);
      expect(result.failureMessage, contains('contradicted'));
    });

    test('a pass detector cannot undo a FAIL', () async {
      final result = await run(
        'alu_pass',
        exit: 0,
        passFail: const StringMatchPassFailConfig(passString: 'EQY'),
      );
      expect(result.status, isNot(TestStatus.pass));
    });

    test('a run that left nothing behind did not run', () async {
      final result = await run('none');
      expect(result.status, TestStatus.fail);
      expect(result.metrics['formal.verdict'], 'NO_OUTCOME');
      expect(result.metrics.containsKey('formal.properties'), isFalse);
    });
  });
}
