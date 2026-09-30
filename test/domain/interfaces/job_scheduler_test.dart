// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/job_scheduler.dart';
import 'package:simcrux/domain/models/test_result.dart';

void main() {
  group('RegressionStatus', () {
    test('captures totals and finished flag', () {
      const status = RegressionStatus(
        runId: 'r',
        totalTests: 10,
        completedTests: 7,
        runningTests: 3,
        isFinished: false,
      );
      expect(status.runId, 'r');
      expect(status.totalTests, 10);
      expect(status.completedTests, 7);
      expect(status.runningTests, 3);
      expect(status.isFinished, isFalse);
    });
  });

  group('RegressionEvent variants', () {
    test('TestStarted carries runId + testId', () {
      const ev = TestStarted(runId: 'r', testId: 't1');
      expect(ev.runId, 'r');
      expect(ev.testId, 't1');
    });

    test('TestLog carries line + stderr flag', () {
      const ev = TestLog(
        runId: 'r',
        testId: 't1',
        line: 'hello',
        fromStderr: false,
      );
      expect(ev.line, 'hello');
      expect(ev.fromStderr, isFalse);
    });

    test('TestProgress reports an intermediate status', () {
      const ev = TestProgress(
        runId: 'r',
        testId: 't1',
        status: TestStatus.running,
      );
      expect(ev.status, TestStatus.running);
    });

    test('TestFinished carries the classified result', () {
      final start = DateTime.utc(2026, 5, 22, 10);
      final result = TestResult(
        testId: 't1',
        runId: 'r',
        status: TestStatus.pass,
        startedAt: start,
        finishedAt: start.add(const Duration(seconds: 1)),
      );
      final ev = TestFinished(runId: 'r', result: result);
      expect(ev.result.status, TestStatus.pass);
    });

    test('RegressionFinished tracks cancellation', () {
      const a = RegressionFinished(runId: 'r', cancelled: false);
      const b = RegressionFinished(runId: 'r', cancelled: true);
      expect(a.cancelled, isFalse);
      expect(b.cancelled, isTrue);
    });
  });
}
