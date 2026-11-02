// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/run_delta_bucket.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/trend_store.dart';
import 'package:simcrux/features/dashboard/models/dashboard_filter.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/inspector/providers/test_trend_provider.dart';
import 'package:simcrux/features/inspector/widgets/run_delta_strip.dart';
import 'package:simcrux/features/workspace/providers/workspace_containers.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// Deterministic delta fixture:
/// - 2 × pass → fail (new failures)
/// - 1 × fail → pass (fixed)
/// - 3 × first appearance (new tests)
/// - 1 × pass → vacuous (other change)
const List<TrendDelta> _kDeltas = [
  TrendDelta(
    testId: 'smoke/a',
    currentStatus: TestStatus.fail,
    previousStatus: TestStatus.pass,
    currentRunId: 'r2',
  ),
  TrendDelta(
    testId: 'smoke/b',
    currentStatus: TestStatus.timeout,
    previousStatus: TestStatus.pass,
    currentRunId: 'r2',
  ),
  TrendDelta(
    testId: 'smoke/c',
    currentStatus: TestStatus.pass,
    previousStatus: TestStatus.fail,
    currentRunId: 'r2',
  ),
  TrendDelta(
    testId: 'smoke/d',
    currentStatus: TestStatus.pass,
    previousStatus: null,
    currentRunId: 'r2',
  ),
  TrendDelta(
    testId: 'smoke/e',
    currentStatus: TestStatus.pass,
    previousStatus: null,
    currentRunId: 'r2',
  ),
  TrendDelta(
    testId: 'smoke/f',
    currentStatus: TestStatus.fail,
    previousStatus: null,
    currentRunId: 'r2',
  ),
  TrendDelta(
    testId: 'smoke/g',
    currentStatus: TestStatus.vacuous,
    previousStatus: TestStatus.pass,
    currentRunId: 'r2',
  ),
];

