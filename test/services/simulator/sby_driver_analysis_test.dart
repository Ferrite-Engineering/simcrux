// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// What the sby driver adds to a finished run from its task directory, on the
// committed corpus replayed through a scripted launcher: the SVA diagnostic
// (handshake_temporal, from the task log on build 20261021 and from
// model/design.log alone on the older builds), the pre-trace marker
// (fifo_slang `cov`, pretrace `slang_cover`), and the dropped-property
// guard. The elaborated design reaches the driver through a scripted Yosys
// that writes the committed `elaborated.json`. The live run is
// test/integration/sby_driver_live_test.dart.
//
// MUTATION: drop the analysis from buildTerminalEvent and every
// formal.sva.* and formal.pretrace.* expectation here fails.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crux_yosys/crux_yosys.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/formal_bucket.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/formal_config.dart';
import 'package:simcrux/domain/models/formal_result_summary.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/formal/formal_design_reader.dart';
import 'package:simcrux/services/formal/formal_run_analysis.dart';
import 'package:simcrux/services/job_scheduler/local_job_scheduler.dart'
    show TestProcess;
import 'package:simcrux/services/simulator/sby_driver.dart';

import '../../support/formal_fixture_checks.dart';

class _FakeProcess implements TestProcess {
  _FakeProcess(this.stdoutLines, this.exit);

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

/// Plays Yosys's `read_rtlil design.il; write_json …`: copies [json] where
/// the reader asked for it.
class _ScriptedYosys implements ProcessRunner {
  _ScriptedYosys(this.json, {this.exit = 0});

  final String? json;
  final int exit;
  final List<List<String>> calls = <List<String>>[];

  @override
  Future<ProcessRunResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
    Future<void>? cancelSignal,
    String? stdoutFilePath,
    void Function(String line)? onStderrLine,
  }) async {
    calls.add(<String>[executable, ...arguments]);
    final source = json;
    if (exit == 0 && source != null) {
      File(source).copySync(
        p.join(workingDirectory!, FormalDesignReader.kJsonName),
      );
    }
    return ProcessRunResult(exitCode: exit, stdout: '', stderr: '');
  }
}

String _fx(String relative) => p.absolute(kFormalFixtureRoot, relative);

List<String> _lines(String relative) =>
    const LineSplitter().convert(File(_fx(relative)).readAsStringSync());

