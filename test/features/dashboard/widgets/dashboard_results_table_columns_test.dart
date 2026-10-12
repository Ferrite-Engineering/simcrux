// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_settings/crux_settings.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_run.dart';
import 'package:simcrux/features/dashboard/models/dashboard_column_layout.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_column_layout_provider.dart';
import 'package:simcrux/features/dashboard/services/dashboard_column_layout_codec.dart';
import 'package:simcrux/features/dashboard/widgets/dashboard_results_table.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/result_store/in_memory_result_store.dart';
import 'package:simcrux/services/result_store/result_store_provider.dart';

void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
  });

  Future<ProviderContainer> pumpTable(
    WidgetTester tester, {
    Locale locale = const Locale('en'),
    double width = 1400,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1400, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final run = TestRun(
      id: 'r1',
      startedAt: DateTime.utc(2026, 5),
      testIds: const ['unit/alu_carry_chain'],
    );
    final store = InMemoryResultStore.forRun(run);
    await store.recordResult(
      TestResult(
        testId: 'unit/alu_carry_chain',
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
          dashboardColumnLayoutSettingsServiceProvider.overrideWithValue(
            SettingsService<DashboardColumnLayout>(
              const DashboardColumnLayoutCodec(),
              prefsOverride: prefs,
            ),
          ),
        ],
        child: MaterialApp(
          locale: locale,
          localizationsDelegates: const [
            L10N.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: L10N.supportedLocales,
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: const DashboardResultsTable(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(
      tester.element(find.byType(DashboardResultsTable)),
    );
  }

  /// Left edge of the Test header and of the Test cell's text in the row.
  (double, double) testColumnLeft(WidgetTester tester) => (
    tester
        .getTopLeft(find.byKey(const ValueKey('dashboardHeader-testName')))
        .dx,
    tester.getTopLeft(find.text('alu_carry_chain')).dx,
  );

  testWidgets('dragging a divider moves the column in the header and the '
      'rows together, and saves when the drag ends', (tester) async {
    await pumpTable(tester);
    final (headerBefore, rowBefore) = testColumnLeft(tester);

    await tester.drag(
      find.byKey(const ValueKey('dashboardResize-suite')),
      const Offset(80, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    final (headerAfter, rowAfter) = testColumnLeft(tester);
    expect(headerAfter - headerBefore, closeTo(80, 2));
    expect(rowAfter - rowBefore, closeTo(80, 2));

    expect(
      await const DashboardColumnLayoutCodec().load(prefs),
      isNot(DashboardColumnLayout.defaults),
    );
  });

  testWidgets('double-clicking a divider restores the default widths', (
    tester,
  ) async {
    final container = await pumpTable(tester);
    await tester.drag(
      find.byKey(const ValueKey('dashboardResize-suite')),
      const Offset(80, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(
      container.read(dashboardColumnLayoutProvider),
      isNot(DashboardColumnLayout.defaults),
    );

    final handle = find.byKey(const ValueKey('dashboardResize-simulator'));
    await tester.tap(handle);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(handle);
    await tester.pumpAndSettle();
    expect(
      container.read(dashboardColumnLayoutProvider),
      DashboardColumnLayout.defaults,
    );
  });

  testWidgets('the last column has no divider; every other one does', (
    tester,
  ) async {
    await pumpTable(tester);
    for (final column in DashboardColumnLayout.columns) {
      expect(
        find.byKey(ValueKey('dashboardResize-${column.name}')),
        column == DashboardColumnLayout.columns.last
            ? findsNothing
            : findsOneWidget,
        reason: column.name,
      );
    }
  });

  testWidgets('a header label may use its whole cell, not half of it', (
    tester,
  ) async {
    // The label and the sort-arrow slot were both Flexible, which split the
    // cell between them and showed "Simul…" in a column with room for
    // "Simulator". The label's room is the cell less its 16 px padding and
    // the 18 px arrow slot. (The test font is about twice as wide as the
    // real one, so whether a label fits is not something to assert here.)
    await pumpTable(tester, width: 1060);
    for (final column in DashboardColumnLayout.columns) {
      final cell = tester.getSize(
        find.byKey(ValueKey('dashboardHeader-${column.name}')),
      );
      // The label is the first RichText; the active column's sort glyph is
      // a second one.
      final paragraph = tester.renderObject<RenderParagraph>(
        find
            .descendant(
              of: find.byKey(ValueKey('dashboardHeader-${column.name}')),
              matching: find.byType(RichText),
            )
            .first,
      );
      expect(
        paragraph.constraints.maxWidth,
        closeTo(cell.width - 16 - 18, 0.5),
        reason: column.name,
      );
    }
  });

  testWidgets('a text cell carries its full value as a tooltip', (
    tester,
  ) async {
    await pumpTable(tester);
    expect(find.byTooltip('alu_carry_chain'), findsOneWidget);
    expect(find.byTooltip('unit'), findsOneWidget);
  });

  testWidgets('the header sits on surfaceContainerHighest, its labels in '
      'onSurfaceVariant, as in LintCrux', (tester) async {
    await pumpTable(tester);
    final scheme = Theme.of(
      tester.element(find.byType(DashboardResultsTable)),
    ).colorScheme;
    final label = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('dashboardHeader-testName')),
        matching: find.byType(Text),
      ),
    );
    expect(label.style?.color, scheme.onSurfaceVariant);
    expect(label.style?.fontWeight, FontWeight.w600);
    final header = tester.widget<Container>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('dashboardHeader-testName')),
            matching: find.byType(Container),
          )
          .last,
    );
    expect(
      (header.decoration! as BoxDecoration).color,
      scheme.surfaceContainerHighest,
    );
  });

  testWidgets('dividers stay out of the semantics tree', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpTable(tester);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('dashboardResize-suite')),
        matching: find.byWidgetPredicate(
          (w) => w is Semantics && (w.properties.button ?? false),
        ),
      ),
      findsNothing,
    );
    handle.dispose();
  });

  for (final locale in const [
    Locale('zh', 'CN'),
    Locale('zh'),
    Locale('ja'),
    Locale('ko'),
  ]) {
    testWidgets('locale ${locale.toLanguageTag()}: the dividers render', (
      tester,
    ) async {
      await pumpTable(tester, locale: locale);
      expect(
        find.byKey(const ValueKey('dashboardResize-suite')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
}

class _ImmediateResultStoreNotifier extends ResultStoreNotifier {
  _ImmediateResultStoreNotifier(this._store);
  final InMemoryResultStore _store;

  @override
  InMemoryResultStore build() => _store;
}
