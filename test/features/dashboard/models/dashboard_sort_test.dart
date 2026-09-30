// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/features/dashboard/models/dashboard_sort.dart';

void main() {
  group('DashboardSort.toggle', () {
    test('switching to a new column resets to ascending', () {
      const base = DashboardSort(); // defaults: startedAt, descending
      final next = base.toggle(DashboardSortColumn.suite);
      expect(next.column, DashboardSortColumn.suite);
      expect(next.direction, DashboardSortDirection.ascending);
    });

    test('clicking the same column flips ascending → descending', () {
      const base = DashboardSort(
        column: DashboardSortColumn.suite,
        direction: DashboardSortDirection.ascending,
      );
      final next = base.toggle(DashboardSortColumn.suite);
      expect(next.column, DashboardSortColumn.suite);
      expect(next.direction, DashboardSortDirection.descending);
    });

    test(
      'clicking the same column twice returns to the starting direction',
      () {
        // The default sort is descending. Toggling the same column twice
        // visits ascending then returns to descending.
        const base = DashboardSort();
        final next = base
            .toggle(DashboardSortColumn.startedAt)
            .toggle(DashboardSortColumn.startedAt);
        expect(next.direction, DashboardSortDirection.descending);
      },
    );
  });
}
