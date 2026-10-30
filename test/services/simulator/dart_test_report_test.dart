// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/services/simulator/dart_test_report.dart';

/// Real `dart test --file-reporter json` output over a ROHD 0.7-or-later
/// design and a ROHD-VF test; see `verification/fixtures/rohd/README.md` for
/// the pinned commits and the generator.
final String _fixture = File(
  'verification/fixtures/rohd/dart-test.json',
).readAsStringSync();

void main() {
  group('parseDartTestReport — real ROHD fixture', () {
    final report = parseDartTestReport(_fixture)!;

    test('lists the four cases in run order', () {
      expect(report.cases.map((c) => c.name), <String>[
        'plain rohd adder passes',
        'plain rohd adder fails',
        'rohd-vf passes',
        'rohd-vf fails',
      ]);
      expect(report.complete, isTrue);
      expect(report.passed, isFalse);
    });

    test(
      'maps outcomes: success, failure, and the ROHD-VF reclassification',
      () {
        expect(report.cases.map((c) => c.outcome), <DartTestOutcome>[
          DartTestOutcome.pass,
          DartTestOutcome.fail,
          DartTestOutcome.pass,
          // The runner says `result: error`; the Test._checkAll frame makes it
          // a failing check.
          DartTestOutcome.fail,
        ]);
        expect(report.cases[1].rohdVfFailure, isFalse);
        expect(report.cases[3].rohdVfFailure, isTrue);
        expect(report.failing, 2);
        expect(report.isClean, isFalse);
      },
    );

    test('carries the declaration location of each test', () {
      final first = report.cases.first.declared!;
      expect(first.uri, endsWith('/test/probe_test.dart'));
      expect(first.line, 63);
      expect(first.column, 3);
    });

    test('carries message and stack, and finds the first user frame', () {
      final plain = report.cases[1];
      expect(plain.message, contains('Expected: <8>'));
      expect(plain.failureFrame!.uri, 'test/probe_test.dart');
      expect(plain.failureFrame!.line, 76);
      expect(plain.failureFrame!.column, 5);

      final vf = report.cases[3];
      expect(vf.message, 'Exception: Test failed.');
      // Frames inside rohd_vf are skipped; the test body is the user's.
      expect(vf.failureFrame!.uri, 'test/probe_test.dart');
      expect(vf.failureFrame!.line, 87);
    });

    test('records a duration for every finished case', () {
      expect(report.cases.every((c) => (c.durationMs ?? -1) >= 0), isTrue);
    });

    test('splits ROHD-VF log lines into severity, time and logger', () {
      final logs = report.cases[3].logs;
      final severe = logs.where((l) => l.severity == 'SEVERE').toList();
      expect(severe, hasLength(3));
      expect(severe.first.simTime, 0);
      expect(severe.first.logger, 'add_test');
      expect(severe.first.message, startsWith('mismatch: '));
      // `Test failure detected, but continuing...` is a plain print.
      final plain = logs.where((l) => !l.structured).toList();
      expect(plain.single.message, contains('Test failure detected'));
    });

    test('surfaces the objection warning', () {
      expect(report.cases[3].objectionWarnings, 1);
      expect(report.cases[2].objectionWarnings, 1);
      expect(report.objectionWarnings, 2);
    });
  });

  group('parseRohdVfLogLine', () {
    test('splits level, simulated time, logger and message', () {
      final e = parseRohdVfLogLine(
        '[SEVERE] @ 1250 | top.env.monitor: bad data: 3 != 4',
      );
      expect(e.severity, 'SEVERE');
      expect(e.simTime, 1250);
      expect(e.logger, 'top.env.monitor');
      expect(e.message, 'bad data: 3 != 4');
    });

    test('leaves a line of another shape whole', () {
      final e = parseRohdVfLogLine('hello [INFO] world');
      expect(e.structured, isFalse);
      expect(e.message, 'hello [INFO] world');
    });
  });

  group('parseDartTestReport — hostile input', () {
    test('returns null for text with no test events', () {
      expect(parseDartTestReport(''), isNull);
      expect(parseDartTestReport('not json\nat all'), isNull);
      expect(parseDartTestReport('[1,2,3]'), isNull);
    });

    test('skips lines that are not JSON objects and unknown event types', () {
      final report = parseDartTestReport(
        '''
garbage {{{
{"type":"futureEvent","x":1}
{"test":{"id":1,"name":"a","metadata":{}},"type":"testStart","time":1}
{"testID":1,"result":"success","skipped":false,"hidden":false,"type":"testDone","time":5}
{"success":true,"type":"done","time":6}
''',
      )!;
      expect(report.cases.single.outcome, DartTestOutcome.pass);
      expect(report.cases.single.durationMs, 4);
    });

    test('tolerates fields of the wrong type', () {
      final report = parseDartTestReport(
        '''
{"test":{"id":"1","name":5},"type":"testStart","time":"x"}
{"test":{"id":2,"name":"ok","line":"7","url":3,"metadata":[]},"type":"testStart","time":1}
{"testID":2,"error":7,"stackTrace":[],"type":"error","time":2}
{"testID":2,"result":"success","skipped":"no","type":"testDone","time":3}
''',
      )!;
      expect(report.cases.single.name, 'ok');
      expect(report.cases.single.declared, isNull);
      expect(report.cases.single.outcome, DartTestOutcome.pass);
    });

    test('a truncated run reports the unfinished case as an error', () {
      final text = _fixture
          .split('\n')
          .takeWhile((l) => !l.contains('"testID":6,"result"'))
          .join('\n');
      final report = parseDartTestReport(text)!;
      expect(report.complete, isFalse);
      expect(report.cases.last.name, 'rohd-vf fails');
      expect(report.cases.last.outcome, DartTestOutcome.error);
      // The runner never confirmed the verdict, so no reclassification.
      expect(report.cases.last.rohdVfFailure, isFalse);
    });

    test('an unfinished case with no error says the run ended', () {
      final report = parseDartTestReport(
        '{"test":{"id":1,"name":"a","metadata":{}},"type":"testStart","time":1}\n',
      )!;
      expect(report.cases.single.outcome, DartTestOutcome.error);
      expect(report.cases.single.message, contains('ended before'));
    });

    test('a skipped case is a skip, with its reason', () {
      final report = parseDartTestReport(
        '''
{"test":{"id":1,"name":"later","metadata":{"skip":true,"skipReason":"todo"}},"type":"testStart","time":1}
{"testID":1,"result":"success","skipped":true,"hidden":false,"type":"testDone","time":2}
{"success":true,"type":"done","time":3}
''',
      )!;
      expect(report.cases.single.outcome, DartTestOutcome.skip);
      expect(report.cases.single.skipReason, 'todo');
    });

    test('a test file that does not load is an error, not hidden', () {
      final report = parseDartTestReport(
        '''
{"test":{"id":1,"name":"loading test/x_test.dart","metadata":{}},"type":"testStart","time":1}
{"testID":1,"error":"Failed to load","stackTrace":"","isFailure":false,"type":"error","time":2}
{"testID":1,"result":"error","skipped":false,"hidden":true,"type":"testDone","time":3}
{"success":false,"type":"done","time":4}
''',
      )!;
      expect(report.cases.single.outcome, DartTestOutcome.error);
    });

    test('a hidden successful loading step is not a case', () {
      final report = parseDartTestReport(
        '''
{"test":{"id":1,"name":"loading test/x_test.dart","metadata":{}},"type":"testStart","time":1}
{"testID":1,"result":"success","skipped":false,"hidden":true,"type":"testDone","time":3}
{"success":true,"type":"done","time":4}
''',
      )!;
      expect(report.cases, isEmpty);
      expect(report.complete, isTrue);
    });
  });

  group('resolveDartSourcePath', () {
    test('resolves file URIs, relative paths and the own package', () {
      expect(
        resolveDartSourcePath(
          'file:///work/p/test/a_test.dart',
          packageRoot: '/work/p',
        ),
        '/work/p/test/a_test.dart',
      );
      expect(
        resolveDartSourcePath('test/a_test.dart', packageRoot: '/work/p'),
        '/work/p/test/a_test.dart',
      );
      expect(
        resolveDartSourcePath(
          'package:mine/src/x.dart',
          packageRoot: '/work/p',
          packageName: 'mine',
        ),
        '/work/p/lib/src/x.dart',
      );
    });

    test('declines dart: libraries and other packages', () {
      expect(
        resolveDartSourcePath('dart:async', packageRoot: '/work/p'),
        isNull,
      );
      expect(
        resolveDartSourcePath(
          'package:rohd/src/module.dart',
          packageRoot: '/work/p',
          packageName: 'mine',
        ),
        isNull,
      );
    });
  });
}
