// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/theme/simcrux_colors.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/suite.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_run.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/dashboard/widgets/dashboard_heatmap_view.dart';
import 'package:simcrux/features/dashboard/widgets/dashboard_status_icon.dart';
import 'package:simcrux/features/dashboard/widgets/test_browser_panel.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/result_store/in_memory_result_store.dart';
import 'package:simcrux/services/result_store/result_store_provider.dart';
import 'package:simcrux/web/web_status_chip.dart';

/// The five canonical CI statuses and the single brand-neutral token each
/// must render as on every dashboard status surface. The palette-drift
/// defect this guards against was four widgets hardcoding four mutually
/// inconsistent raw `Colors.*` values (e.g. vacuous shown green in the
/// heatmap but amber in the icon, cover shown green in the web chip but
/// indigo in the heatmap). Wiring all four through
/// [SimcruxColors.statusColor] makes each status one hue everywhere; this
/// test asserts the four surfaces agree on that hue.
const _canonical = <TestStatus, Color>{
  TestStatus.pass: SimcruxColors.statusPass,
  TestStatus.fail: SimcruxColors.statusFail,
  TestStatus.vacuous: SimcruxColors.statusVacuous,
  TestStatus.cover: SimcruxColors.statusCover,
  TestStatus.skipped: SimcruxColors.statusSkipped,
};

/// The browser/results-table icon each canonical status renders, used to
/// pick the status icon out of a panel that also draws other iconography.
const _iconFor = <TestStatus, IconData>{
  TestStatus.pass: Icons.check_circle,
  TestStatus.fail: Icons.cancel,
  TestStatus.vacuous: Icons.info_outline,
  TestStatus.cover: Icons.flag,
  TestStatus.skipped: Icons.remove_circle_outline,
};

Widget _wrap(Widget child, {List<Override> overrides = const []}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      localizationsDelegates: const [
        L10N.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: L10N.supportedLocales,
      home: Scaffold(body: SizedBox(width: 1200, height: 600, child: child)),
    ),
  );
}

TestResult _result(String id, TestStatus status) => TestResult(
  testId: id,
  runId: 'r1',
  status: status,
  startedAt: DateTime.utc(2026, 5),
  finishedAt: DateTime.utc(2026, 5).add(const Duration(milliseconds: 50)),
);

void main() {
  group('status palette consistency', () {
    test('SimcruxColors.statusColor returns the token for each canonical '
        'status, independent of the color scheme', () {
      for (final scheme in const [ColorScheme.light(), ColorScheme.dark()]) {
        _canonical.forEach((status, token) {
          expect(
            SimcruxColors.statusColor(status, scheme),
            token,
            reason: '$status must resolve to its canonical token',
          );
        });
      }
    });

    testWidgets('DashboardStatusIcon renders the token for each canonical '
        'status', (tester) async {
      for (final entry in _canonical.entries) {
        await tester.pumpWidget(_wrap(DashboardStatusIcon(status: entry.key)));
        await tester.pumpAndSettle();
        final icon = tester.widget<Icon>(find.byType(Icon));
        expect(icon.color, entry.value, reason: '${entry.key}');
      }
    });

    testWidgets('WebStatusChip renders the token as its label color for each '
        'canonical status', (tester) async {
      for (final entry in _canonical.entries) {
        await tester.pumpWidget(_wrap(WebStatusChip(entry.key)));
        await tester.pumpAndSettle();
        final text = tester.widget<Text>(
          find.descendant(
            of: find.byType(WebStatusChip),
            matching: find.byType(Text),
          ),
        );
        expect(text.style?.color, entry.value, reason: '${entry.key}');
      }
    });

    testWidgets('DashboardHeatmapView colors each cell with the token', (
      tester,
    ) async {
      // One result per canonical status in a single run, so a single pump
      // exercises all five cells side by side (the real dashboard shape).
      final run = TestRun(
        id: 'r1',
        startedAt: DateTime.utc(2026, 5),
        testIds: [for (final s in _canonical.keys) 'suite/${s.name}'],
      );
      final store = InMemoryResultStore.forRun(run);
      for (final s in _canonical.keys) {
        await store.recordResult(_result('suite/${s.name}', s));
      }
      await tester.pumpWidget(
        _wrap(
          const DashboardHeatmapView(),
          overrides: [
            resultStoreProvider.overrideWith(
              () => _ImmediateResultStore(store),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      for (final entry in _canonical.entries) {
        // The cell tooltip is "<suite>/<test> · <status>"; match the
        // status segment to pick this status's cell.
        final cell = find.descendant(
          of: find.byWidgetPredicate(
            (w) =>
                w is Tooltip && (w.message?.endsWith(entry.key.name) ?? false),
          ),
          matching: find.byWidgetPredicate(
            (w) => w is Container && w.decoration is BoxDecoration,
          ),
        );
        final container = tester.widget<Container>(cell);
        final decoration = container.decoration! as BoxDecoration;
        expect(decoration.color, entry.value, reason: '${entry.key}');
      }
    });

    testWidgets('TestBrowserPanel colors the per-test icon with the token', (
      tester,
    ) async {
      // One test per canonical status, joined to a matching result, so a
      // single pump renders all five status icons at once.
      final run = TestRun(
        id: 'r1',
        startedAt: DateTime.utc(2026, 5),
        testIds: [for (final s in _canonical.keys) 'suite/${s.name}'],
      );
      final store = InMemoryResultStore.forRun(run);
      for (final s in _canonical.keys) {
        await store.recordResult(_result('suite/${s.name}', s));
      }
      await tester.pumpWidget(
        _wrap(
          const TestBrowserPanel(),
          overrides: [
            activeConfigProvider.overrideWith(_StubActiveConfig.new),
            resultStoreProvider.overrideWith(
              () => _ImmediateResultStore(store),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      for (final entry in _canonical.entries) {
        final icon = tester.widget<Icon>(
          find.byWidgetPredicate(
            (w) => w is Icon && w.icon == _iconFor[entry.key],
          ),
        );
        expect(icon.color, entry.value, reason: '${entry.key}');
      }
    });
  });
}

class _ImmediateResultStore extends ResultStoreNotifier {
  _ImmediateResultStore(this._store);
  final InMemoryResultStore _store;

  @override
  InMemoryResultStore build() => _store;
}

class _StubActiveConfig extends ActiveConfigNotifier {
  @override
  RegressionConfig? build() => RegressionConfig(
    projectFilePath: '/proj/simcrux.yaml',
    schemaVersion: '1',
    suites: [
      Suite(
        name: 'suite',
        tests: [
          for (final s in _canonical.keys)
            TestSpec(
              id: 'suite/${s.name}',
              name: s.name,
              suiteName: 'suite',
              simulatorId: 'icarus',
              top: 'tb',
            ),
        ],
      ),
    ],
    simulatorBinaries: const {},
  );
}
