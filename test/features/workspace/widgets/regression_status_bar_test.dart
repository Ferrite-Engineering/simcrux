// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_status_bar/crux_status_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/workspace/widgets/regression_status_bar.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

Widget _harness(
  Widget child, {
  Stream<DashboardTotals> totals = const Stream<DashboardTotals>.empty(),
  Locale locale = const Locale('en'),
}) {
  return ProviderScope(
    overrides: [
      dashboardTotalsProvider.overrideWith((ref) => totals),
    ],
    child: MaterialApp(
      locale: locale,
      localizationsDelegates: L10N.localizationsDelegates,
      supportedLocales: L10N.supportedLocales,
      home: Scaffold(
        body: Column(children: <Widget>[const Spacer(), child]),
      ),
    ),
  );
}

void main() {
  group('RegressionStatusBar', () {
    testWidgets('mounts the shared CruxStatusBar with the config file name', (
      tester,
    ) async {
      await tester.pumpWidget(
        _harness(
          const RegressionStatusBar(configPath: '/work/soc/simcrux.yaml'),
        ),
      );
      await tester.pump();

      // Mounts on the shared cross-suite chrome.
      expect(find.byType(CruxStatusBar), findsOneWidget);
      // File identity (basename of the config path).
      expect(find.text('simcrux.yaml'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('surfaces the run summary once totals arrive', (tester) async {
      await tester.pumpWidget(
        _harness(
          const RegressionStatusBar(configPath: '/work/cpu/simcrux.yaml'),
          totals: Stream<DashboardTotals>.value(
            DashboardTotals(
              total: 5,
              byStatus: const <TestStatus, int>{
                TestStatus.pass: 3,
                TestStatus.fail: 1,
                TestStatus.running: 1,
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('simcrux.yaml'), findsOneWidget);
      expect(find.text('Total: 5'), findsOneWidget);
      expect(find.text('Passed: 3'), findsOneWidget);
      expect(find.text('Failed: 1'), findsOneWidget);
      expect(find.text('Running: 1'), findsOneWidget);
    });

    group('the region name', () {
      // A screen reader announces the bar as a named region, in the app's
      // language, like WaveCrux's.
      const names = <String, String>{
        'en': 'Status bar',
        'ja': 'ステータスバー',
        'ko': '상태 표시줄',
        'zh': '状态栏',
      };
      for (final entry in names.entries) {
        testWidgets('the bar is named "${entry.value}" in ${entry.key}', (
          tester,
        ) async {
          final handle = tester.ensureSemantics();
          await tester.pumpWidget(
            _harness(
              const RegressionStatusBar(configPath: '/work/soc/simcrux.yaml'),
              locale: Locale(entry.key),
            ),
          );
          await tester.pump();
          expect(find.bySemanticsLabel(entry.value), findsOneWidget);
          handle.dispose();
        });
      }

      testWidgets('the idle bar carries the name too', (tester) async {
        final handle = tester.ensureSemantics();
        await tester.pumpWidget(
          _harness(const Builder(builder: RegressionStatusBar.idle)),
        );
        await tester.pump();
        expect(find.bySemanticsLabel('Status bar'), findsOneWidget);
        handle.dispose();
      });
    });

    group('the zero-suppressed counts', () {
      testWidgets('omits skipped / timeout / error when all are zero', (
        tester,
      ) async {
        // These three moved here from the DashboardStatusBar that used to sit
        // stacked above this bar. Rendering all seven unconditionally would
        // make this the widest bar in the suite to show three zeroes.
        await tester.pumpWidget(
          _harness(
            const RegressionStatusBar(configPath: '/work/cpu/simcrux.yaml'),
            totals: Stream<DashboardTotals>.value(
              DashboardTotals(
                total: 4,
                byStatus: const <TestStatus, int>{
                  TestStatus.pass: 3,
                  TestStatus.fail: 1,
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Total: 4'), findsOneWidget);
        expect(find.textContaining('Skipped'), findsNothing);
        expect(find.textContaining('Timed out'), findsNothing);
        expect(find.textContaining('Error'), findsNothing);
      });

      testWidgets('shows each one as soon as it is non-zero', (tester) async {
        await tester.pumpWidget(
          _harness(
            const RegressionStatusBar(configPath: '/work/cpu/simcrux.yaml'),
            totals: Stream<DashboardTotals>.value(
              DashboardTotals(
                total: 9,
                byStatus: const <TestStatus, int>{
                  TestStatus.pass: 3,
                  TestStatus.fail: 1,
                  TestStatus.skipped: 2,
                  TestStatus.timeout: 1,
                  TestStatus.unknown: 2,
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Skipped: 2'), findsOneWidget);
        expect(find.text('Timed out: 1'), findsOneWidget);
        expect(find.text('Error: 2'), findsOneWidget);
        // …and a zero one still stays away.
        expect(find.textContaining('Running'), findsOneWidget);
        expect(find.text('Running: 0'), findsOneWidget);
      });
    });

    // The status bar packs a config path and five labelled counters into one
    // row, so it is the first surface where a longer CJK rendering overflows.
    // Additive: the assertions above are en-specific by design and stay so.
    for (final locale in L10N.supportedLocales) {
      testWidgets('renders without exceptions in ${locale.toLanguageTag()}', (
        tester,
      ) async {
        await tester.pumpWidget(
          _harness(
            const RegressionStatusBar(configPath: '/work/soc/simcrux.yaml'),
            locale: locale,
          ),
        );
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(find.byType(CruxStatusBar), findsOneWidget);
      });
    }
  });
}
