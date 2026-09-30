// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/trend_store.dart';

void main() {
  group('TrendPoint', () {
    test('carries every field for the SQLite insert', () {
      final point = TrendPoint(
        runId: 'r',
        testId: 't1',
        status: TestStatus.pass,
        runtime: const Duration(seconds: 12),
        startedAt: DateTime.utc(2026, 5, 22, 10),
      );
      expect(point.runId, 'r');
      expect(point.testId, 't1');
      expect(point.status, TestStatus.pass);
      expect(point.runtime, const Duration(seconds: 12));
    });
  });

  group('TrendDelta', () {
    test('previousStatus may be null on first-seen tests', () {
      const delta = TrendDelta(
        testId: 't_new',
        currentStatus: TestStatus.pass,
        previousStatus: null,
        currentRunId: 'r-1',
      );
      expect(delta.previousStatus, isNull);
      expect(delta.currentStatus, TestStatus.pass);
    });

    test('detects newly-failing tests', () {
      const delta = TrendDelta(
        testId: 't',
        currentStatus: TestStatus.fail,
        previousStatus: TestStatus.pass,
        currentRunId: 'r-2',
      );
      expect(delta.currentStatus, TestStatus.fail);
      expect(delta.previousStatus, TestStatus.pass);
    });
  });
}
