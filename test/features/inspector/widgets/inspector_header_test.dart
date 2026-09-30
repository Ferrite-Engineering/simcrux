// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/dashboard_row.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/features/dashboard/widgets/dashboard_status_icon.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/features/inspector/widgets/inspector_header.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

SelectedTest _selection({TestStatus status = TestStatus.pass}) {
  final result = TestResult(
    testId: 'smoke/pass_basic',
    runId: 'r1',
    status: status,
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
  WidgetTester tester,
  SelectedTest selection, {
  Locale locale = const Locale('en'),
}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: const [
          L10N.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: L10N.supportedLocales,
        home: Scaffold(body: InspectorHeader(selection: selection)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('InspectorHeader', () {
    // Note: InspectorHeader requires a selection (no empty state of
    // its own) — the unselected placeholder lives on InspectorPane
    // (CruxPanelEmptyState) and is covered by inspector_pane_test.dart.
    testWidgets('renders test name, full test id and status icon', (
      tester,
    ) async {
      await _pump(tester, _selection());
      expect(tester.takeException(), isNull);
      expect(find.text('pass_basic'), findsOneWidget);
      expect(find.text('smoke/pass_basic'), findsOneWidget);
      expect(find.byType(DashboardStatusIcon), findsOneWidget);
    });

    testWidgets('status icon reflects the selected result status', (
      tester,
    ) async {
      await _pump(tester, _selection(status: TestStatus.fail));
      expect(tester.takeException(), isNull);
      final icon = tester.widget<DashboardStatusIcon>(
        find.byType(DashboardStatusIcon),
      );
      expect(icon.status, TestStatus.fail);
    });

    testWidgets('locale sweep renders without exceptions', (tester) async {
      for (final locale in const [
        Locale('en'),
        Locale('zh', 'CN'),
        Locale('zh'),
        Locale('ja'),
        Locale('ko'),
      ]) {
        await _pump(tester, _selection(), locale: locale);
        expect(tester.takeException(), isNull, reason: '$locale');
      }
    });
  });
}
