// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/result_store.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_run.dart';
import 'package:simcrux/features/dashboard/widgets/dashboard_heatmap_view.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/result_store/in_memory_result_store.dart';
import 'package:simcrux/services/result_store/result_store_provider.dart';

TestResult _result(String id, TestStatus status) {
  return TestResult(
    testId: id,
    runId: 'r1',
    status: status,
    startedAt: DateTime.utc(2026, 5),
    finishedAt: DateTime.utc(2026, 5).add(const Duration(milliseconds: 50)),
  );
}

InMemoryResultStore _populatedStore() {
  final run = TestRun(
    id: 'r1',
    startedAt: DateTime.utc(2026, 5),
    testIds: const ['unit/alu', 'unit/regfile', 'unit/lsu'],
  );
  return InMemoryResultStore.forRun(run);
}

/// A store holding [count] recorded results — a full-size regression.
InMemoryResultStore _bigStore(int count) {
  final ids = <String>[for (var i = 0; i < count; i++) 'unit/t$i'];
  final run = TestRun(
    id: 'r1',
    startedAt: DateTime.utc(2026, 5),
    testIds: ids,
  );
  final store = InMemoryResultStore.forRun(run);
  for (var i = 0; i < count; i++) {
    unawaited(
      store.recordResult(
        _result(ids[i], i % 7 == 0 ? TestStatus.fail : TestStatus.pass),
      ),
    );
  }
  return store;
}

