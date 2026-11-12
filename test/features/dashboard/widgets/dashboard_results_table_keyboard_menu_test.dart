// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0
//
// LOCALE_SWEEP_EXEMPT: asserts which keys open the menu, not what its labels
// say.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_run.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_row_extensions.dart';
import 'package:simcrux/features/dashboard/widgets/dashboard_results_table.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/result_store/in_memory_result_store.dart';
import 'package:simcrux/services/result_store/result_store_provider.dart';

class _ImmediateResultStoreNotifier extends ResultStoreNotifier {
  _ImmediateResultStoreNotifier(this._store);
  final InMemoryResultStore _store;

  @override
  InMemoryResultStore build() => _store;
}

Future<void> _pumpTable(WidgetTester tester) async {
  final run = TestRun(
    id: 'r1',
    startedAt: DateTime.utc(2026, 5),
    testIds: const ['unit/alu'],
  );
  final store = InMemoryResultStore.forRun(run);
  await store.recordResult(
    TestResult(
      testId: 'unit/alu',
      runId: 'r1',
      status: TestStatus.pass,
      startedAt: DateTime.utc(2026, 5),
      finishedAt: DateTime.utc(2026, 5).add(const Duration(milliseconds: 50)),
    ),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        resultStoreProvider.overrideWith(
          () => _ImmediateResultStoreNotifier(store),
        ),
        dashboardRowContextMenuBuilderProvider.overrideWithValue(
          (context, ref, row, position) => const <PopupMenuEntry<void>>[
            PopupMenuItem<void>(child: Text('Contributed entry')),
          ],
        ),
      ],
      child: MaterialApp(
        theme: ThemeData(platform: TargetPlatform.linux),
        localizationsDelegates: const [
          L10N.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: L10N.supportedLocales,
        home: const Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: 1200, child: DashboardResultsTable()),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Tabs through the table until [open] makes the contributed entry appear.
Future<bool> _tabUntilMenuOpens(
  WidgetTester tester,
  Future<void> Function() open,
) async {
  for (var i = 0; i < 12; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await open();
    await tester.pumpAndSettle();
    if (find.text('Contributed entry').evaluate().isNotEmpty) return true;
  }
  return false;
}

void main() {
  testWidgets('Shift+F10 on a results row opens its context menu', (
    tester,
  ) async {
    await _pumpTable(tester);
    final opened = await _tabUntilMenuOpens(tester, () async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.f10);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    });
    expect(opened, isTrue);
  });

  testWidgets('the Menu key on a results row opens its context menu', (
    tester,
  ) async {
    await _pumpTable(tester);
    final opened = await _tabUntilMenuOpens(
      tester,
      () => tester.sendKeyEvent(LogicalKeyboardKey.contextMenu),
    );
    expect(opened, isTrue);
  });

  testWidgets('a bare F10 opens nothing', (tester) async {
    await _pumpTable(tester);
    final opened = await _tabUntilMenuOpens(
      tester,
      () => tester.sendKeyEvent(LogicalKeyboardKey.f10),
    );
    expect(opened, isFalse);
  });
}
