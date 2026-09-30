// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/retention_policy.dart';

void main() {
  group('RetentionPolicy', () {
    test('defaultPolicy carries the documented defaults', () {
      const policy = RetentionPolicy.defaultPolicy;
      expect(policy.maxAgeDays, 30);
      expect(policy.maxDataPoints, 50000);
      expect(policy.pruneStrategy, RetentionPruneStrategy.oldestFirst);
      expect(policy.isUnlimited, isFalse);
    });

    test('unlimited has both bounds null and reports unlimited', () {
      const policy = RetentionPolicy.unlimited;
      expect(policy.maxAgeDays, isNull);
      expect(policy.maxDataPoints, isNull);
      expect(policy.isUnlimited, isTrue);
    });

    test('copyWith respects clear flags', () {
      const base = RetentionPolicy(maxAgeDays: 7, maxDataPoints: 100);
      final clearedAge = base.copyWith(clearMaxAge: true);
      expect(clearedAge.maxAgeDays, isNull);
      expect(clearedAge.maxDataPoints, 100);

      final clearedPoints = base.copyWith(clearMaxPoints: true);
      expect(clearedPoints.maxAgeDays, 7);
      expect(clearedPoints.maxDataPoints, isNull);

      final updated = base.copyWith(maxAgeDays: 14);
      expect(updated.maxAgeDays, 14);
      expect(updated.maxDataPoints, 100);
    });

    test('toJson / fromJson round-trip every field', () {
      const original = RetentionPolicy(
        maxAgeDays: 60,
        maxDataPoints: 1000,
        pruneStrategy: RetentionPruneStrategy.lowestValueFirst,
      );
      final decoded = RetentionPolicy.fromJson(original.toJson());
      expect(decoded, original);
    });

    test('fromJson tolerates missing fields with safe fallbacks', () {
      final decoded = RetentionPolicy.fromJson(const <String, Object?>{});
      // Missing fields ⇒ null limits + default strategy.
      expect(decoded.maxAgeDays, isNull);
      expect(decoded.maxDataPoints, isNull);
      expect(decoded.pruneStrategy, RetentionPruneStrategy.oldestFirst);
    });

    test('fromJson accepts numeric strings via num.toInt', () {
      final decoded = RetentionPolicy.fromJson(const <String, Object?>{
        'maxAgeDays': 90.0,
        'maxDataPoints': 250.0,
        'pruneStrategy': 'lowestValueFirst',
      });
      expect(decoded.maxAgeDays, 90);
      expect(decoded.maxDataPoints, 250);
      expect(decoded.pruneStrategy, RetentionPruneStrategy.lowestValueFirst);
    });

    test('equality + hashCode are value-based', () {
      const a = RetentionPolicy(maxAgeDays: 30, maxDataPoints: 100);
      const b = RetentionPolicy(maxAgeDays: 30, maxDataPoints: 100);
      const c = RetentionPolicy(maxAgeDays: 30, maxDataPoints: 200);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });
}
