// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/services/simulator/dart_test_metrics.dart';
import 'package:simcrux/services/simulator/dart_test_report.dart';

final DartTestReport _report = parseDartTestReport(
  File('verification/fixtures/rohd/dart-test.json').readAsStringSync(),
)!;

String? _resolve(String uri) => resolveDartSourcePath(
  uri,
  packageRoot: '/work/rohd_fixture',
  packageName: 'rohd_fixture',
);

void main() {
  group('dartTestMetrics', () {
    final metrics = dartTestMetrics(_report, resolve: _resolve);

    test('counts the run', () {
      expect(metrics['dart.tests'], '4');
      expect(metrics['dart.pass'], '2');
      expect(metrics['dart.fail'], '2');
      expect(metrics['dart.error'], '0');
      expect(metrics['dart.complete'], 'true');
      expect(metrics['dart.objection_warnings'], '2');
    });

    test('writes one status per case, in run order', () {
      expect(metrics['dart.case.0.name'], 'plain rohd adder passes');
      expect(metrics['dart.case.0.status'], 'PASS');
      expect(metrics['dart.case.3.name'], 'rohd-vf fails');
      expect(metrics['dart.case.3.status'], 'FAIL');
      expect(metrics['dart.case.3.rohd_vf'], 'true');
    });

    test('resolves declaration and failing frame to files', () {
      expect(
        metrics['dart.case.1.file'],
        '/work/rohd_fixture/test/probe_test.dart',
      );
      expect(metrics['dart.case.1.line'], '71');
      expect(
        metrics['dart.case.1.source_file'],
        '/work/rohd_fixture/test/probe_test.dart',
      );
      expect(metrics['dart.case.1.source_line'], '76');
    });

    test('keeps detail for failing cases only', () {
      expect(metrics.containsKey('dart.case.0.message'), isFalse);
      expect(metrics.containsKey('dart.case.0.stack'), isFalse);
      expect(metrics['dart.case.1.message'], contains('Expected: <8>'));
      expect(metrics['dart.case.3.logs'], contains('SEVERE'));
    });

    test('caps the cases that carry detail', () {
      final many = DartTestReport(
        complete: true,
        cases: <DartTestCase>[
          for (var i = 0; i < kDartTestMaxDetailedCases + 10; i++)
            DartTestCase(
              id: i,
              name: 't$i',
              outcome: DartTestOutcome.fail,
              message: 'boom',
            ),
        ],
      );
      final m = dartTestMetrics(many, resolve: _resolve);
      expect(m['dart.tests'], '${kDartTestMaxDetailedCases + 10}');
      expect(m['dart.case.${kDartTestMaxDetailedCases + 5}.status'], 'FAIL');
      expect(
        m.containsKey('dart.case.${kDartTestMaxDetailedCases + 5}.message'),
        isFalse,
      );
    });
  });

  group('DartTestResultView', () {
    final view = DartTestResultView.fromMetrics(
      dartTestMetrics(_report, resolve: _resolve),
    )!;

    test('round-trips the rows', () {
      expect(view.rows, hasLength(4));
      expect(view.tests, 4);
      expect(view.objectionWarnings, 2);
      expect(view.complete, isTrue);
      final vf = view.rows[3];
      expect(vf.failing, isTrue);
      expect(vf.rohdVf, isTrue);
      expect(vf.message, 'Exception: Test failed.');
      expect(
        vf.logs.where((l) => l.severity == 'SEVERE'),
        hasLength(3),
      );
    });

    test('Go to Source prefers the failing frame over the declaration', () {
      final failing = view.rows[1];
      expect(failing.goToFile, endsWith('/test/probe_test.dart'));
      expect(failing.goToLine, 76);
      final passing = view.rows[0];
      expect(passing.goToLine, 63);
    });

    test('is null for a row that is not a Dart test run', () {
      expect(DartTestResultView.fromMetrics(const <String, String>{}), isNull);
      expect(
        DartTestResultView.fromMetrics(const {'cocotb.tests': '3'}),
        isNull,
      );
    });

    test('survives garbage metric values', () {
      final v = DartTestResultView.fromMetrics(const {
        'dart.tests': '1',
        'dart.case.0.name': 'x',
        'dart.case.0.line': 'NaN',
        'dart.case.0.logs': '{not json',
      })!;
      expect(v.rows.single.line, isNull);
      expect(v.rows.single.logs, isEmpty);
      expect(v.rows.single.status, 'ERROR');
    });
  });
}
