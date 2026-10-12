// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/features/dashboard/models/dashboard_column_layout.dart';
import 'package:simcrux/features/dashboard/models/dashboard_sort.dart';
import 'package:simcrux/features/dashboard/services/dashboard_column_layout_codec.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DashboardColumnLayout', () {
    final defaults = DashboardColumnLayout.defaults;
    // 100 px per unit of weight: the default weights total 10.4.
    const tableWidth = 1040.0;

    test('a missing or invalid weight takes its default', () {
      final layout = DashboardColumnLayout(const {
        DashboardSortColumn.suite: 4,
        DashboardSortColumn.testName: double.nan,
        DashboardSortColumn.duration: -1,
      });
      expect(layout.weights[DashboardSortColumn.suite], 4);
      expect(
        layout.weights[DashboardSortColumn.testName],
        DashboardColumnLayout.defaultWeights[DashboardSortColumn.testName],
      );
      expect(
        layout.weights[DashboardSortColumn.duration],
        DashboardColumnLayout.defaultWeights[DashboardSortColumn.duration],
      );
    });

    test('the status column resizes against Suite', () {
      final after = defaults.resize(DashboardSortColumn.status, 50, tableWidth);
      expect(
        after.weights[DashboardSortColumn.status]! +
            after.weights[DashboardSortColumn.suite]!,
        closeTo(
          defaults.weights[DashboardSortColumn.status]! +
              defaults.weights[DashboardSortColumn.suite]!,
          1e-9,
        ),
      );
      expect(
        after.weights[DashboardSortColumn.status],
        greaterThan(defaults.weights[DashboardSortColumn.status]!),
      );
    });

    test('a drag moves width between the two neighbours only', () {
      final after = defaults.resize(DashboardSortColumn.suite, 100, tableWidth);
      final perPixel = defaults.totalWeight / tableWidth;
      expect(
        after.weights[DashboardSortColumn.suite],
        closeTo(
          defaults.weights[DashboardSortColumn.suite]! + 100 * perPixel,
          1e-9,
        ),
      );
      expect(
        after.weights[DashboardSortColumn.testName],
        closeTo(
          defaults.weights[DashboardSortColumn.testName]! - 100 * perPixel,
          1e-9,
        ),
      );
      expect(after.totalWeight, closeTo(defaults.totalWeight, 1e-9));
      for (final c in [
        DashboardSortColumn.status,
        DashboardSortColumn.simulator,
        DashboardSortColumn.duration,
        DashboardSortColumn.startedAt,
      ]) {
        expect(after.weights[c], defaults.weights[c]);
      }
    });

    test('neither neighbour shrinks below the minimum width', () {
      final after = defaults.resize(
        DashboardSortColumn.suite,
        100000,
        tableWidth,
      );
      final perPixel = defaults.totalWeight / tableWidth;
      expect(
        after.weights[DashboardSortColumn.testName],
        closeTo(DashboardColumnLayout.minColumnWidth * perPixel, 1e-9),
      );
    });

    test('the last column has no divider to drag', () {
      expect(
        defaults.resize(DashboardSortColumn.startedAt, 50, tableWidth),
        same(defaults),
      );
    });
  });

  group('DashboardColumnLayoutCodec', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('nothing stored reads as the defaults', () async {
      final prefs = await SharedPreferences.getInstance();
      expect(
        await const DashboardColumnLayoutCodec().load(prefs),
        DashboardColumnLayout.defaults,
      );
    });

    test('round-trips every weight', () async {
      final prefs = await SharedPreferences.getInstance();
      const codec = DashboardColumnLayoutCodec();
      final layout = DashboardColumnLayout.defaults.resize(
        DashboardSortColumn.simulator,
        30,
        1000,
      );
      await codec.save(prefs, layout);
      expect(await codec.load(prefs), layout);
    });

    test('malformed JSON reads as the defaults', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        DashboardColumnLayoutCodec.prefsKey: '{not json',
      });
      final prefs = await SharedPreferences.getInstance();
      expect(
        await const DashboardColumnLayoutCodec().load(prefs),
        DashboardColumnLayout.defaults,
      );
    });
  });
}
