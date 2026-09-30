// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/flakiness_config.dart';

void main() {
  group('FlakinessConfig', () {
    test('defaults are the documented window, thresholds and retry', () {
      const c = FlakinessConfig();
      expect(c.windowSize, 50);
      expect(c.flakyThreshold, 0.05);
      expect(c.highlyFlakyThreshold, 0.40);
      expect(c.recencyDecay, 0.3);
      expect(c.autoRetryEnabled, isFalse);
      expect(c.autoRetryAttempts, 3);
    });

    test('copyWith replaces specified fields and preserves others', () {
      const c = FlakinessConfig();
      final c2 = c.copyWith(windowSize: 100, autoRetryEnabled: true);
      expect(c2.windowSize, 100);
      expect(c2.autoRetryEnabled, isTrue);
      expect(c2.flakyThreshold, c.flakyThreshold);
      expect(c2.highlyFlakyThreshold, c.highlyFlakyThreshold);
      expect(c2.recencyDecay, c.recencyDecay);
      expect(c2.autoRetryAttempts, c.autoRetryAttempts);
    });

    test('equality matches on every field', () {
      const a = FlakinessConfig(
        windowSize: 25,
        flakyThreshold: 0.1,
        highlyFlakyThreshold: 0.5,
        recencyDecay: 0.5,
        autoRetryEnabled: true,
        autoRetryAttempts: 4,
      );
      const b = FlakinessConfig(
        windowSize: 25,
        flakyThreshold: 0.1,
        highlyFlakyThreshold: 0.5,
        recencyDecay: 0.5,
        autoRetryEnabled: true,
        autoRetryAttempts: 4,
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('asserts windowSize > 0', () {
      expect(
        () => FlakinessConfig(windowSize: 0),
        throwsA(isA<AssertionError>()),
      );
    });

    test('asserts thresholds in (0, 1)', () {
      expect(
        () => FlakinessConfig(flakyThreshold: -0.1),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => FlakinessConfig(flakyThreshold: 1.1),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => FlakinessConfig(highlyFlakyThreshold: 1.5),
        throwsA(isA<AssertionError>()),
      );
    });

    test('asserts highlyFlakyThreshold >= flakyThreshold', () {
      expect(
        () => FlakinessConfig(
          flakyThreshold: 0.5,
          highlyFlakyThreshold: 0.1,
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('asserts recencyDecay in [0, 1]', () {
      expect(
        () => FlakinessConfig(recencyDecay: -0.1),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => FlakinessConfig(recencyDecay: 1.1),
        throwsA(isA<AssertionError>()),
      );
    });

    test('asserts autoRetryAttempts in [0, 5]', () {
      expect(
        () => FlakinessConfig(autoRetryAttempts: -1),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => FlakinessConfig(autoRetryAttempts: 6),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
