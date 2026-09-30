// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// integration_test/dashboard/seeded_run_dashboard_test.dart
//
// Seeded-run journey: a CLI-opened project runs through the REAL
// pipeline — ConfigLoader → LocalJobScheduler → scripted driver → exit_code
// PassFailDetector → per-tab InMemoryResultStore — and the dashboard +
// inspector render the completed run. Covers the three "need a seeded result
// set" pending journeys: table population + pass/fail outcome rendering,
// status filter + sort, row select → inspector (header / details / log
// preview fed from the real log buffers).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/features/dashboard/models/dashboard_sort.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/dashboard/widgets/dashboard_results_table.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

import '../helpers/app_driver.dart';
import '../helpers/seeded_run.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  suppressPlatformSemanticsLeak();

  testWidgets(
    'seeded run populates the dashboard; filter, sort, and select '
    'drive the table and the inspector',
    (tester) async {
      final project = await writeSeededProject(
        tests: const [
          SeededTest('smoke', 'alu_pass', [ScriptedOutcome.passed()]),
          SeededTest('smoke', 'alu_fail', [
            ScriptedOutcome.failed(
              stderrLines: ['seeded: ERROR intentional alu failure'],
            ),
          ]),
          SeededTest('timing', 'fifo_pass', [ScriptedOutcome.passed()]),
          SeededTest('timing', 'fifo_fail', [ScriptedOutcome.failed()]),
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
      await pumpUntilRunFinished(tester, tab, expectedResults: 4);

      // ── Run outcomes landed through the real detector ────────────────
      final totals = await pumpUntil(tester, () {
        final t = tab.read(dashboardTotalsProvider).value;
        return t != null &&
            t.total == 4 &&
            t.countOf(TestStatus.pass) == 2 &&
            t.countOf(TestStatus.fail) == 2;
      });
      expect(totals, isTrue, reason: 'expected 2 pass / 2 fail totals');

      // ── Table renders every seeded row ───────────────────────────────
      // Test names also appear in the left-pane test browser — scope all
      // table assertions to the results table itself.
      Finder inTable(String name) => find.descendant(
        of: find.byType(DashboardResultsTable),
        matching: find.text(name),
      );
      final rowsVisible = await pumpUntil(
        tester,
        () => inTable('alu_fail').evaluate().isNotEmpty,
      );
      expect(rowsVisible, isTrue);
      for (final name in ['alu_pass', 'alu_fail', 'fifo_pass', 'fifo_fail']) {
        expect(inTable(name), findsOneWidget, reason: 'row $name');
      }

      // ── Select: tap the failing row → inspector shows it ─────────────
      await tester.tap(inTable('alu_fail'));
      final selected = await pumpUntil(
        tester,
        () => tab.read(selectedTestIdProvider) == 'smoke/alu_fail',
      );
      expect(selected, isTrue, reason: 'row tap must select smoke/alu_fail');

      final l10n = L10N.of(tester.element(find.byType(Scaffold).first));
      // Inspector details section header + the scripted stderr line in the
      // log preview (real LogBufferStore path; allow the 80 ms coalescing
      // window to fire).
      final detailsShown = await pumpUntil(
        tester,
        () => find.text(l10n.inspectorSectionDetails).evaluate().isNotEmpty,
      );
      expect(detailsShown, isTrue, reason: 'inspector details must render');
      final logShown = await pumpUntil(
        tester,
        () => find
            .textContaining('seeded: ERROR intentional alu failure')
            .evaluate()
            .isNotEmpty,
      );
      expect(
        logShown,
        isTrue,
        reason: 'inspector log preview must show the scripted stderr line',
      );

      // ── Filter: tap the Fail status chip → passing rows vanish ───────
      await tester.tap(
        find.widgetWithText(FilterChip, l10n.testStatusFail),
      );
      // Poll for the post-filter steady state in one condition: the rows
      // provider recomputes on a coalesced ~10 Hz tick, so there is a
      // transient frame where the table is empty (old rows gone, new rows
      // not yet emitted) — asserting piecewise would race it.
      final filtered = await pumpUntil(
        tester,
        () =>
            tab
                .read(dashboardFilterProvider)
                .statuses
                .contains(
                  TestStatus.fail,
                ) &&
            inTable('alu_pass').evaluate().isEmpty &&
            inTable('fifo_pass').evaluate().isEmpty &&
            inTable('alu_fail').evaluate().length == 1 &&
            inTable('fifo_fail').evaluate().length == 1,
      );
      expect(
        filtered,
        isTrue,
        reason: 'fail filter must hide passing rows and keep failing rows',
      );

      // ── Sort: name ascending, then flipped to descending ─────────────
      // (The default sort is startedAt-descending, whose order between
      // concurrently-finishing scripted tests is timing-dependent — pin
      // an explicit name sort in both directions instead.)
      double rowY(String name) => tester.getTopLeft(inTable(name)).dy;
      tab
          .read(dashboardSortProvider.notifier)
          .setAll(
            const DashboardSort(
              column: DashboardSortColumn.testName,
              direction: DashboardSortDirection.ascending,
            ),
          );
      final ascending = await pumpUntil(
        tester,
        () =>
            inTable('fifo_fail').evaluate().isNotEmpty &&
            rowY('alu_fail') < rowY('fifo_fail'),
      );
      expect(
        ascending,
        isTrue,
        reason: 'ascending name sort must list alu_fail first',
      );
      tab
          .read(dashboardSortProvider.notifier)
          .setAll(const DashboardSort(column: DashboardSortColumn.testName));
      final descending = await pumpUntil(
        tester,
        () =>
            inTable('fifo_fail').evaluate().isNotEmpty &&
            rowY('fifo_fail') < rowY('alu_fail'),
      );
      expect(
        descending,
        isTrue,
        reason: 'descending name sort must list fifo_fail first',
      );

      expect(tester.takeException(), isNull);
    },
  );
}
