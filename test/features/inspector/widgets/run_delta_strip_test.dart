// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/trend_store.dart';
import 'package:simcrux/features/inspector/providers/test_trend_provider.dart';
import 'package:simcrux/features/inspector/widgets/run_delta_strip.dart';
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

void main() {
  group('RunDeltaStrip', () {
    testWidgets('renders nothing when there are no run-over-run changes', (
      tester,
    ) async {
      await _pump(
        tester,
        overrides: [_deltasOverride(const <TrendDelta>[])],
      );
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
        find.descendant(
          of: find.byType(Wrap),
          matching: find.byType(Text),
        ),
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
        find.descendant(
          of: find.byType(Wrap),
          matching: find.byType(Text),
        ),
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
