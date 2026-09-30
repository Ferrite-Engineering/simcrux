// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/result_store.dart';

void main() {
  group('RunSummary', () {
    test('totalsByStatus is wrapped unmodifiable', () {
      final summary = RunSummary(
        runId: 'r',
        startedAt: DateTime.utc(2026, 5, 22, 10),
        finishedAt: DateTime.utc(2026, 5, 22, 10, 5),
        totalsByStatus: const {
          TestStatus.pass: 9,
          TestStatus.fail: 1,
        },
      );
      expect(
        () => summary.totalsByStatus[TestStatus.skipped] = 1,
        throwsUnsupportedError,
      );
      expect(summary.runtime, const Duration(minutes: 5));
    });
  });

  group('RunQuery', () {
    test('all fields default to null / unlimited', () {
      const q = RunQuery();
      expect(q.since, isNull);
      expect(q.until, isNull);
      expect(q.limit, isNull);
      expect(q.projectFilePath, isNull);
    });
  });

  group('ResultQuery', () {
    test('captures status filter set and substring', () {
      const q = ResultQuery(
        testIdSubstring: 'alu',
        status: {TestStatus.fail, TestStatus.timeout},
        limit: 50,
      );
      expect(q.testIdSubstring, 'alu');
      expect(q.status, {TestStatus.fail, TestStatus.timeout});
      expect(q.limit, 50);
    });
  });
}
