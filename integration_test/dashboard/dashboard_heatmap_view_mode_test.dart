// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// integration_test/dashboard/dashboard_heatmap_view_mode_test.dart
//
// Heatmap view-mode journey: a seeded run populates the dashboard, the
// `DashboardViewModeToggle` segmented control switches
// `dashboardViewModeProvider` from table to heatmap, and
// `DashboardHeatmapView` renders one cell per seeded test (asserted via
// each cell's `Tooltip` message, which encodes `suite/test · status`).
// Tapping a heatmap cell also drives the shared inspector selection, same
// as a table row tap.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:simcrux/features/dashboard/widgets/dashboard_heatmap_view.dart';
import 'package:simcrux/features/dashboard/widgets/dashboard_results_table.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

import '../helpers/app_driver.dart';
import '../helpers/seeded_run.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  suppressPlatformSemanticsLeak();

  testWidgets(
    'view-mode toggle switches the dashboard from table to heatmap and '
    'the heatmap renders one cell per seeded test',
    (tester) async {
      final project = await writeSeededProject(
        tests: const [
          SeededTest('smoke', 'alu_pass', [ScriptedOutcome.passed()]),
          SeededTest('smoke', 'alu_fail', [
            ScriptedOutcome.failed(
              stderrLines: ['seeded: ERROR intentional alu failure'],
            ),
          ]),
        ],
      );
      final driver = ScriptedDriver(project.outcomesByTestName);

      await bootSimcrux(
        tester,
        args: [project.configPath],
        extraOverrides: [seededDriverRegistryOverride(driver)],
      );
      await pumpUntil(tester, () => tabCount(tester) == 1);
      final tab = tabContainerFor(tester);
      await startSeededRun(tester, tab);
      await pumpUntilRunFinished(tester, tab, expectedResults: 2);

      final l10n = L10N.of(tester.element(find.byType(Scaffold).first));

      // Table view is the default — confirm before switching.
      final tableShown = await pumpUntil(
        tester,
        () => find.byType(DashboardResultsTable).evaluate().isNotEmpty,
      );
      expect(tableShown, isTrue, reason: 'table must be the default view');

      // ── Toggle to heatmap ─────────────────────────────────────────────
      await tester.tap(find.text(l10n.dashboardViewModeHeatmap));
      final heatmapShown = await pumpUntil(
        tester,
        () =>
            find.byType(DashboardHeatmapView).evaluate().isNotEmpty &&
            find.byType(DashboardResultsTable).evaluate().isEmpty,
      );
      expect(
        heatmapShown,
        isTrue,
        reason: 'heatmap must replace the table after the toggle',
      );

      // ── Heatmap renders one cell per seeded test, colored by status ──
      final passTooltip = find.byTooltip('smoke/alu_pass · pass');
      final failTooltip = find.byTooltip('smoke/alu_fail · fail');
      final cellsRendered = await pumpUntil(
        tester,
        () =>
            passTooltip.evaluate().isNotEmpty &&
            failTooltip.evaluate().isNotEmpty,
      );
      expect(
        cellsRendered,
        isTrue,
        reason: 'heatmap must render a cell for every seeded test',
      );

      // ── Tapping a cell drives the shared inspector selection ─────────
      await tester.tap(failTooltip);
      final selected = await pumpUntil(
        tester,
        () => tab.read(selectedTestIdProvider) == 'smoke/alu_fail',
      );
      expect(
        selected,
        isTrue,
        reason: 'heatmap cell tap must select smoke/alu_fail',
      );

      expect(tester.takeException(), isNull);
    },
  );
}
