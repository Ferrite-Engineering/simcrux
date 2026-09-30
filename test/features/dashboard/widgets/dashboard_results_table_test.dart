// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_run.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_row_extensions.dart';
import 'package:simcrux/features/dashboard/widgets/dashboard_results_table.dart';
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

Widget _wrap(Widget child, {Locale locale = const Locale('en')}) {
  return ProviderScope(
    child: MaterialApp(
      locale: locale,
      localizationsDelegates: const [
        L10N.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: L10N.supportedLocales,
      home: Scaffold(body: SizedBox(width: 1200, child: child)),
    ),
  );
}

void main() {
  group('DashboardResultsTable', () {
    testWidgets('renders empty placeholder when no run is active', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const DashboardResultsTable()));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.text(
          L10N.of(tester.element(find.byType(Scaffold))).dashboardEmpty,
        ),
        findsOneWidget,
      );
    });

    testWidgets('renders results when a run is publishing rows', (
      tester,
    ) async {
      final run = TestRun(
        id: 'r1',
        startedAt: DateTime.utc(2026, 5),
        testIds: const ['unit/alu', 'unit/regfile'],
      );
      final store = InMemoryResultStore.forRun(run);
      await store.recordResult(_result('unit/alu', TestStatus.pass));
      await store.recordResult(_result('unit/regfile', TestStatus.fail));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            resultStoreProvider.overrideWith(
              () => _ImmediateResultStoreNotifier(store),
            ),
          ],
          child: const MaterialApp(
            localizationsDelegates: [
              L10N.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: L10N.supportedLocales,
            home: Scaffold(
              body: SizedBox(width: 1200, child: DashboardResultsTable()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('alu'), findsOneWidget);
      expect(find.text('regfile'), findsOneWidget);
    });

    testWidgets('locale sweep renders without exceptions in en/zh/ja/ko', (
      tester,
    ) async {
      for (final locale in const [
        Locale('en'),
        Locale('zh'),
        Locale('ja'),
        Locale('ko'),
      ]) {
        await tester.pumpWidget(
          _wrap(const DashboardResultsTable(), locale: locale),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$locale');
      }
    });
  });

  group('DashboardResultsTable row keyboard', () {
    // A row's one keyboard stop is its check box. Space is the check box's
    // own key; Enter is the keyboard form of clicking the row, which opens
    // the test in the inspector.
    Future<ProviderContainer> pumpAndFocusFirstRow(WidgetTester tester) async {
      final run = TestRun(
        id: 'r1',
        startedAt: DateTime.utc(2026, 5),
        testIds: const ['unit/alu', 'unit/regfile'],
      );
      final store = InMemoryResultStore.forRun(run);
      await store.recordResult(_result('unit/alu', TestStatus.pass));
      await store.recordResult(_result('unit/regfile', TestStatus.fail));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            resultStoreProvider.overrideWith(
              () => _ImmediateResultStoreNotifier(store),
            ),
          ],
          child: MaterialApp(
            theme: ThemeData(platform: TargetPlatform.windows),
            localizationsDelegates: const [
              L10N.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: L10N.supportedLocales,
            home: const Scaffold(
              body: SizedBox(width: 1200, child: DashboardResultsTable()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final checkbox = find.byType(Checkbox).first;
      Focus.of(
        tester.element(
          find.descendant(of: checkbox, matching: find.byType(CustomPaint)),
        ),
      ).requestFocus();
      await tester.pump();
      return ProviderScope.containerOf(
        tester.element(find.byType(DashboardResultsTable)),
      );
    }

    testWidgets('Enter opens the row in the inspector', (tester) async {
      final container = await pumpAndFocusFirstRow(tester);
      final firstRowId = container
          .read(dashboardRowsProvider)
          .requireValue
          .first
          .testId;

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(container.read(selectedTestIdProvider), firstRowId);
      expect(container.read(dashboardSelectionProvider), isEmpty);
    });

    testWidgets('Space toggles the check box and opens nothing', (
      tester,
    ) async {
      final container = await pumpAndFocusFirstRow(tester);
      final firstRowId = container
          .read(dashboardRowsProvider)
          .requireValue
          .first
          .testId;

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();

      expect(container.read(dashboardSelectionProvider), {firstRowId});
      expect(container.read(selectedTestIdProvider), isNull);
    });
  });

  group('DashboardResultsTable row context menu', () {
    // A single-row run whose only test is 'unit/alu'.
    Future<void> pumpRow(
      WidgetTester tester, {
      required List<Override> overrides,
      TargetPlatform? platform,
    }) async {
      final run = TestRun(
        id: 'r1',
        startedAt: DateTime.utc(2026, 5),
        testIds: const ['unit/alu'],
      );
      final store = InMemoryResultStore.forRun(run);
      await store.recordResult(_result('unit/alu', TestStatus.pass));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            resultStoreProvider.overrideWith(
              () => _ImmediateResultStoreNotifier(store),
            ),
            ...overrides,
          ],
          child: MaterialApp(
            theme: platform == null ? null : ThemeData(platform: platform),
            localizationsDelegates: const [
              L10N.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: L10N.supportedLocales,
            home: const Scaffold(
              body: SizedBox(width: 1200, child: DashboardResultsTable()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('alu'), findsOneWidget);
    }

    // A Pro-style builder that contributes one findable entry so the menu
    // has something to show (open-core's default builder is empty).
    Override contributingBuilder() {
      return dashboardRowContextMenuBuilderProvider.overrideWithValue(
        (context, ref, row) => const <PopupMenuEntry<void>>[
          PopupMenuItem<void>(child: Text('Cross-probe to peer')),
        ],
      );
    }

    testWidgets('opens on right-click (secondary tap) on desktop', (
      tester,
    ) async {
      await pumpRow(
        tester,
        overrides: [contributingBuilder()],
        platform: TargetPlatform.linux,
      );
      await tester.tap(find.text('alu'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('Cross-probe to peer'), findsOneWidget);
    });

    testWidgets('opens on long-press on a touch platform', (tester) async {
      await pumpRow(
        tester,
        overrides: [contributingBuilder()],
        platform: TargetPlatform.iOS,
      );
      await tester.longPress(find.text('alu'));
      await tester.pumpAndSettle();
      expect(find.text('Cross-probe to peer'), findsOneWidget);
    });

    testWidgets('right-click is inert with the open-core empty builder', (
      tester,
    ) async {
      // No override → the open-core default builder returns no entries, so
      // the gesture resolves without surfacing a menu.
      await pumpRow(
        tester,
        overrides: const [],
        platform: TargetPlatform.linux,
      );
      await tester.tap(find.text('alu'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.byType(PopupMenuItem<void>), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}

class _ImmediateResultStoreNotifier extends ResultStoreNotifier {
  _ImmediateResultStoreNotifier(this._store);
  final InMemoryResultStore _store;

  @override
  InMemoryResultStore build() => _store;
}
