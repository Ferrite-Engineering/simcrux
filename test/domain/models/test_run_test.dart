// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_run.dart';

TestResult _result(String id, TestStatus status) {
  final start = DateTime.utc(2026, 5, 22, 10);
  return TestResult(
    testId: id,
    runId: 'run-1',
    status: status,
    startedAt: start,
    finishedAt: start.add(const Duration(seconds: 1)),
  );
}

void main() {
  group('TestRun', () {
    test('isFinished is false until finishedAt is set', () {
      final run = TestRun(
        id: 'run-1',
        startedAt: DateTime.utc(2026, 5, 22, 10),
        testIds: const ['t1', 't2'],
      );
      expect(run.isFinished, isFalse);
      final finished = run.copyWith(
        finishedAt: DateTime.utc(2026, 5, 22, 10, 5),
      );
      expect(finished.isFinished, isTrue);
    });

    test('countOf counts results matching a status', () {
      final run = TestRun(
        id: 'run-1',
        startedAt: DateTime.utc(2026, 5, 22, 10),
        testIds: const ['t1', 't2', 't3'],
        results: [
          _result('t1', TestStatus.pass),
          _result('t2', TestStatus.fail),
          _result('t3', TestStatus.pass),
        ],
      );
      expect(run.countOf(TestStatus.pass), 2);
      expect(run.countOf(TestStatus.fail), 1);
      expect(run.countOf(TestStatus.skipped), 0);
    });

    test('runtime returns elapsed-from-now when run is in flight', () {
      final start = DateTime.utc(2026, 5, 22, 10);
      final run = TestRun(
        id: 'run-1',
        startedAt: start,
        testIds: const ['t1'],
      );
      expect(
        run.runtime(now: start.add(const Duration(seconds: 30))),
        const Duration(seconds: 30),
      );
    });

    test('runtime returns the final span when run is finished', () {
      final start = DateTime.utc(2026, 5, 22, 10);
      final run = TestRun(
        id: 'run-1',
        startedAt: start,
        finishedAt: start.add(const Duration(minutes: 5)),
        testIds: const ['t1'],
      );
      expect(run.runtime(), const Duration(minutes: 5));
    });

    test('equality compares every field', () {
      final start = DateTime.utc(2026, 5, 22, 10);
      final a = TestRun(
        id: 'run-1',
        startedAt: start,
        testIds: const ['t1'],
        results: [_result('t1', TestStatus.pass)],
      );
      final b = TestRun(
        id: 'run-1',
        startedAt: start,
        testIds: const ['t1'],
        results: [_result('t1', TestStatus.pass)],
      );
      final c = TestRun(
        id: 'run-2',
        startedAt: start,
        testIds: const ['t1'],
        results: [_result('t1', TestStatus.pass)],
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
    });
  });
}
