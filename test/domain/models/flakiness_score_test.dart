// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/flakiness_score.dart';

void main() {
  final windowStart = DateTime.utc(2026);
  final windowEnd = DateTime.utc(2026, 5, 25);

  group('FlakinessScore', () {
    test('equality matches on every field', () {
      final a = FlakinessScore(
        testId: 'cpu.alu_test',
        score: 0.12,
        classification: FlakyClassification.flaky,
        totalRuns: 50,
        passRuns: 44,
        failRuns: 6,
        otherRuns: 0,
        statusFlips: 5,
        lastFailureAt: DateTime.utc(2026, 5, 20),
        lastSuccessAt: DateTime.utc(2026, 5, 24),
        windowStart: windowStart,
        windowEnd: windowEnd,
      );
      final b = FlakinessScore(
        testId: 'cpu.alu_test',
        score: 0.12,
        classification: FlakyClassification.flaky,
        totalRuns: 50,
        passRuns: 44,
        failRuns: 6,
        otherRuns: 0,
        statusFlips: 5,
        lastFailureAt: DateTime.utc(2026, 5, 20),
        lastSuccessAt: DateTime.utc(2026, 5, 24),
        windowStart: windowStart,
        windowEnd: windowEnd,
      );

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('isFlaky is true for flaky and highlyFlaky classifications', () {
      FlakinessScore make(FlakyClassification c) => FlakinessScore(
        testId: 't',
        score: 0.3,
        classification: c,
        totalRuns: 10,
        passRuns: 7,
        failRuns: 3,
        otherRuns: 0,
        statusFlips: 2,
        lastFailureAt: null,
        lastSuccessAt: null,
        windowStart: windowStart,
        windowEnd: windowEnd,
      );

      expect(make(FlakyClassification.flaky).isFlaky, isTrue);
      expect(make(FlakyClassification.highlyFlaky).isFlaky, isTrue);
      expect(make(FlakyClassification.intermittent).isFlaky, isFalse);
      expect(make(FlakyClassification.stable).isFlaky, isFalse);
      expect(make(FlakyClassification.consistentlyFailing).isFlaky, isFalse);
    });

    test('asserts score in [0, 1]', () {
      expect(
        () => FlakinessScore(
          testId: 't',
          score: 1.5,
          classification: FlakyClassification.flaky,
          totalRuns: 1,
          passRuns: 0,
          failRuns: 1,
          otherRuns: 0,
          statusFlips: 0,
          lastFailureAt: null,
          lastSuccessAt: null,
          windowStart: windowStart,
          windowEnd: windowEnd,
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('TestStatusFlakyCategory', () {
    test('only pass is a flaky pass', () {
      expect(TestStatus.pass.isFlakyPass, isTrue);
      expect(TestStatus.fail.isFlakyPass, isFalse);
      expect(TestStatus.vacuous.isFlakyPass, isFalse);
      expect(TestStatus.cover.isFlakyPass, isFalse);
      expect(TestStatus.timeout.isFlakyPass, isFalse);
    });

    test('fail and timeout are flaky fails; cancelled / vacuous are not', () {
      expect(TestStatus.fail.isFlakyFail, isTrue);
      expect(TestStatus.timeout.isFlakyFail, isTrue);
      expect(TestStatus.pass.isFlakyFail, isFalse);
      expect(TestStatus.cancelled.isFlakyFail, isFalse);
      expect(TestStatus.vacuous.isFlakyFail, isFalse);
      expect(TestStatus.cover.isFlakyFail, isFalse);
      expect(TestStatus.skipped.isFlakyFail, isFalse);
      expect(TestStatus.running.isFlakyFail, isFalse);
      expect(TestStatus.unknown.isFlakyFail, isFalse);
    });
  });
}
