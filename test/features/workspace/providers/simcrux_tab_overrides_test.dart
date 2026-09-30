// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_workspace/crux_workspace.dart' as crux;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/features/dashboard/models/dashboard_filter.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/workspace/providers/simcrux_tab_overrides.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('simcruxTabOverrides', () {
    test('returns a non-empty override list including the dashboard '
        'filter notifier', () {
      final overrides = simcruxTabOverrides(crux.TabId.generate());
      expect(overrides, isNotEmpty);
    });

    test('per-tab containers isolate filter mutations', () {
      final root = ProviderContainer();
      addTearDown(root.dispose);
      final tabA = ProviderContainer(
        parent: root,
        overrides: simcruxTabOverrides(crux.TabId.generate()),
      );
      addTearDown(tabA.dispose);
      final tabB = ProviderContainer(
        parent: root,
        overrides: simcruxTabOverrides(crux.TabId.generate()),
      );
      addTearDown(tabB.dispose);

      tabA.read(dashboardFilterProvider.notifier).toggleStatus(TestStatus.fail);
      final aFilter = tabA.read(dashboardFilterProvider);
      final bFilter = tabB.read(dashboardFilterProvider);
      expect(aFilter.statuses, const {TestStatus.fail});
      expect(bFilter, DashboardFilter.unset);
    });

    test('per-tab containers isolate active-config mutations', () {
      final root = ProviderContainer();
      addTearDown(root.dispose);
      final tabA = ProviderContainer(
        parent: root,
        overrides: simcruxTabOverrides(crux.TabId.generate()),
      );
      addTearDown(tabA.dispose);
      final tabB = ProviderContainer(
        parent: root,
        overrides: simcruxTabOverrides(crux.TabId.generate()),
      );
      addTearDown(tabB.dispose);

      final cfg = RegressionConfig(
        projectFilePath: '/p/a.yaml',
        schemaVersion: '1',
        suites: const [],
        simulatorBinaries: const {},
      );
      tabA.read(activeConfigProvider.notifier).replace(cfg);
      expect(tabA.read(activeConfigProvider), cfg);
      expect(tabB.read(activeConfigProvider), isNull);
    });

    test('per-tab containers isolate config-load-error state '
        "(tab A's broken-YAML banner must not render in tab B)", () {
      final root = ProviderContainer();
      addTearDown(root.dispose);
      final tabA = ProviderContainer(
        parent: root,
        overrides: simcruxTabOverrides(crux.TabId.generate()),
      );
      addTearDown(tabA.dispose);
      final tabB = ProviderContainer(
        parent: root,
        overrides: simcruxTabOverrides(crux.TabId.generate()),
      );
      addTearDown(tabB.dispose);

      const error = ConfigLoadError(
        path: '/p/a.yaml',
        message: 'mapping values are not allowed here',
      );
      tabA.read(configLoadErrorProvider.notifier).record(error);
      expect(tabA.read(configLoadErrorProvider), error);
      expect(
        tabB.read(configLoadErrorProvider),
        isNull,
        reason: "tab A's load error must not surface in tab B",
      );

      // Clearing from tab B (e.g. its own successful load) must not
      // wipe tab A's diagnostic.
      tabB.read(configLoadErrorProvider.notifier).clear();
      expect(tabA.read(configLoadErrorProvider), error);
    });

    test('per-tab containers isolate selection mutations', () {
      final root = ProviderContainer();
      addTearDown(root.dispose);
      final tabA = ProviderContainer(
        parent: root,
        overrides: simcruxTabOverrides(crux.TabId.generate()),
      );
      addTearDown(tabA.dispose);
      final tabB = ProviderContainer(
        parent: root,
        overrides: simcruxTabOverrides(crux.TabId.generate()),
      );
      addTearDown(tabB.dispose);

      tabA.read(dashboardSelectionProvider.notifier).toggle('alu/add');
      expect(tabA.read(dashboardSelectionProvider), {'alu/add'});
      expect(tabB.read(dashboardSelectionProvider), isEmpty);
    });
  });
}
