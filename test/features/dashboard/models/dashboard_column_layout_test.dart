// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/features/dashboard/models/dashboard_column_layout.dart';
import 'package:simcrux/features/dashboard/models/dashboard_sort.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_column_layout_provider.dart';

// The layout arithmetic is crux_table's and tested there; these pin what
// SimCrux contributes: its columns, their default weights, the order the
// dividers resize in, and the preference key saved widths come back from.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('dashboardColumns', () {
    final defaults = dashboardColumns.defaults;
    // 100 px per unit of weight: the default weights total 12.2.
    const tableWidth = 1220.0;

    test('every column has a default weight and the order is the table', () {
      expect(dashboardColumns.columns, [
        DashboardSortColumn.status,
        DashboardSortColumn.verdict,
        DashboardSortColumn.suite,
        DashboardSortColumn.testName,
        DashboardSortColumn.simulator,
        DashboardSortColumn.duration,
        DashboardSortColumn.startedAt,
      ]);
      expect(defaults.totalWeight, closeTo(12.2, 1e-9));
      expect(defaults.isDefault, isTrue);
    });

    test('a layout saved before the Verdict column gives it its default', () {
      // An earlier build stored six weights; the seventh column takes its
      // default and the six keep theirs.
      final layout = DashboardColumnLayout(dashboardColumns, const {
        DashboardSortColumn.status: 1.2,
        DashboardSortColumn.suite: 2.5,
      });
      expect(
        layout.weights[DashboardSortColumn.verdict],
        dashboardColumns.defaultWeights[DashboardSortColumn.verdict],
      );
      expect(layout.weights[DashboardSortColumn.suite], 2.5);
    });

    test('a missing or invalid weight takes its default', () {
      final layout = DashboardColumnLayout(dashboardColumns, const {
        DashboardSortColumn.suite: 4,
        DashboardSortColumn.testName: double.nan,
        DashboardSortColumn.duration: -1,
      });
      expect(layout.weights[DashboardSortColumn.suite], 4);
      expect(
        layout.weights[DashboardSortColumn.testName],
        dashboardColumns.defaultWeights[DashboardSortColumn.testName],
      );
      expect(
        layout.weights[DashboardSortColumn.duration],
        dashboardColumns.defaultWeights[DashboardSortColumn.duration],
      );
    });

    test('the status column resizes against Verdict', () {
      final after = defaults.resize(DashboardSortColumn.status, 50, tableWidth);
      expect(
        after.weights[DashboardSortColumn.status]! +
            after.weights[DashboardSortColumn.verdict]!,
        closeTo(
          defaults.weights[DashboardSortColumn.status]! +
              defaults.weights[DashboardSortColumn.verdict]!,
          1e-9,
        ),
      );
      expect(
        after.weights[DashboardSortColumn.status],
        greaterThan(defaults.weights[DashboardSortColumn.status]!),
      );
    });

    test('neither neighbour shrinks below the minimum width', () {
      final after = defaults.resize(
        DashboardSortColumn.suite,
        -10000,
        tableWidth,
      );
      final perPixel = defaults.totalWeight / tableWidth;
      expect(
        after.weights[DashboardSortColumn.suite],
        closeTo(dashboardColumns.minColumnWidth * perPixel, 1e-9),
      );
    });

    test('the last column has no divider to drag', () {
      expect(
        defaults.resize(DashboardSortColumn.startedAt, 50, tableWidth),
        defaults,
      );
    });
  });

  group('the column layout preference', () {
    final codec = dashboardColumnLayoutProviders.codec;

    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('is the key SimCrux wrote before the lift', () {
      // Widths saved by an earlier build must come back under crux_table.
      expect(codec.prefsKey, 'simcrux.dashboardColumnWeights');
    });

    test('nothing stored reads as the defaults', () async {
      final prefs = await SharedPreferences.getInstance();
      expect(await codec.load(prefs), dashboardColumns.defaults);
    });

    test('round-trips every weight', () async {
      final prefs = await SharedPreferences.getInstance();
      final layout = dashboardColumns.defaults.resize(
        DashboardSortColumn.simulator,
        30,
        1000,
      );
      await codec.save(prefs, layout);
      expect(await codec.load(prefs), layout);
    });

    test('reads the JSON an earlier build saved', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        codec.prefsKey:
            '{"status":1.2,"suite":2.5,"testName":2.5,"simulator":1.4,'
            '"duration":1.2,"startedAt":1.6}',
      });
      final prefs = await SharedPreferences.getInstance();
      final loaded = await codec.load(prefs);
      expect(loaded.weights[DashboardSortColumn.suite], 2.5);
      expect(loaded.weights[DashboardSortColumn.testName], 2.5);
    });

    test('malformed JSON reads as the defaults', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        codec.prefsKey: '{not json',
      });
      final prefs = await SharedPreferences.getInstance();
      expect(await codec.load(prefs), dashboardColumns.defaults);
    });
  });
}
