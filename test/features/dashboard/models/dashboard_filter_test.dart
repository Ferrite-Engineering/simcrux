// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/features/dashboard/models/dashboard_filter.dart';

void main() {
  group('DashboardFilter', () {
    test('unset is fully empty', () {
      expect(DashboardFilter.unset.isUnset, isTrue);
      expect(DashboardFilter.unset.statuses, isEmpty);
      expect(DashboardFilter.unset.suites, isEmpty);
      expect(DashboardFilter.unset.simulators, isEmpty);
      expect(DashboardFilter.unset.testNameSubstring, '');
      expect(DashboardFilter.unset.minRuntime, isNull);
      expect(DashboardFilter.unset.maxRuntime, isNull);
    });

    test('copyWith replaces only the supplied fields', () {
      final base = DashboardFilter(
        statuses: const {TestStatus.pass},
        testNameSubstring: 'foo',
      );
      final next = base.copyWith(statuses: const {TestStatus.fail});
      expect(next.statuses, const {TestStatus.fail});
      expect(next.testNameSubstring, 'foo');
    });

    test('== and hashCode honor unordered set comparisons', () {
      final a = DashboardFilter(
        statuses: const {TestStatus.pass, TestStatus.fail},
        suites: const {'unit', 'random'},
      );
      final b = DashboardFilter(
        statuses: const {TestStatus.fail, TestStatus.pass},
        suites: const {'random', 'unit'},
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });
  });
}
