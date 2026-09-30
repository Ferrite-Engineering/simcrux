// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/trend_aggregate.dart';

void main() {
  group('TrendAggregateKey', () {
    test('convenience constructors set the right kind', () {
      const a = TrendAggregateKey.perTest('test_a');
      expect(a.kind, TrendAggregateKeyKind.perTest);
      expect(a.id, 'test_a');

      const b = TrendAggregateKey.perSuite('suite_a');
      expect(b.kind, TrendAggregateKeyKind.perSuite);
      expect(b.id, 'suite_a');

      const c = TrendAggregateKey.global();
      expect(c.kind, TrendAggregateKeyKind.global);
      expect(c.id, isNull);
    });

    test('equality + hashCode are value-based', () {
      const a = TrendAggregateKey.perTest('x');
      const b = TrendAggregateKey.perTest('x');
      const c = TrendAggregateKey.perTest('y');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });

  group('TrendAggregate', () {
    final start = DateTime.utc(2026, 5, 2);
    final end = DateTime.utc(2026, 5, 3);

    test('passRate returns 0 when totalRuns == 0', () {
      final agg = TrendAggregate(
        key: const TrendAggregateKey.global(),
        windowStart: start,
        windowEnd: end,
        totalRuns: 0,
        passCount: 0,
        failCount: 0,
        skipCount: 0,
      );
      expect(agg.passRate, 0);
    });

    test('passRate equals passCount / totalRuns', () {
      final agg = TrendAggregate(
        key: const TrendAggregateKey.global(),
        windowStart: start,
        windowEnd: end,
        totalRuns: 10,
        passCount: 7,
        failCount: 2,
        skipCount: 1,
      );
      expect(agg.passRate, closeTo(0.7, 1e-9));
    });

    test('copyWith replaces individual fields', () {
      final base = TrendAggregate(
        key: const TrendAggregateKey.global(),
        windowStart: start,
        windowEnd: end,
        totalRuns: 5,
        passCount: 5,
        failCount: 0,
        skipCount: 0,
      );
      final updated = base.copyWith(failCount: 2);
      expect(updated.failCount, 2);
      expect(updated.passCount, 5);
    });
  });

  group('computeRuntimePercentiles', () {
    test('returns all-null on empty input', () {
      final r = computeRuntimePercentiles(const <int>[]);
      expect(r.p50, isNull);
      expect(r.p95, isNull);
      expect(r.p99, isNull);
    });

    test('single value populates every percentile', () {
      final r = computeRuntimePercentiles(const [42]);
      expect(r.p50, 42);
      expect(r.p95, 42);
      expect(r.p99, 42);
    });

    test('nearest-rank ordering across 100 sorted values', () {
      final values = List<int>.generate(100, (i) => i + 1); // 1..100
      final r = computeRuntimePercentiles(values);
      // ceil(0.50 * 100) - 1 = 49 -> values[49] = 50
      expect(r.p50, 50);
      // ceil(0.95 * 100) - 1 = 94 -> 95
      expect(r.p95, 95);
      // ceil(0.99 * 100) - 1 = 98 -> 99
      expect(r.p99, 99);
    });

    test('input order is not significant', () {
      final r = computeRuntimePercentiles(const [9, 4, 7, 1, 5, 3, 8, 2, 6]);
      expect(r.p50, 5);
      expect(r.p95, 9);
      expect(r.p99, 9);
    });
  });
}
