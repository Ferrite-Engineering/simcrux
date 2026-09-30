// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/retry_policy.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_spec.dart';

TestSpec _spec() => TestSpec(
  id: 'cpu_unit/alu_basic',
  name: 'alu_basic',
  suiteName: 'cpu_unit',
  simulatorId: 'icarus',
  top: 'tb_alu',
);

TestResult _result({TestStatus status = TestStatus.fail, int? seed}) {
  return TestResult(
    testId: 'cpu_unit/alu_basic',
    runId: 'r1',
    status: status,
    startedAt: DateTime.utc(2026, 5),
    finishedAt: DateTime.utc(2026, 5, 1, 0, 0, 1),
    executionSeed: seed,
  );
}

void main() {
  group('NoopRetryPolicy', () {
    const policy = NoopRetryPolicy();

    test('shouldRetry returns false regardless of status / attempts', () {
      for (final status in TestStatus.values) {
        for (var attempts = 1; attempts <= 5; attempts++) {
          expect(
            policy.shouldRetry(
              spec: _spec(),
              lastResult: _result(status: status),
              attemptsSoFar: attempts,
              maxAttempts: 5,
            ),
            isFalse,
            reason: 'status=$status attempts=$attempts',
          );
        }
      }
    });

    test('nextSeedFor returns null', () {
      expect(
        policy.nextSeedFor(
          spec: _spec(),
          lastResult: _result(),
          attemptsSoFar: 1,
        ),
        isNull,
      );
    });
  });
}
