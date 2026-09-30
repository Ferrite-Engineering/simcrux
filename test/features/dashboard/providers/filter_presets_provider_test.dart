// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/features/dashboard/models/dashboard_filter.dart';
import 'package:simcrux/features/dashboard/providers/filter_presets_provider.dart';

void main() {
  group('FilterPresetsNotifier', () {
    test('ships two default presets (Failures, Passing)', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final presets = container.read(filterPresetsProvider);
      expect(presets.map((p) => p.name), ['Failures', 'Passing']);
    });

    test('save appends a new preset and remove drops it', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(filterPresetsProvider.notifier)
        ..save('AXI only', DashboardFilter(suites: const {'axi'}))
        ..remove('AXI only');
      final presets = container.read(filterPresetsProvider);
      expect(presets.any((p) => p.name == 'AXI only'), isFalse);
    });

    test('save replaces an existing preset of the same name', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(filterPresetsProvider.notifier)
        ..save('Quick', DashboardFilter(statuses: const {TestStatus.pass}))
        ..save('Quick', DashboardFilter(statuses: const {TestStatus.fail}));
      final preset = container
          .read(filterPresetsProvider)
          .firstWhere((p) => p.name == 'Quick');
      expect(preset.filter.statuses, equals(const {TestStatus.fail}));
    });
  });
}