Widget _wrap(
  Widget child, {
  Locale locale = const Locale('en'),
  List<Override> overrides = const [],
}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      locale: locale,
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

void main() {
  group('DashboardHeatmapView', () {
    testWidgets('renders the empty state when no results exist', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const DashboardHeatmapView()));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // No cells (each cell wraps its square in a Tooltip)...
      expect(find.byType(Tooltip), findsNothing);
      // ...just the localized centered empty-state message, matching
      // the table view's empty state.
      final l10n = L10N.of(tester.element(find.byType(DashboardHeatmapView)));
      expect(find.text(l10n.dashboardEmpty), findsOneWidget);
    });

    testWidgets('renders the localized error state', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const DashboardHeatmapView(),
          overrides: [
            resultStoreProvider.overrideWith(_ThrowingResultStoreNotifier.new),
          ],
        ),
      );
      await tester.pumpAndSettle();
      final l10n = L10N.of(tester.element(find.byType(DashboardHeatmapView)));
      expect(find.text(l10n.dashboardError), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders one status-colored cell per result row', (
      tester,
    ) async {
      final store = _populatedStore();
      await store.recordResult(_result('unit/alu', TestStatus.pass));
      await store.recordResult(_result('unit/regfile', TestStatus.fail));
      await store.recordResult(_result('unit/lsu', TestStatus.timeout));

      await tester.pumpWidget(
        _wrap(
          const DashboardHeatmapView(),
          overrides: [
            resultStoreProvider.overrideWith(
              () => _ImmediateResultStoreNotifier(store),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(Tooltip), findsNWidgets(3));
      final messages = tester
          .widgetList<Tooltip>(find.byType(Tooltip))
          .map((t) => t.message)
          .toList();
      expect(
        messages.where((m) => m!.contains(TestStatus.pass.name)),
        hasLength(1),
      );
      expect(
        messages.where((m) => m!.contains(TestStatus.fail.name)),
        hasLength(1),
      );
    });

    testWidgets('tapping a cell selects that test for the inspector', (
      tester,
    ) async {
      final store = _populatedStore();
      await store.recordResult(_result('unit/alu', TestStatus.pass));
      await store.recordResult(_result('unit/regfile', TestStatus.fail));

      await tester.pumpWidget(
        _wrap(
          const DashboardHeatmapView(),
          overrides: [
            resultStoreProvider.overrideWith(
              () => _ImmediateResultStoreNotifier(store),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(DashboardHeatmapView)),
      );
      expect(container.read(selectedTestIdProvider), isNull);

      final regfileCell = find.byWidgetPredicate(
        (w) => w is Tooltip && (w.message?.contains('regfile') ?? false),
      );
      expect(regfileCell, findsOneWidget);
      await tester.tap(regfileCell);
      await tester.pumpAndSettle();
      expect(container.read(selectedTestIdProvider), 'unit/regfile');
    });

    // The size this view exists for. Before it was virtualized, a
    // 10 000-test run built, laid out and retained 10 000 `Tooltip`s in a
    // `Wrap`, and — because the grid itself watched `selectedTestIdProvider`
    // — every tap rebuilt all of them to move one border.
    //
    // PRIMARY MUTATION TARGET: putting the `selectedTestIdProvider` watch
    // back on the grid, or swapping `GridView.builder` for an eager `Wrap`,
    // fails these two.
    testWidgets('a 10 000-test run builds only the cells in view', (
      tester,
    ) async {
      final store = _bigStore(10000);
      await tester.pumpWidget(
        _wrap(
          const DashboardHeatmapView(),
          overrides: [
            resultStoreProvider.overrideWith(
              () => _ImmediateResultStoreNotifier(store),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final built = tester.widgetList<Tooltip>(find.byType(Tooltip)).length;
      expect(
        built,
        lessThan(3500),
        reason: 'built $built cells for 10 000 tests',
      );
    });

    testWidgets('tapping a cell rebuilds two cells, not ten thousand', (
      tester,
    ) async {
      final store = _bigStore(10000);
      await tester.pumpWidget(
        _wrap(
          const DashboardHeatmapView(),
          overrides: [
            resultStoreProvider.overrideWith(
              () => _ImmediateResultStoreNotifier(store),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(DashboardHeatmapView)),
      );
      final firstCell = find.byType(Tooltip).first;
      final before = tester.widgetList<Tooltip>(find.byType(Tooltip)).length;
      final sw = Stopwatch()..start();
      await tester.tap(firstCell);
      await tester.pump();
      sw.stop();
      expect(container.read(selectedTestIdProvider), isNotNull);
      // The cell count is unchanged (nothing new was materialized) and the
      // frame is quick, because only the tapped cell rebuilt.
      expect(tester.widgetList<Tooltip>(find.byType(Tooltip)).length, before);
      expect(
        sw.elapsedMilliseconds,
        lessThan(250),
        reason: 'selection frame took ${sw.elapsedMilliseconds} ms',
      );
    });

    testWidgets('locale sweep renders without exceptions', (tester) async {
      for (final locale in const [
        Locale('en'),
        Locale('zh', 'CN'),
        Locale('zh'),
        Locale('ja'),
        Locale('ko'),
      ]) {
        await tester.pumpWidget(
          _wrap(const DashboardHeatmapView(), locale: locale),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$locale');
      }
    });
  });
}

class _ImmediateResultStoreNotifier extends ResultStoreNotifier {
  _ImmediateResultStoreNotifier(this._store);
  final InMemoryResultStore _store;

  @override
  InMemoryResultStore build() => _store;
}

/// [ResultStore] whose [currentRun] stream errors immediately —
/// drives [dashboardRowsProvider] into its error state so the
/// heatmap view's error text can be exercised.
class _ThrowingResultStore implements ResultStore {
  @override
  Stream<TestRun> get currentRun => Stream<TestRun>.error(Exception('boom'));

  @override
  TestRun get latestRun => throw UnimplementedError();

  @override
  Future<void> recordResult(TestResult result) => throw UnimplementedError();

  @override
  Future<void> recordRunCompletion(RunSummary summary) =>
      throw UnimplementedError();

  @override
  Stream<TestRun> queryRuns(RunQuery query) => throw UnimplementedError();

  @override
  Stream<TestResult> queryResults(ResultQuery query) =>
      throw UnimplementedError();
}

class _ThrowingResultStoreNotifier extends ResultStoreNotifier {
  @override
  ResultStore build() => _ThrowingResultStore();
}