Future<void> _pump(
  WidgetTester tester, {
  required List<Override> overrides,
  Locale locale = const Locale('en'),
}) async {
  await tester.pumpWidget(
    ProviderScope(
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
        home: const Scaffold(body: RunDeltaStrip()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Overrides the leaf [recentTrendDeltasProvider] (never the trend
/// store — trendStoreChangeTickProvider keeps streams/timers alive).
Override _deltasOverride(List<TrendDelta> deltas) {
  return recentTrendDeltasProvider.overrideWith((_) => deltas);
}

/// What [recentTrendDeltasProvider] reports in the tab-scope tests below; the
/// tests change it to make [runDeltaProvider] emit.
class _DeltaSource extends Notifier<List<TrendDelta>> {
  @override
  List<TrendDelta> build() => _kDeltas;

  List<TrendDelta> get deltas => state;

  set deltas(List<TrendDelta> next) => state = next;
}

final NotifierProvider<_DeltaSource, List<TrendDelta>> _deltaSourceProvider =
    NotifierProvider<_DeltaSource, List<TrendDelta>>(_DeltaSource.new);

/// The production topology in miniature: [runDeltaProvider] and everything it
/// reads live in [root], while the dashboard filter is a per-tab provider in
/// [tab], and the strip reads through the tab's scope.
class _TabScoped {
  _TabScoped() {
    root = ProviderContainer(
      overrides: [
        recentTrendDeltasProvider.overrideWith(
          (ref) => ref.watch(_deltaSourceProvider),
        ),
      ],
    );
    tab = ProviderContainer(
      parent: root,
      overrides: [
        dashboardFilterProvider.overrideWith(DashboardFilterNotifier.new),
      ],
    );
  }

  late final ProviderContainer root;
  late final ProviderContainer tab;

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      WorkspaceContainersScope(
        root: root,
        scoped: tab,
        child: MaterialApp(
          localizationsDelegates: const [
            L10N.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: L10N.supportedLocales,
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: tabOpen,
              builder: (_, open, _) =>
                  open ? const RunDeltaStrip() : const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Whether the tab's content is in the tree. Closing the tab disposes its
  /// container at once, but the content leaves the tree on the next frame.
  final ValueNotifier<bool> tabOpen = ValueNotifier<bool>(true);

  List<TrendDelta> get deltas => root.read(_deltaSourceProvider);

  set deltas(List<TrendDelta> next) =>
      root.read(_deltaSourceProvider.notifier).deltas = next;

  RunDeltaBucket? get bucket => tab.read(dashboardFilterProvider).deltaBucket;

  void narrowTo(RunDeltaBucket bucket) => tab
      .read(dashboardFilterProvider.notifier)
      .setAll(DashboardFilter.unset.copyWith(deltaBucket: bucket));
}

void main() {
  group('RunDeltaStrip in a tab scope', () {
    testWidgets('clears a narrowing whose counter has emptied', (tester) async {
      final scope = _TabScoped();
      addTearDown(scope.root.dispose);
      await scope.pump(tester);
      scope.narrowTo(RunDeltaBucket.newFailures);
      await tester.pumpAndSettle();
      expect(scope.bucket, RunDeltaBucket.newFailures);

      // The new failures are fixed: that counter is no longer drawn.
      scope.deltas = _kDeltas
          .where((d) => d.testId != 'smoke/a' && d.testId != 'smoke/b')
          .toList();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(scope.bucket, isNull);
    });

    testWidgets('keeps a narrowing whose counter still has tests', (
      tester,
    ) async {
      final scope = _TabScoped();
      addTearDown(scope.root.dispose);
      await scope.pump(tester);
      scope.narrowTo(RunDeltaBucket.fixed);
      await tester.pumpAndSettle();

      scope.deltas = _kDeltas.where((d) => d.testId != 'smoke/a').toList();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(scope.bucket, RunDeltaBucket.fixed);
    });

    testWidgets(
      'does nothing, and throws nothing, when the tab container is already '
      'disposed while the delta changes',
      (tester) async {
        final scope = _TabScoped();
        addTearDown(scope.root.dispose);
        await scope.pump(tester);
        scope.narrowTo(RunDeltaBucket.newFailures);
        await tester.pumpAndSettle();

        // Closing a tab disposes its container as the workspace changes, but
        // its widgets leave the tree only on the next frame, and the strip's
        // listener on the app-wide delta provider stays registered until they
        // do. The provider refreshes at the start of that frame.
        scope.tab.dispose();
        scope.tabOpen.value = false;
        scope.deltas = const <TrendDelta>[];
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));

        expect(tester.takeException(), isNull);
        expect(find.byType(RunDeltaStrip), findsNothing);
      },
    );
  });

  group('RunDeltaStrip', () {
    testWidgets('renders nothing when there are no run-over-run changes', (
      tester,
    ) async {
      await _pump(tester, overrides: [_deltasOverride(const <TrendDelta>[])]);
      expect(tester.takeException(), isNull);
      expect(find.byType(Wrap), findsNothing);
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('renders one counter chip per non-zero delta bucket', (
      tester,
    ) async {
      await _pump(tester, overrides: [_deltasOverride(_kDeltas)]);
      expect(tester.takeException(), isNull);
      expect(
        find.descendant(of: find.byType(Wrap), matching: find.byType(Text)),
        findsNWidgets(4),
      );
      // The counter labels are non-localized literals baked into
      // RunDeltaStrip (no ARB keys exist for them), so exact-match is
      // the only faithful assertion available here.
      expect(find.text('↘ 2 new'), findsOneWidget);
      expect(find.text('↗ 1 fixed'), findsOneWidget);
      expect(find.text('+ 3 new'), findsOneWidget);
      expect(find.text('~ 1 changed'), findsOneWidget);
    });

    testWidgets('omits counter chips for zero buckets', (tester) async {
      await _pump(
        tester,
        overrides: [
          _deltasOverride(const [
            TrendDelta(
              testId: 'smoke/a',
              currentStatus: TestStatus.fail,
              previousStatus: TestStatus.pass,
              currentRunId: 'r2',
            ),
          ]),
        ],
      );
      expect(tester.takeException(), isNull);
      expect(
        find.descendant(of: find.byType(Wrap), matching: find.byType(Text)),
        findsOneWidget,
      );
      expect(find.text('↘ 1 new'), findsOneWidget);
    });

    testWidgets('locale sweep renders without exceptions', (tester) async {
      for (final locale in const [
        Locale('en'),
        Locale('zh', 'CN'),
        Locale('zh'),
        Locale('ja'),
        Locale('ko'),
      ]) {
        await _pump(
          tester,
          overrides: [_deltasOverride(_kDeltas)],
          locale: locale,
        );
        expect(tester.takeException(), isNull, reason: '$locale');
      }
    });
  });
}
