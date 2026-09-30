// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/trend_alert.dart';

void main() {
  group('TrendAlert', () {
    test('fingerprint composes kind / suite / test for stable identity', () {
      const a = TrendAlert(
        kind: TrendAlertKind.runtimeRegression,
        severity: TrendAlertSeverity.warning,
        testId: 'test_x',
        suiteId: 'suite_a',
        detectedAtRunId: 'r1',
        firstObservedAtRunId: 'r1',
      );
      expect(a.fingerprint, 'runtimeRegression::suite_a::test_x');
    });

    test('fingerprint handles null testId / suiteId gracefully', () {
      const suiteAlert = TrendAlert(
        kind: TrendAlertKind.newPersistentFailure,
        severity: TrendAlertSeverity.critical,
        suiteId: 'suite_a',
        detectedAtRunId: 'r2',
        firstObservedAtRunId: 'r1',
      );
      expect(suiteAlert.fingerprint, 'newPersistentFailure::suite_a::');

      const global = TrendAlert(
        kind: TrendAlertKind.flipFlopRunDetected,
        severity: TrendAlertSeverity.info,
        detectedAtRunId: 'r3',
        firstObservedAtRunId: 'r3',
      );
      expect(global.fingerprint, 'flipFlopRunDetected::::');
    });

    test('copyWith clears optional numeric fields when requested', () {
      const base = TrendAlert(
        kind: TrendAlertKind.runtimeRegression,
        severity: TrendAlertSeverity.warning,
        testId: 't',
        baselineValue: 100,
        currentValue: 200,
        deltaPercent: 1,
        detectedAtRunId: 'r2',
        firstObservedAtRunId: 'r1',
      );
      final cleared = base.copyWith(
        clearBaseline: true,
        clearCurrent: true,
        clearDelta: true,
      );
      expect(cleared.baselineValue, isNull);
      expect(cleared.currentValue, isNull);
      expect(cleared.deltaPercent, isNull);
    });

    test('equality + hashCode are value-based', () {
      const a = TrendAlert(
        kind: TrendAlertKind.runtimeRegression,
        severity: TrendAlertSeverity.warning,
        testId: 't',
        detectedAtRunId: 'r1',
        firstObservedAtRunId: 'r1',
      );
      const b = TrendAlert(
        kind: TrendAlertKind.runtimeRegression,
        severity: TrendAlertSeverity.warning,
        testId: 't',
        detectedAtRunId: 'r1',
        firstObservedAtRunId: 'r1',
      );
      const c = TrendAlert(
        kind: TrendAlertKind.runtimeRegression,
        severity: TrendAlertSeverity.critical,
        testId: 't',
        detectedAtRunId: 'r1',
        firstObservedAtRunId: 'r1',
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });
}
