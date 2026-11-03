// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
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

/// A strip above the app's navigator (as the licence-expiry strip is), and a
/// toolbar above the content, inside a nested navigator like the one each file
/// tab has: the nested overlay's origin is not the root overlay's.
const double _strip = 30;
const double _toolbar = 55;

void main() {
  testWidgets(
    'the results row menu opens at the click inside a tab navigator',
    (
      tester,
    ) async {
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
          finishedAt: DateTime.utc(
            2026,
            5,
          ).add(const Duration(milliseconds: 50)),
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
            builder: (context, navigator) => Column(
              children: <Widget>[
                const SizedBox(height: _strip),
                Expanded(child: navigator!),
              ],
            ),
            home: Scaffold(
              body: Column(
                children: <Widget>[
                  const SizedBox(height: _toolbar),
                  Expanded(
                    child: Navigator(
                      onGenerateRoute: (_) => MaterialPageRoute<void>(
                        builder: (_) => const Align(
                          alignment: Alignment.topLeft,
                          child: SizedBox(
                            width: 1200,
                            child: DashboardResultsTable(),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Sanity: the nested overlay really is offset from the root overlay, or
      // this test could not fail.
      final nested = tester.getTopLeft(find.byType(Overlay).last);
      final root = tester.getTopLeft(find.byType(Overlay).first);
      expect(nested.dy - root.dy, _toolbar);

      final click = tester.getCenter(find.text('alu'));
      await tester.tapAt(click, buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      final firstItem = tester.getTopLeft(
        find.byType(PopupMenuItem<void>).first,
      );
      // The menu's own vertical padding sits above its first item.
      const menuPadding = 8.0;
      expect(firstItem.dx, closeTo(click.dx, 2));
      expect(firstItem.dy - menuPadding, closeTo(click.dy, 2));
    },
  );
}
