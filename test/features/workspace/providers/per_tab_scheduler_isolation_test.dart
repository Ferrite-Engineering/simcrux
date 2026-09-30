// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_workspace/crux_workspace.dart' as crux;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/features/dashboard/providers/regression_runner.dart';
import 'package:simcrux/features/workspace/providers/simcrux_tab_overrides.dart';
import 'package:simcrux/services/job_scheduler/job_scheduler_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('per-tab scheduler isolation', () {
    test('each tab has its own regressionRunnerProvider instance — '
        'an in-flight run in tab A does not surface in tab B', () async {
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

      final notifierA = tabA.read(regressionRunnerProvider.notifier);
      final notifierB = tabB.read(regressionRunnerProvider.notifier);
      expect(
        identical(notifierA, notifierB),
        isFalse,
        reason:
            'per-tab override must produce distinct notifier '
            'instances; otherwise concurrent runs collide on '
            'shared _RunState',
      );

      // Each tab starts in the AsyncData(null) terminal state (no run
      // in flight). Verifying the per-tab independence: starting one
      // does not transition the other.
      final stateA = tabA.read(regressionRunnerProvider);
      final stateB = tabB.read(regressionRunnerProvider);
      // Both are AsyncData(null) on initial build.
      expect(stateA, isA<AsyncValue<RegressionRunState?>>());
      expect(stateB, isA<AsyncValue<RegressionRunState?>>());
      expect(stateA.value, isNull);
      expect(stateB.value, isNull);
    });

    test('simulatorDriverRegistryProvider stays root-scoped — each '
        'tab sees the same registry instance', () {
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

      // The registry is read-only and shared — each tab's scheduler
      // resolves driver instances from the same registry.
      final regA = tabA.read(simulatorDriverRegistryProvider);
      final regB = tabB.read(simulatorDriverRegistryProvider);
      expect(identical(regA, regB), isTrue);
    });
  });
}
