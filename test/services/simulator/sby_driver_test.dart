// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
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
import 'package:simcrux/domain/models/sby_outcome.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/job_scheduler/local_job_scheduler.dart';
import 'package:simcrux/services/simulator/sby_driver.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';

import '../../support/formal_fixture_checks.dart';

// The general `sby` driver against a scripted launcher: the command line,
// containment before spawn, the agreement rule end to end through the real
// scheduler, trace containment, the exit-code rule, and demo replay of the
// committed corpus. The live run against a real sby is
// test/integration/sby_driver_live_test.dart.

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
  _Recorder({this.process, this.missing = false, this.onSpawn});

  final _FakeProcess? process;
  final bool missing;

  /// Plays `sby`: writes what it would leave in the task directory.
  final void Function(List<String> args)? onSpawn;

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
    onSpawn?.call(args);
    return process ?? _FakeProcess();
  }
}

String get _corpus => p.absolute(kFormalFixtureRoot, 'sby', 'handshake_imm');

List<String> _capturedLog(String task) => const LineSplitter().convert(
  File(p.join(_corpus, 'captured', task, 'sby.log')).readAsStringSync(),
);

void main() {
  late Directory root;
  late Directory workDir;
  late String sbyFile;

  setUp(() {
    root = Directory.systemTemp.createTempSync('simcrux_sby_driver_');
    workDir = Directory(p.join(root.path, 'work'))..createSync();
    final project = Directory(p.join(root.path, 'project'))..createSync();
    for (final name in ['handshake_imm.sby', 'handshake_imm.sv']) {
      File(p.join(_corpus, name)).copySync(p.join(project.path, name));
    }
    sbyFile = p.join(project.path, 'handshake_imm.sby');
  });
  tearDown(() => root.deleteSync(recursive: true));

  TestSpec spec(FormalConfig formal, {PassFailConfig? passFail}) => TestSpec(
    id: 'formal/t',
    name: 't',
    suiteName: 'formal',
    simulatorId: SbyDriver.kId,
    top: 't',
    passFail: passFail ?? const ExitCodePassFailConfig(),
    formal: formal,
  );

  ExecuteRequest request(
    FormalConfig formal, {
    SimulatorBinaryConfig binary = const SimulatorBinaryConfig(
      simulatorId: SbyDriver.kId,
    ),
  }) => ExecuteRequest(
    test: spec(formal),
    workingDirectory: workDir.path,
    compileResult: null,
    binaryConfig: binary,
  );

  Future<TestExecutionFinished> finished(
    SbyDriver driver,
    ExecuteRequest req,
  ) async => (await driver.execute(req).toList())
      .whereType<TestExecutionFinished>()
      .single;

  /// Copies the captured prove_bug trace where `sby` would have written it.
  void writeTrace(List<String> args) {
    final taskDir = args[args.indexOf('-d') + 1];
    final to = File(p.join(taskDir, 'engine_0', 'trace.vcd'));
    to.parent.createSync(recursive: true);
    File(
      p.join(_corpus, 'captured', 'prove_bug', 'engine_0', 'trace.vcd'),
    ).copySync(to.path);
  }

  group('identity', () {
    test('claims the bare `sby` id and declares no HDL languages', () {
      final driver = SbyDriver();
      expect(driver.id, 'sby');
      expect(driver.capabilities.supportedLanguages, isEmpty);
      expect(driver.capabilities.requiresSeparateCompileStep, isFalse);
    });
  });

  group('the command line', () {
    test(
      'is `sby -f -d <work>/<task> --live jsonl <file.sby> <task>`',
      () async {
        final recorder = _Recorder(
          process: _FakeProcess(stdoutLines: _capturedLog('prove')),
        );
        await finished(
          SbyDriver(launcher: recorder.launch),
          request(FormalConfig(sbyFile: sbyFile, task: 'prove')),
        );
        final spawn = recorder.spawns.single;
        expect(spawn.executable, 'sby');
        expect(spawn.args, [
          '-f',
          '-d',
          p.join(workDir.path, 'prove'),
          '--live',
          'jsonl',
          sbyFile,
          'prove',
        ]);
        expect(spawn.cwd, p.dirname(sbyFile), reason: 'runs beside the .sby');
      },
    );

    test('tool overrides and extra args go before the job file', () async {
      final recorder = _Recorder(process: _FakeProcess());
      await finished(
        SbyDriver(launcher: recorder.launch),
        request(
          FormalConfig(
            sbyFile: sbyFile,
            task: 'prove',
            tools: const {'yosys': '/opt/y', 'smtbmc': '/opt/s'},
            extraArgs: const ['-j', '2'],
          ),
        ),
      );
      final args = recorder.spawns.single.args;
      expect(
        args.sublist(args.indexOf('jsonl') + 1),
        [
          '--yosys',
          '/opt/y',
          '--smtbmc',
          '/opt/s',
          '-j',
          '2',
          sbyFile,
          'prove',
        ],
      );
    });

    test(
      'Settings > Engines binary path is used when the file names none',
      () async {
        final recorder = _Recorder(process: _FakeProcess());
        await finished(
          SbyDriver(launcher: recorder.launch),
          request(
            FormalConfig(sbyFile: sbyFile, task: 'prove'),
            binary: const SimulatorBinaryConfig(
              simulatorId: SbyDriver.kId,
              source: SimulatorBinarySource.custom,
              customPath: '/opt/oss-cad-suite/bin',
            ),
          ),
        );
        expect(recorder.spawns.single.executable, '/opt/oss-cad-suite/bin/sby');
      },
    );

    test('no task: the job file basename names the directory', () async {
      final recorder = _Recorder(process: _FakeProcess());
      await finished(
        SbyDriver(launcher: recorder.launch),
        request(FormalConfig(sbyFile: sbyFile)),
      );
      final args = recorder.spawns.single.args;
      expect(args[2], p.join(workDir.path, 'handshake_imm'));
      expect(args.last, sbyFile);
    });
  });

  group('containment: refused before anything is spawned', () {
    for (final task in ['..', 'a/b', r'a\b', '/etc', r'C:\x', 'C:x', '']) {
      test('task "$task"', () async {
        final recorder = _Recorder(process: _FakeProcess());
        final done = await finished(
          SbyDriver(launcher: recorder.launch),
          request(FormalConfig(sbyFile: sbyFile, task: task)),
        );
        expect(recorder.spawns, isEmpty);
        expect(done.status, TestStatus.fail);
        expect(done.failureMessage, contains('task directory'));
      });
    }

    for (final arg in [
      '-d',
      '--prefix',
      '--prefix=/tmp',
      '-d/tmp',
      '-f',
      '-t',
    ]) {
      test('extra arg "$arg" may not choose the work directory', () async {
        final recorder = _Recorder(process: _FakeProcess());
        final done = await finished(
          SbyDriver(launcher: recorder.launch),
          request(
            FormalConfig(sbyFile: sbyFile, task: 'prove', extraArgs: [arg]),
          ),
        );
        expect(recorder.spawns, isEmpty);
        expect(done.status, TestStatus.fail);
        expect(done.failureMessage, contains('work directory'));
      });
    }
  });

  group('the verdict comes from the log, never the exit code', () {
    test(
      'a counterexample: FAIL, trace attached, properties recorded',
      () async {
        final recorder = _Recorder(
          process: _FakeProcess(
            stdoutLines: _capturedLog('prove_bug'),
            exit: 2,
          ),
          onSpawn: writeTrace,
        );
        final done = await finished(
          SbyDriver(launcher: recorder.launch),
          request(FormalConfig(sbyFile: sbyFile, task: 'prove_bug')),
        );
        expect(done.status, TestStatus.fail);
        expect(done.exitCode, 2);
        expect(done.metrics['formal.verdict'], 'FAIL');
        expect(done.metrics['formal.process_exit_code'], '2');
        expect(done.metrics['formal.task'], 'prove_bug');
        expect(done.metrics['formal.mode'], 'prove');
        expect(done.metrics['formal.engine'], 'smtbmc');
        expect(done.metrics['formal.solver'], 'yices');
        expect(done.metrics['formal.properties'], '3');
        expect(done.metrics['formal.properties_failed'], '1');
        expect(done.metrics['formal.verdict_disagreement'], '0');
        expect(
          done.waveformPath,
          p.join(workDir.path, 'prove_bug', 'engine_0', 'trace.vcd'),
        );
        final failing = [
          for (var n = 0; n < 3; n++)
            if (done.metrics['formal.property.$n.status'] == 'counterexample')
              n,
        ].single;
        expect(
          done.metrics['formal.property.$failing.location'],
          'handshake_imm.sv:45.15-45.38',
          reason: 'no project root: as sby spelled it',
        );
        expect(done.metrics['formal.property.$failing.step'], '6');
        expect(
          done.metrics['formal.property.$failing.trace'],
          'engine_0/trace.vcd',
        );
        expect(done.metrics['formal.property.$failing.label'], isNull);
      },
    );

    test(
      'exit 0 with no DONE line is NO_OUTCOME and the 0 is withheld',
      () async {
        final recorder = _Recorder(
          process: _FakeProcess(
            stdoutLines: ['SBY 1:00:00 [t] engine_0: smtbmc'],
          ),
        );
        final done = await finished(
          SbyDriver(launcher: recorder.launch),
          request(FormalConfig(sbyFile: sbyFile, task: 'prove')),
        );
        expect(done.status, TestStatus.fail);
        expect(done.exitCode, isNull);
        expect(done.metrics['formal.verdict'], 'NO_OUTCOME');
        expect(done.metrics['formal.process_exit_code'], '0');
      },
    );

    test('a missing sby names the remedy and offers no install', () async {
      final recorder = _Recorder(missing: true);
      final events = await SbyDriver(launcher: recorder.launch)
          .execute(request(FormalConfig(sbyFile: sbyFile, task: 'prove')))
          .handleError((Object _) {})
          .toList();
      final done = events.whereType<TestExecutionFinished>().single;
      expect(done.failureMessage, contains('Settings → Engines'));
      expect(done.failureMessage, contains('OSS CAD Suite'));
      expect(done.failureMessage, isNot(contains('No such file')));
      expect(
        done.failureMessage!.toLowerCase(),
        isNot(contains('simcrux will')),
      );
      expect(done.failureMessage!.toLowerCase(), isNot(contains('download')));
    });

    test('status.sqlite in the task directory is read after exit', () async {
      // A log with no status stream: the per-property facts come from the
      // database sby left in the task directory.
      final log = _capturedLog(
        'prove_bug',
      ).where((l) => !l.contains(' jsonl: ')).toList();
      final recorder = _Recorder(
        process: _FakeProcess(stdoutLines: log, exit: 2),
        onSpawn: (args) {
          writeTrace(args);
          File(p.join(_corpus, 'captured', 'status.sqlite')).copySync(
            p.join(args[args.indexOf('-d') + 1], 'status.sqlite'),
          );
        },
      );
      final done = await finished(
        SbyDriver(launcher: recorder.launch),
        request(FormalConfig(sbyFile: sbyFile, task: 'prove_bug')),
      );
      expect(done.metrics['formal.properties'], '3');
      expect(done.metrics['formal.properties_failed'], '1');
    });
  });

  group('the agreement rule, through the real scheduler', () {
    Future<TestResult> runThroughScheduler(List<String> log) async {
      final recorder = _Recorder(process: _FakeProcess(stdoutLines: log));
      final scheduler = LocalJobScheduler(
        driverRegistry: SimulatorDriverRegistry({
          SbyDriver.kId: SbyDriver(launcher: recorder.launch),
        }),
        config: RegressionConfig(
          projectFilePath: '/fake/simcrux.yaml',
          schemaVersion: '1',
          suites: const [],
          simulatorBinaries: const {},
        ),
        runRoot: workDir.path,
      );
      final events = await scheduler
          .submit(
            RegressionRequest(
              runId: 'r1',
              tests: [
                spec(
                  FormalConfig(sbyFile: sbyFile, task: 'prove'),
                  // What a formal importer emits: keyed on the pass marker.
                  passFail: const StringMatchPassFailConfig(
                    passString: SbyLogReader.kPassMarker,
                  ),
                ),
              ],
            ),
          )
          .toList();
      return events.whereType<TestFinished>().single.result;
    }

    const job = 'SBY 1:00:00 [/w/prove]';
    String record(String engine, String status, int depth) =>
        '$job jsonl: {"time": 0.1, "task_name": "prove", "mode": "prove", '
        '"engine": "$engine", "name": "top.a_x", "location": "a.sv:3.1-3.9", '
        '"kind": "ASSERT", "status": "$status", "depth": $depth}';

    test(
      'DONE (PASS) with a failing property is a fail, never a pass',
      () async {
        final result = await runThroughScheduler([
          record('engine_0', 'FAIL', 2),
          '$job DONE (PASS, rc=0)',
        ]);
        expect(result.status, TestStatus.fail);
        expect(result.metrics['formal.verdict'], 'FAIL');
        expect(result.metrics['formal.verdict_disagreement'], '1');
        expect(result.failureMessage, contains('more conservative'));
        expect(result.exitCode, isNull, reason: 'the 0 is withheld');
      },
    );

    test('DONE (PASS) with every property proved is a pass', () async {
      final result = await runThroughScheduler([
        record('task_status', 'PASS', 11),
        '$job DONE (PASS, rc=0)',
      ]);
      expect(result.status, TestStatus.pass);
      expect(result.metrics['formal.verdict_disagreement'], '0');
    });
  });

  group('trace containment', () {
    test('an announced trace outside the task directory is refused', () async {
      final outside = File(p.join(root.path, 'secret.vcd'))
        ..writeAsStringSync('x');
      final recorder = _Recorder(
        process: _FakeProcess(
          stdoutLines: [
            'SBY 1:00:00 [t] summary: counterexample trace: ${outside.path}',
            'SBY 1:00:00 [t] DONE (FAIL, rc=2)',
          ],
          exit: 2,
        ),
      );
      final events =
          await SbyDriver(
                launcher: recorder.launch,
              )
              .execute(request(FormalConfig(sbyFile: sbyFile, task: 'prove')))
              .toList();
      final done = events.whereType<TestExecutionFinished>().single;
      expect(done.waveformPath, isNull);
      expect(done.metrics['formal.trace_unresolved'], outside.path);
      // A driver fault reaches the run log (and stderr), never only
      // developer.log, which a release build does not show.
      expect(
        events.whereType<TestLogLine>().where(
          (l) => l.fromStderr && l.line.startsWith('sby: trace '),
        ),
        hasLength(1),
      );
    });

    test('a symlink in the task directory that points out is refused', () async {
      final outside = File(p.join(root.path, 'secret.vcd'))
        ..writeAsStringSync('x');
      final recorder = _Recorder(
        process: _FakeProcess(
          stdoutLines: [
            'SBY 1:00:00 [t] summary: counterexample trace: engine_0/trace.vcd',
            'SBY 1:00:00 [t] DONE (FAIL, rc=2)',
          ],
          exit: 2,
        ),
        onSpawn: (args) {
          final taskDir = args[args.indexOf('-d') + 1];
          Directory(p.join(taskDir, 'engine_0')).createSync(recursive: true);
          Link(
            p.join(taskDir, 'engine_0', 'trace.vcd'),
          ).createSync(outside.path);
        },
      );
      final done = await finished(
        SbyDriver(launcher: recorder.launch),
        request(FormalConfig(sbyFile: sbyFile, task: 'prove')),
      );
      expect(done.waveformPath, isNull);
      expect(done.metrics['formal.trace_unresolved'], 'engine_0/trace.vcd');
    });

    test('a .yw witness maps to the VCD beside it', () {
      final taskDir = Directory(p.join(workDir.path, 'prove'))..createSync();
      writeTrace(['-d', taskDir.path]);
      expect(
        SbyDriver().resolveTrace('x/engine_0/trace.yw', taskDir.path),
        p.join(taskDir.path, 'engine_0', 'trace.vcd'),
      );
    });
  });

  group('demo mode replays a capture through the same readers', () {
    String demoCase({required String task, required int exit}) {
      final outputs = Directory(p.join(root.path, 'demo'))..createSync();
      final caseDir = Directory(p.join(outputs.path, 't'))..createSync();
      File(
        p.join(_corpus, 'captured', task, 'sby.log'),
      ).copySync(p.join(caseDir.path, 'sby.log'));
      File(
        p.join(_corpus, 'captured', 'status.sqlite'),
      ).copySync(p.join(caseDir.path, 'status.sqlite'));
      final trace = File(
        p.join(_corpus, 'captured', task, 'engine_0', 'trace.vcd'),
      );
      if (trace.existsSync()) {
        Directory(p.join(caseDir.path, 'engine_0')).createSync();
        trace.copySync(p.join(caseDir.path, 'engine_0', 'trace.vcd'));
      }
      File(p.join(caseDir.path, 'case.json')).writeAsStringSync(
        jsonEncode({
          'log': 'sby.log',
          'traces': [if (trace.existsSync()) 'engine_0/trace.vcd'],
          'status_db': 'status.sqlite',
          'exit_code': exit,
        }),
      );
      return outputs.path;
    }

    test('prove_bug replays to FAIL with its counterexample', () async {
      final recorder = _Recorder();
      final done = await finished(
        SbyDriver(launcher: recorder.launch),
        request(
          FormalConfig(
            task: 'prove_bug',
            mode: FormalRunMode.demo,
            demoOutputs: demoCase(task: 'prove_bug', exit: 2),
          ),
        ),
      );
      expect(recorder.spawns, isEmpty, reason: 'demo spawns nothing');
      expect(done.metrics['formal.run_mode'], 'demo');
      expect(done.metrics['formal.verdict'], 'FAIL');
      expect(done.metrics['formal.properties_failed'], '1');
      expect(done.waveformPath, endsWith(p.join('engine_0', 'trace.vcd')));
    });

    test('prove replays to PASS with every property proved', () async {
      final done = await finished(
        SbyDriver(),
        request(
          FormalConfig(
            task: 'prove',
            mode: FormalRunMode.demo,
            demoOutputs: demoCase(task: 'prove', exit: 0),
          ),
        ),
      );
      expect(done.status, TestStatus.pass);
      expect(done.metrics['formal.verdict'], 'PASS');
      expect(done.metrics['formal.properties'], '3');
      expect(done.metrics['formal.verdict_disagreement'], '0');
    });

    test('a demo case name that is a path is refused', () async {
      final done = await finished(
        SbyDriver(),
        request(
          FormalConfig(
            task: 'prove',
            mode: FormalRunMode.demo,
            demoOutputs: root.path,
            demoCase: '../work',
          ),
        ),
      );
      expect(done.status, TestStatus.fail);
      expect(done.failureMessage, contains('single directory name'));
    });
  });
}
