// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/dashboard_row.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/features/inspector/providers/test_trend_provider.dart';
import 'package:simcrux/features/inspector/widgets/inspector_trend.dart';
import 'package:simcrux/features/inspector/widgets/test_trend_sparkline.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

const String _kTestId = 'smoke/pass_basic';

SelectedTest _selection() {
  final result = TestResult(
    testId: _kTestId,
    runId: 'r1',
    status: TestStatus.pass,
    startedAt: DateTime.utc(2026, 5),
    finishedAt: DateTime.utc(2026, 5).add(const Duration(milliseconds: 50)),
    exitCode: 0,
  );
  return SelectedTest(
    row: DashboardRow(
      result: result,
      suiteName: 'smoke',
      simulatorId: 'icarus',
      testName: 'pass_basic',
    ),
  );
}

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
        home: Scaffold(body: InspectorTrend(selection: _selection())),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // The leaf FutureProvider family is always overridden with static
  // data so the widget never touches the real SQLite trend store or
  // the trendStoreChangeTickProvider stream.
  group('InspectorTrend', () {
    testWidgets('renders the localized empty state with no history', (
      tester,
    ) async {
      await _pump(
        tester,
        overrides: [
          testTrendProvider(_kTestId).overrideWith(
            (_) => const <TestStatus>[],
          ),
        ],
      );
      expect(tester.takeException(), isNull);
      final l10n = L10N.of(tester.element(find.byType(Scaffold)));
      expect(find.text(l10n.inspectorTrendHeading), findsOneWidget);
      expect(find.text(l10n.inspectorTrendEmpty), findsOneWidget);
      expect(find.byType(TestTrendSparkline), findsNothing);
    });

    testWidgets('renders a sparkline cell per trend point', (tester) async {
      await _pump(
        tester,
        overrides: [
          testTrendProvider(_kTestId).overrideWith(
            (_) => const [
              TestStatus.pass,
              TestStatus.fail,
              TestStatus.pass,
            ],
          ),
        ],
      );
      expect(tester.takeException(), isNull);
      final l10n = L10N.of(tester.element(find.byType(Scaffold)));
      expect(find.text(l10n.inspectorTrendHeading), findsOneWidget);
      expect(find.text(l10n.inspectorTrendEmpty), findsNothing);
      final sparkline = tester.widget<TestTrendSparkline>(
        find.byType(TestTrendSparkline),
      );
      expect(sparkline.statuses, const [
        TestStatus.pass,
        TestStatus.fail,
        TestStatus.pass,
      ]);
      expect(
        find.descendant(
          of: find.byType(TestTrendSparkline),
          matching: find.byType(Container),
        ),
        findsNWidgets(3),
      );
    });

    testWidgets('falls back to the empty text when the trend query fails', (
      tester,
    ) async {
      await _pump(
        tester,
        overrides: [
          testTrendProvider(_kTestId).overrideWith(
            (_) async => throw StateError('trend store unavailable'),
          ),
        ],
      );
      expect(tester.takeException(), isNull);
      final l10n = L10N.of(tester.element(find.byType(Scaffold)));
      expect(find.text(l10n.inspectorTrendEmpty), findsOneWidget);
      expect(find.byType(TestTrendSparkline), findsNothing);
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
          overrides: [
            testTrendProvider(_kTestId).overrideWith(
              (_) => const [TestStatus.pass, TestStatus.fail],
            ),
          ],
          locale: locale,
        );
        expect(tester.takeException(), isNull, reason: '$locale');
      }
    });
  });
}
