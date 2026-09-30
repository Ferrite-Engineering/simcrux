// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/dashboard_view_mode.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/features/dashboard/models/dashboard_sort.dart';
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';

void main() {
  group('SimcruxTabPayload', () {
    test('default construction holds empty filter chips + table view', () {
      final payload = SimcruxTabPayload(configPath: '/p/a.yaml');
      expect(payload.configPath, '/p/a.yaml');
      expect(payload.selectedTestId, isNull);
      expect(payload.filterStatuses, isEmpty);
      expect(payload.filterSuites, isEmpty);
      expect(payload.filterSimulators, isEmpty);
      expect(payload.filterTestNameSubstring, '');
      expect(payload.sort, const DashboardSort());
      expect(payload.viewMode, DashboardViewMode.table);
      expect(payload.expandedSuites, isEmpty);
    });

    test('all set fields are unmodifiable views', () {
      final payload = SimcruxTabPayload(
        configPath: '/p/a.yaml',
        filterStatuses: const {TestStatus.fail},
        filterSuites: const {'alu'},
        filterSimulators: const {'icarus'},
        expandedSuites: const {'alu'},
      );
      expect(
        () => payload.filterStatuses.add(TestStatus.pass),
        throwsUnsupportedError,
      );
      expect(
        () => payload.filterSuites.add('cpu'),
        throwsUnsupportedError,
      );
      expect(
        () => payload.filterSimulators.add('verilator'),
        throwsUnsupportedError,
      );
      expect(
        () => payload.expandedSuites.add('cpu'),
        throwsUnsupportedError,
      );
    });

    test('value equality across fields', () {
      final a = SimcruxTabPayload(
        configPath: '/p/a.yaml',
        selectedTestId: 'alu/add',
        filterStatuses: const {TestStatus.fail},
        filterSuites: const {'alu'},
        filterSimulators: const {'icarus'},
        filterTestNameSubstring: 'add',
        sort: const DashboardSort(
          column: DashboardSortColumn.duration,
        ),
        viewMode: DashboardViewMode.heatmap,
        expandedSuites: const {'alu'},
      );
      final b = SimcruxTabPayload(
        configPath: '/p/a.yaml',
        selectedTestId: 'alu/add',
        filterStatuses: const {TestStatus.fail},
        filterSuites: const {'alu'},
        filterSimulators: const {'icarus'},
        filterTestNameSubstring: 'add',
        sort: const DashboardSort(
          column: DashboardSortColumn.duration,
        ),
        viewMode: DashboardViewMode.heatmap,
        expandedSuites: const {'alu'},
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('inequality detected on any single field', () {
      final base = SimcruxTabPayload(
        configPath: '/p/a.yaml',
        filterStatuses: const {TestStatus.fail},
      );
      expect(base == base.copyWith(configPath: '/p/b.yaml'), isFalse);
      expect(base == base.copyWith(selectedTestId: 'alu/add'), isFalse);
      expect(
        base == base.copyWith(filterStatuses: const {TestStatus.pass}),
        isFalse,
      );
      expect(
        base == base.copyWith(filterSuites: const {'alu'}),
        isFalse,
      );
      expect(
        base == base.copyWith(viewMode: DashboardViewMode.heatmap),
        isFalse,
      );
    });

    test('copyWith replaces only specified fields', () {
      final base = SimcruxTabPayload(
        configPath: '/p/a.yaml',
        selectedTestId: 'alu/add',
        filterStatuses: const {TestStatus.pass},
      );
      final next = base.copyWith(viewMode: DashboardViewMode.heatmap);
      expect(next.configPath, base.configPath);
      expect(next.selectedTestId, base.selectedTestId);
      expect(next.filterStatuses, base.filterStatuses);
      expect(next.viewMode, DashboardViewMode.heatmap);
    });

    test('clearSelectedTestId nukes the selection regardless of '
        'selectedTestId arg', () {
      final base = SimcruxTabPayload(
        configPath: '/p/a.yaml',
        selectedTestId: 'alu/add',
      );
      final cleared = base.copyWith(clearSelectedTestId: true);
      expect(cleared.selectedTestId, isNull);
      final stillCleared = base.copyWith(
        selectedTestId: 'alu/sub',
        clearSelectedTestId: true,
      );
      expect(stillCleared.selectedTestId, isNull);
    });
  });
}
