// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/pr_annotation.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/services/pr_annotation/run_annotation_builder.dart';

TestResult _result(
  String id, {
  TestStatus status = TestStatus.pass,
  String? failureMessage,
  int? exitCode,
  int? seed,
  String? waveformPath,
}) {
  final start = DateTime.utc(2026, 7, 30);
  return TestResult(
    testId: id,
    runId: 'run-1',
    status: status,
    startedAt: start,
    finishedAt: start.add(const Duration(seconds: 1)),
    failureMessage: failureMessage,
    exitCode: exitCode,
    executionSeed: seed,
    waveformPath: waveformPath,
  );
}

PrAnnotation _statusCheckOf(List<PrAnnotation> a) =>
    a.firstWhere((x) => x.targetKind == PrAnnotationTargetKind.statusCheck);

List<PrAnnotation> _failuresOf(List<PrAnnotation> a) =>
    a.where((x) => x.targetKind == PrAnnotationTargetKind.annotation).toList();

void main() {
  const builder = RunAnnotationBuilder();

  group('status check', () {
    test('an all-green run produces exactly one notice status check', () {
      final annotations = builder.build(
        results: [_result('a'), _result('b')],
        runId: 'run-1',
      );

      expect(annotations, hasLength(1));
      final check = _statusCheckOf(annotations);
      expect(check.severity, PrAnnotationSeverity.notice);
      expect(check.message, contains('2 of 2 tests passed'));
      expect(check.extraMetadata['simcrux.failed'], '0');
    });

    test('passing tests never produce their own annotations', () {
      final annotations = builder.build(
        results: List.generate(50, (i) => _result('pass-$i')),
        runId: 'run-1',
      );
      expect(_failuresOf(annotations), isEmpty);
    });

    test('a failing run escalates the status check to error', () {
      final annotations = builder.build(
        results: [
          _result('a'),
          _result('b', status: TestStatus.fail),
        ],
        runId: 'run-1',
      );
      expect(_statusCheckOf(annotations).severity, PrAnnotationSeverity.error);
    });

    test('a cancelled run is a notice, not a failure, and says it is '
        'partial', () {
      final annotations = builder.build(
        results: [_result('a', status: TestStatus.fail)],
        runId: 'run-1',
        cancelled: true,
      );
      final check = _statusCheckOf(annotations);
      expect(
        check.severity,
        PrAnnotationSeverity.notice,
        reason:
            'the user stopped the run; that is not a verdict on the '
            'design, and marking it failed teaches people to ignore the check',
      );
      expect(check.message, contains('partial'));
      expect(check.extraMetadata['simcrux.cancelled'], 'true');
    });

    test('carries the run id so a reader can find the run locally', () {
      final annotations = builder.build(
        results: [_result('a')],
        runId: 'run-xyz',
      );
      final check = _statusCheckOf(annotations);
      expect(check.message, contains('run-xyz'));
      expect(check.extraMetadata['simcrux.run_id'], 'run-xyz');
    });

    test('reports skipped separately from passed', () {
      final annotations = builder.build(
        results: [
          _result('a'),
          _result('b', status: TestStatus.skipped),
        ],
        runId: 'run-1',
      );
      final check = _statusCheckOf(annotations);
      expect(check.message, contains('1 of 2 tests passed'));
      expect(check.message, contains('1 skipped'));
    });
  });

  group('which statuses gate', () {
    test('fail, timeout and unknown all count as failures', () {
      for (final status in <TestStatus>[
        TestStatus.fail,
        TestStatus.timeout,
        TestStatus.unknown,
      ]) {
        final annotations = builder.build(
          results: [_result('t', status: status)],
          runId: 'run-1',
        );
        expect(
          _statusCheckOf(annotations).severity,
          PrAnnotationSeverity.error,
          reason:
              '$status must gate — letting it slide is how a hanging or '
              'unclassifiable test becomes permanent',
        );
        expect(_failuresOf(annotations), hasLength(1));
      }
    });

    test('cancelled is not a failure', () {
      final annotations = builder.build(
        results: [_result('t', status: TestStatus.cancelled)],
        runId: 'run-1',
      );
      expect(_failuresOf(annotations), isEmpty);
      expect(_statusCheckOf(annotations).severity, PrAnnotationSeverity.notice);
    });

    test('vacuous and cover do not gate', () {
      final annotations = builder.build(
        results: [
          _result('v', status: TestStatus.vacuous),
          _result('c', status: TestStatus.cover),
        ],
        runId: 'run-1',
      );
      expect(_failuresOf(annotations), isEmpty);
    });
  });

  group('per-failure annotations', () {
    test('names the test and its exit code', () {
      final annotations = builder.build(
        results: [
          _result('alu_basic', status: TestStatus.fail, exitCode: 3),
        ],
        runId: 'run-1',
      );
      final failure = _failuresOf(annotations).single;
      expect(failure.title, 'alu_basic');
      expect(failure.message, contains('alu_basic failed'));
      expect(failure.message, contains('exit 3'));
      expect(failure.severity, PrAnnotationSeverity.error);
    });

    test('distinguishes a timeout from an assertion failure in prose', () {
      final annotations = builder.build(
        results: [_result('hangs', status: TestStatus.timeout)],
        runId: 'run-1',
      );
      expect(_failuresOf(annotations).single.message, contains('timed out'));
    });

    test('includes the failure message when present', () {
      final annotations = builder.build(
        results: [
          _result(
            'alu',
            status: TestStatus.fail,
            failureMessage: 'expected 8 got 9',
          ),
        ],
        runId: 'run-1',
      );
      expect(
        _failuresOf(annotations).single.message,
        contains('expected 8 got 9'),
      );
    });

    test('offers a reproduction command when the seed is known', () {
      final annotations = builder.build(
        results: [_result('rnd', status: TestStatus.fail, seed: 47)],
        runId: 'run-1',
      );
      final failure = _failuresOf(annotations).single;
      expect(failure.message, contains('--filter rnd'));
      expect(failure.message, contains('seed 47'));
      expect(failure.extraMetadata['simcrux.seed'], '47');
    });

    test('carries the waveform path as metadata when one was captured', () {
      final annotations = builder.build(
        results: [
          _result('w', status: TestStatus.fail, waveformPath: '/tmp/w.fst'),
        ],
        runId: 'run-1',
      );
      expect(
        _failuresOf(annotations).single.extraMetadata['simcrux.waveform'],
        '/tmp/w.fst',
      );
    });

    test('never guesses a file path — GitHub silently drops annotations '
        'whose path is not in the diff', () {
      final annotations = builder.build(
        results: [_result('a', status: TestStatus.fail)],
        runId: 'run-1',
      );
      final failure = _failuresOf(annotations).single;
      expect(failure.filePath, isNull);
      expect(failure.lineNumber, isNull);
    });
  });

  group('truncation', () {
    test('caps per-failure annotations at maxFailureAnnotations', () {
      const capped = RunAnnotationBuilder(maxFailureAnnotations: 3);
      final annotations = capped.build(
        results: List.generate(
          10,
          (i) => _result('f-$i', status: TestStatus.fail),
        ),
        runId: 'run-1',
      );
      expect(_failuresOf(annotations), hasLength(3));
    });

    test('announces truncation instead of silently showing a subset', () {
      const capped = RunAnnotationBuilder(maxFailureAnnotations: 3);
      final annotations = capped.build(
        results: List.generate(
          10,
          (i) => _result('f-$i', status: TestStatus.fail),
        ),
        runId: 'run-1',
      );
      final check = _statusCheckOf(annotations);
      expect(check.message, contains('first 3 of 10 failures'));
      expect(
        check.extraMetadata['simcrux.failed'],
        '10',
        reason:
            'the true count must survive truncation — a subset that '
            'does not announce itself reads as the complete set',
      );
    });

    test('does not mention truncation when nothing was truncated', () {
      final annotations = builder.build(
        results: [_result('f', status: TestStatus.fail)],
        runId: 'run-1',
      );
      expect(_statusCheckOf(annotations).message, isNot(contains('first')));
    });

    test("the default cap leaves headroom under GitHub's 50-per-request "
        'limit', () {
      expect(const RunAnnotationBuilder().maxFailureAnnotations, lessThan(50));
    });
  });

  test('an empty run still produces a status check', () {
    final annotations = builder.build(results: const [], runId: 'run-1');
    expect(annotations, hasLength(1));
    expect(_statusCheckOf(annotations).message, contains('0 of 0'));
  });

  test('the returned list is unmodifiable', () {
    final annotations = builder.build(results: [_result('a')], runId: 'r');
    expect(
      () => annotations.add(annotations.first),
      throwsUnsupportedError,
    );
  });
}