void main() {
  late Directory root;
  late Directory workDir;
  late Directory project;

  setUp(() {
    root = Directory.systemTemp.createTempSync('simcrux_sby_analysis_');
    workDir = Directory(p.join(root.path, 'work'))..createSync();
    project = Directory(p.join(root.path, 'project'))..createSync();
  });
  tearDown(() => root.deleteSync(recursive: true));

  /// Copies a corpus case's inputs into the project; returns the job file.
  String useCase(String name) {
    for (final f in Directory(_fx('sby/$name')).listSync().whereType<File>()) {
      if (f.path.endsWith('.sv') || f.path.endsWith('.sby')) {
        f.copySync(p.join(project.path, p.basename(f.path)));
      }
    }
    return p.join(project.path, '$name.sby');
  }

  ExecuteRequest request(String sbyFile, String task) => ExecuteRequest(
    test: TestSpec(
      id: 'formal/$task',
      name: task,
      suiteName: 'formal',
      simulatorId: SbyDriver.kId,
      top: task,
      formal: FormalConfig(
        sbyFile: sbyFile,
        task: task,
        projectRoot: project.path,
      ),
    ),
    workingDirectory: workDir.path,
    compileResult: null,
    binaryConfig: const SimulatorBinaryConfig(simulatorId: SbyDriver.kId),
  );

  /// Runs [task] with the scripted log; [stage] writes what sby would leave
  /// in the task directory.
  Future<(TestExecutionFinished, List<String>)> run(
    String sbyFile,
    String task, {
    required List<String> log,
    required int exit,
    void Function(String taskDir)? stage,
    ProcessRunner? yosys,
  }) async {
    final driver = SbyDriver(
      launcher: (executable, args, {environment, workingDirectory}) async {
        final taskDir = args[args.indexOf('-d') + 1];
        Directory(taskDir).createSync(recursive: true);
        stage?.call(taskDir);
        return _FakeProcess(log, exit);
      },
      analyser: FormalRunAnalyser(
        designReader: FormalDesignReader(
          processRunner: yosys ?? _ScriptedYosys(null),
        ),
      ),
    );
    final events = await driver.execute(request(sbyFile, task)).toList();
    return (
      events.whereType<TestExecutionFinished>().single,
      <String>[
        for (final e in events.whereType<TestLogLine>()) e.line,
      ],
    );
  }

  void copyInto(String from, String taskDir, String relative) {
    final to = File(p.join(taskDir, relative));
    to.parent.createSync(recursive: true);
    File(_fx(from)).copySync(to.path);
  }

  group('the SVA diagnostic', () {
    test('slang on 20261021: the construct and its location, first', () async {
      final sby = useCase('handshake_temporal');
      final (done, _) = await run(
        sby,
        'slang',
        log: _lines('sby/handshake_temporal/captured/slang/sby.log'),
        exit: 16,
        stage: (dir) {
          copyInto(
            'sby/handshake_temporal/captured/slang/design.log',
            dir,
            'model/design.log',
          );
          copyInto(
            'sby/handshake_temporal/handshake.sv',
            dir,
            'src/handshake.sv',
          );
        },
      );
      expect(done.status, TestStatus.fail);
      expect(done.metrics['formal.verdict'], 'ERROR');
      expect(done.metrics['formal.frontend'], 'slang');
      expect(done.metrics['formal.not_run_reason'], 'sva_unsupported');
      expect(done.metrics['formal.sva.class'], 'other');
      expect(done.metrics['formal.sva.construct'], r'$initstate');
      expect(done.metrics['formal.sva.location'], 'handshake.sv:49');
      expect(
        done.failureMessage,
        startsWith(r'`$initstate` at handshake.sv:49 is an assertion form.'),
      );
      expect(done.failureMessage, isNot(contains('pass')));
      final summary = FormalResultSummary.fromMetrics(done.metrics)!;
      expect(summary.bucket, FormalBucket.didNotRun);
      expect(summary.svaRefusal?.line, 49);
    });

    test('builtin: the named sequence on line 33', () async {
      final sby = useCase('handshake_temporal');
      final (done, _) = await run(
        sby,
        'builtin',
        log: _lines('sby/handshake_temporal/captured/builtin/sby.log'),
        exit: 16,
        stage: (dir) {
          copyInto(
            'sby/handshake_temporal/captured/builtin/design.log',
            dir,
            'model/design.log',
          );
          copyInto(
            'sby/handshake_temporal/handshake.sv',
            dir,
            'src/handshake.sv',
          );
        },
      );
      expect(done.metrics['formal.frontend'], 'builtin');
      expect(done.metrics['formal.sva.class'], 'named_sequence');
      expect(done.metrics['formal.sva.construct'], 'sequence');
      expect(done.metrics['formal.sva.location'], 'handshake.sv:33');
    });

    for (final build in ['20260921', '20260821']) {
      test('slang on $build: read from model/design.log alone', () async {
        final sby = useCase('handshake_temporal');
        final dir = 'schemas/$build/sby/handshake_temporal/slang';
        final (done, _) = await run(
          sby,
          'slang',
          log: _lines('$dir/sby.log'),
          exit: 16,
          stage: (task) {
            copyInto('$dir/design.log', task, 'model/design.log');
            copyInto(
              'sby/handshake_temporal/handshake.sv',
              task,
              'src/handshake.sv',
            );
          },
        );
        expect(done.metrics['formal.not_run_reason'], 'sva_unsupported');
        expect(done.metrics['formal.sva.construct'], r'$initstate');
        expect(done.metrics['formal.sva.location'], 'handshake.sv:49');
      });
    }

    test('a refusal outside any assertion keeps the ordinary error', () async {
      final sby = useCase('handshake_temporal');
      final (done, _) = await run(
        sby,
        'builtin',
        log: const <String>[
          'SBY 1:00:00 [handshake_temporal_builtin] base: handshake.sv:9: ERROR: syntax error, unexpected TOK_ID',
          'SBY 1:00:00 [handshake_temporal_builtin] DONE (ERROR, rc=16)',
        ],
        exit: 16,
        stage: (dir) => copyInto(
          'sby/handshake_temporal/handshake.sv',
          dir,
          'src/handshake.sv',
        ),
      );
      expect(done.metrics.containsKey('formal.sva.class'), isFalse);
      expect(done.metrics.containsKey('formal.not_run_reason'), isFalse);
      expect(done.failureMessage, contains('syntax error'));
    });
  });

  group('the pre-trace marker', () {
    List<String> taskLines(String caseName, String task) => <String>[
      for (final l in _lines('sby/$caseName/captured/run.log'))
        if (l.contains('[${caseName}_$task]')) l,
    ];

    test(r'fifo_slang cov: c_drain reached at step 2 through $past(full, 4) '
        'is flagged; c_full is not', () async {
      final sby = useCase('fifo_slang');
      final yosys = _ScriptedYosys(
        _fx('sby/fifo_slang/captured/cov/elaborated.json'),
      );
      final (done, _) = await run(
        sby,
        'cov',
        log: taskLines('fifo_slang', 'cov'),
        exit: 0,
        stage: (dir) {
          File(p.join(dir, 'model', 'design.il'))
            ..createSync(recursive: true)
            ..writeAsStringSync('# elaborated design\n');
        },
        yosys: yosys,
      );
      expect(yosys.calls.single.last, contains('read_rtlil design.il'));
      expect(done.status, TestStatus.pass);
      expect(done.metrics['formal.verdict'], 'PASS');
      expect(done.metrics['formal.pretrace.kind'], 'cover');
      expect(done.metrics['formal.pretrace.depth'], '4');
      expect(done.metrics['formal.pretrace.step'], '2');
      expect(
        done.metrics['formal.pretrace.location'],
        contains('fifo_slang.sv:47'),
      );
      final flagged = <String>[
        for (
          var n = 0;
          done.metrics.containsKey('formal.property.$n.kind');
          n++
        )
          if (done.metrics.containsKey('formal.property.$n.pretrace'))
            done.metrics['formal.property.$n.location']!,
      ];
      expect(flagged, hasLength(1));
      expect(flagged.single, contains('fifo_slang.sv:47'));
      final summary = FormalResultSummary.fromMetrics(done.metrics)!;
      expect(
        summary.bucket,
        FormalBucket.proved,
        reason: 'a marker, not a verdict',
      );
      expect(summary.pretrace?.depth, 4);
    });

    test('pretrace slang_cover: the guarded variant is not flagged', () async {
      final sby = useCase('pretrace');
      final (done, _) = await run(
        sby,
        'slang_cover',
        log: taskLines('pretrace', 'slang_cover'),
        exit: 0,
        stage: (dir) {
          File(p.join(dir, 'model', 'design.il'))
            ..createSync(recursive: true)
            ..writeAsStringSync('# elaborated design\n');
        },
        yosys: _ScriptedYosys(
          _fx('sby/pretrace/captured/slang_cover/elaborated.json'),
        ),
      );
      final byLine = <int, bool>{};
      for (
        var n = 0;
        done.metrics.containsKey('formal.property.$n.kind');
        n++
      ) {
        final location = done.metrics['formal.property.$n.location']!;
        final line = int.parse(
          RegExp(r':(\d+)').firstMatch(location)!.group(1)!,
        );
        byLine[line] = done.metrics.containsKey('formal.property.$n.pretrace');
      }
      // Hand expectation: lines 15 and 16 depend on pre-trace state, 17
      // (f_age == 3 guards it) does not.
      expect(byLine, <int, bool>{15: true, 16: true, 17: false});
    });

    test('the assertion form is flagged on its counterexample', () async {
      final sby = useCase('pretrace');
      final (done, _) = await run(
        sby,
        'slang_bmc',
        log: taskLines('pretrace', 'slang_bmc'),
        exit: 2,
        stage: (dir) {
          File(p.join(dir, 'model', 'design.il'))
            ..createSync(recursive: true)
            ..writeAsStringSync('# elaborated design\n');
        },
        yosys: _ScriptedYosys(
          _fx('sby/pretrace/captured/slang_bmc/elaborated.json'),
        ),
      );
      expect(done.metrics['formal.verdict'], 'FAIL');
      expect(done.metrics['formal.pretrace.kind'], 'assert');
      expect(done.metrics['formal.pretrace.step'], '2');
    });

    // Hand expectation (sby/vacuity/vacuity.expected.json): a_vacuous is
    // held off by the reset assumption, a_live is checked every step.
    for (final (task, vacuous, live, assume) in const [
      ('slang_bmc', 11, 12, 10),
      ('builtin_bmc', 17, 19, 15),
    ]) {
      test('vacuity $task: the never-enabled assertion names the assumption; '
          'the verdict is untouched', () async {
        final sby = useCase('vacuity');
        final (done, _) = await run(
          sby,
          task,
          log: taskLines('vacuity', task),
          exit: 0,
          stage: (dir) {
            File(p.join(dir, 'model', 'design.il'))
              ..createSync(recursive: true)
              ..writeAsStringSync('# elaborated design\n');
          },
          yosys: _ScriptedYosys(
            _fx('sby/vacuity/captured/$task/elaborated.json'),
          ),
        );
        expect(done.metrics['formal.verdict'], 'PASS');
        expect(done.status, TestStatus.pass);
        final byLine = <int, String?>{};
        for (
          var n = 0;
          done.metrics.containsKey('formal.property.$n.kind');
          n++
        ) {
          final location = done.metrics['formal.property.$n.location']!;
          final line = int.parse(
            RegExp(r':(\d+)').firstMatch(location)!.group(1)!,
          );
          byLine[line] = done.metrics['formal.property.$n.vacuous'];
        }
        expect(byLine[vacuous], 'vacuity.sv:$assume');
        expect(byLine.containsKey(live), isTrue);
        expect(byLine[live], isNull);
      });
    }

    test('a Yosys that fails leaves a note and the verdict alone', () async {
      final sby = useCase('fifo_slang');
      final (done, log) = await run(
        sby,
        'cov',
        log: taskLines('fifo_slang', 'cov'),
        exit: 0,
        stage: (dir) {
          File(p.join(dir, 'model', 'design.il'))
            ..createSync(recursive: true)
            ..writeAsStringSync('# elaborated design\n');
        },
        yosys: _ScriptedYosys(null, exit: 1),
      );
      expect(done.metrics['formal.verdict'], 'PASS');
      expect(done.metrics.containsKey('formal.pretrace.kind'), isFalse);
      expect(log.any((l) => l.contains('pre-trace')), isTrue);
    });
  });

  group('the dropped-property guard', () {
    String job(String body) {
      File(p.join(project.path, 'drop.sby')).writeAsStringSync(
        '[tasks]\nprove\n\n[options]\nmode prove\n\n[engines]\nsmtbmc\n\n'
        '[script]\nread -formal drop.sv\nprep -top pretrace\n\n[files]\n'
        'drop.sv\n',
      );
      File(p.join(project.path, 'drop.sv')).writeAsStringSync(body);
      return p.join(project.path, 'drop.sby');
    }

    Future<TestExecutionFinished> passWithCoversOnly(String source) async {
      final sby = job(source);
      final (done, _) = await run(
        sby,
        'prove',
        log: const <String>['SBY 1:00:00 [drop_prove] DONE (PASS, rc=0)'],
        exit: 0,
        stage: (dir) {
          File(p.join(dir, 'src', 'drop.sv'))
            ..createSync(recursive: true)
            ..writeAsStringSync(source);
          File(p.join(dir, 'model', 'design.il'))
            ..createSync(recursive: true)
            ..writeAsStringSync('# elaborated design\n');
        },
        // A design with three covers and no assertion.
        yosys: _ScriptedYosys(
          _fx('sby/pretrace/captured/builtin_cover/elaborated.json'),
        ),
      );
      return done;
    }

    test('declared assertions that never reached the design: Did not run, '
        'dropped, never a pass', () async {
      final done = await passWithCoversOnly(
        'module m(input clk, input a);\n'
        '  always @(posedge clk) assert (a); // dropped\n'
        'endmodule\n',
      );
      expect(done.metrics['formal.verdict'], 'PASS');
      expect(done.metrics['formal.not_run_reason'], 'dropped');
      expect(done.status, TestStatus.fail);
      expect(done.exitCode, isNull, reason: 'exit 0 is never handed on');
      expect(done.failureMessage, contains('did not run'));
      final summary = FormalResultSummary.fromMetrics(done.metrics)!;
      expect(summary.bucket, FormalBucket.didNotRun);
    });

    test('a source with no assertion is not called dropped', () async {
      final done = await passWithCoversOnly(
        'module m(input clk, input a);\n'
        '  // assert (a); is only a comment here\n'
        'endmodule\n',
      );
      expect(done.metrics.containsKey('formal.not_run_reason'), isFalse);
      expect(done.status, TestStatus.pass);
    });
  });

  test('countSourceProperties ignores comments and counts both forms', () {
    const text = '''
// assert (x);
/* cover (y); */
a1: assert property (@(posedge clk) a);
always @(posedge clk) assert (b);
always @(*) assert final (c);
c1: cover property (@(posedge clk) d);
''';
    expect(FormalRunAnalyser.countSourceProperties(text, 'assert'), 3);
    expect(FormalRunAnalyser.countSourceProperties(text, 'cover'), 1);
  });
}
