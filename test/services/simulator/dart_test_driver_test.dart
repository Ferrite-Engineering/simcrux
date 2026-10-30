// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/job_scheduler/local_job_scheduler.dart';
import 'package:simcrux/services/simulator/dart_test_driver.dart';

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

class _Launch {
  _Launch(this.executable, this.args, this.workingDirectory);
  final String executable;
  final List<String> args;
  final String? workingDirectory;
}

class _Recorder {
  _Recorder(this.make);
  final _FakeProcess Function()? make;
  final List<_Launch> calls = <_Launch>[];

  Future<TestProcess> launch(
    String executable,
    List<String> args, {
    Map<String, String>? environment,
    String? workingDirectory,
  }) async {
    calls.add(_Launch(executable, args, workingDirectory));
    final factory = make;
    if (factory == null) {
      throw ProcessException(executable, args, 'no such file', -1);
    }
    return factory();
  }
}

final String _fixture = File(
  'verification/fixtures/rohd/dart-test.json',
).readAsStringSync();

const SimulatorBinaryConfig _binary = SimulatorBinaryConfig(
  simulatorId: 'dart_test',
);

TestSpec _spec(List<String> sources, {Map<String, String>? parameters}) =>
    TestSpec(
      id: 'rohd/adder',
      name: 'adder',
      suiteName: 'rohd',
      simulatorId: 'dart_test',
      top: 'rohd_adder',
      sources: sources,
      parameters: parameters,
    );

Future<List<TestExecutionEvent>> _run(
  DartTestDriver driver,
  TestSpec spec,
  String wd,
) => driver
    .execute(
      ExecuteRequest(
        test: spec,
        workingDirectory: wd,
        compileResult: null,
        binaryConfig: _binary,
      ),
    )
    .toList()
    .timeout(const Duration(seconds: 10));

void main() {
  late Directory tmp;
  late Directory pkg;
  late Directory wd;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('simcrux_dart_test_');
    pkg = Directory('${tmp.path}/pkg')..createSync();
    Directory('${pkg.path}/test').createSync();
    File('${pkg.path}/pubspec.yaml').writeAsStringSync('name: rohd_fixture\n');
    File('${pkg.path}/test/adder_test.dart').writeAsStringSync('void main(){}');
    wd = Directory('${tmp.path}/wd')..createSync();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('declares its id and that it reads a structured report', () {
    final driver = DartTestDriver(launcher: _Recorder(null).launch);
    expect(driver.id, 'dart_test');
    expect(driver.capabilities.emitsStructuredOutput, isTrue);
    expect(driver.capabilities.requiresSeparateCompileStep, isFalse);
  });

  test('detectVersion is null when dart is missing', () async {
    final driver = DartTestDriver(launcher: _Recorder(null).launch);
    expect(await driver.detectVersion(_binary), isNull);
  });

  group('run mode', () {
    test('runs dart test in the package with a JSON file reporter', () async {
      final rec = _Recorder(
        () => _FakeProcess(stdoutLines: const ['00:00 +1: All tests passed!']),
      );
      File('${wd.path}/dart-test.json').writeAsStringSync(
        '{"test":{"id":1,"name":"a","metadata":{}},"type":"testStart","time":1}\n'
        '{"testID":1,"result":"success","skipped":false,"hidden":false,"type":"testDone","time":2}\n'
        '{"success":true,"type":"done","time":3}\n',
      );
      final events = await _run(
        DartTestDriver(launcher: rec.launch),
        _spec(['${pkg.path}/test/adder_test.dart']),
        wd.path,
      );
      final call = rec.calls.single;
      expect(call.executable, 'dart');
      expect(call.workingDirectory, pkg.path);
      expect(call.args.take(5), [
        'test',
        '--reporter',
        'expanded',
        '--file-reporter',
        'json:${wd.path}/dart-test.json',
      ]);
      expect(call.args.last, 'test/adder_test.dart');
      // The console output is kept.
      expect(
        events.whereType<TestLogLine>().map((e) => e.line),
        contains('00:00 +1: All tests passed!'),
      );
      final finished = events.whereType<TestExecutionFinished>().single;
      expect(finished.status, TestStatus.pass);
      expect(finished.metrics['dart.tests'], '1');
    });

    test(
      'a failing report fails the row even when the exit code is 0',
      () async {
        File('${wd.path}/dart-test.json').writeAsStringSync(_fixture);
        final events = await _run(
          DartTestDriver(launcher: _Recorder(_FakeProcess.new).launch),
          _spec(['${pkg.path}/test/adder_test.dart']),
          wd.path,
        );
        final finished = events.whereType<TestExecutionFinished>().single;
        expect(finished.status, TestStatus.fail);
        expect(finished.exitCode, isNull);
        expect(finished.metrics[DartTestDriver.kMetricProcessExitCode], '0');
        expect(finished.failureMessage, contains('plain rohd adder fails'));
        expect(finished.failureMessage, contains('and 1 more'));
        expect(
          finished.metrics['dart.case.1.source_file'],
          '${pkg.path}/test/probe_test.dart',
        );
      },
    );

    test('with no report the exit code decides', () async {
      final events = await _run(
        DartTestDriver(launcher: _Recorder(() => _FakeProcess(exit: 1)).launch),
        _spec(['${pkg.path}/test/adder_test.dart']),
        wd.path,
      );
      final finished = events.whereType<TestExecutionFinished>().single;
      expect(finished.status, TestStatus.fail);
      expect(finished.exitCode, 1);
      expect(finished.metrics, isEmpty);
    });

    test('a garbage report falls back to the exit code', () async {
      File('${wd.path}/dart-test.json').writeAsStringSync('}{ not a report');
      final events = await _run(
        DartTestDriver(launcher: _Recorder(_FakeProcess.new).launch),
        _spec(['${pkg.path}/test/adder_test.dart']),
        wd.path,
      );
      expect(
        events.whereType<TestExecutionFinished>().single.status,
        TestStatus.pass,
      );
    });

    test('no package to run in is a clear, non-crashing result', () async {
      final events = await _run(
        DartTestDriver(launcher: _Recorder(null).launch),
        _spec(const []),
        wd.path,
      );
      final finished = events.whereType<TestExecutionFinished>().single;
      expect(finished.status, TestStatus.unknown);
      expect(finished.failureMessage, contains('package_dir'));
    });

    test('a missing dart reports the tool as unavailable', () async {
      final driver = DartTestDriver(launcher: _Recorder(null).launch);
      final events = await driver
          .execute(
            ExecuteRequest(
              test: _spec(['${pkg.path}/test/adder_test.dart']),
              workingDirectory: wd.path,
              compileResult: null,
              binaryConfig: _binary,
            ),
          )
          .handleError((Object _) {})
          .toList();
      expect(
        events.whereType<TestExecutionFinished>().single.status,
        TestStatus.unknown,
      );
    });
  });

  group('import mode', () {
    test('reads an existing JSON report without running anything', () async {
      final report = File('${tmp.path}/results.jsonl')
        ..writeAsStringSync(_fixture);
      final rec = _Recorder(null);
      final events = await _run(
        DartTestDriver(launcher: rec.launch),
        _spec([report.path], parameters: {'package_dir': pkg.path}),
        wd.path,
      );
      expect(rec.calls, isEmpty);
      final finished = events.whereType<TestExecutionFinished>().single;
      expect(finished.status, TestStatus.fail);
      expect(finished.metrics['dart.fail'], '2');
      expect(finished.metrics['dart.case.3.rohd_vf'], 'true');
      // Logs are kept: the ROHD-VF lines come back in their original shape.
      final lines = events.whereType<TestLogLine>().map((e) => e.line);
      expect(
        lines.any((l) => l.startsWith('[SEVERE] @ 0 | add_test: mismatch')),
        isTrue,
      );
    });

    test('a file that is not a report is reported, not thrown', () async {
      final notReport = File('${tmp.path}/other.json')
        ..writeAsStringSync('{"hello": 1}');
      final events = await _run(
        DartTestDriver(launcher: _Recorder(null).launch),
        _spec([notReport.path]),
        wd.path,
      );
      final finished = events.whereType<TestExecutionFinished>().single;
      expect(finished.status, TestStatus.unknown);
      expect(
        finished.failureMessage,
        contains('not a `dart test` JSON report'),
      );
    });

    test('a missing file is reported, not thrown', () async {
      final events = await _run(
        DartTestDriver(launcher: _Recorder(null).launch),
        _spec(['${tmp.path}/nope.jsonl']),
        wd.path,
      );
      expect(
        events.whereType<TestExecutionFinished>().single.status,
        TestStatus.unknown,
      );
    });
  });
}
