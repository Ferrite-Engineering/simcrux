// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/dashboard_view_mode.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_view_mode_provider.dart';
import 'package:simcrux/features/dashboard/widgets/dashboard_view_mode_toggle.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

import '../../../support/answered_telemetry.dart';

Widget _wrap(Widget child, {Locale locale = const Locale('en')}) {
  return ProviderScope(
    overrides: answeredTelemetryOverrides(),
    child: MaterialApp(
      locale: locale,
      localizationsDelegates: const [
        L10N.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: L10N.supportedLocales,
      home: Scaffold(body: child),
    ),
  );
}

ProviderContainer _containerOf(WidgetTester tester) =>
    ProviderScope.containerOf(
      tester.element(find.byType(DashboardViewModeToggle)),
    );

void main() {
  group('DashboardViewModeToggle', () {
    testWidgets('renders a segmented control with the table mode selected', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const DashboardViewModeToggle()));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(SegmentedButton<DashboardViewMode>), findsOneWidget);
      expect(find.byIcon(Icons.table_rows_outlined), findsOneWidget);
      expect(find.byIcon(Icons.grid_on_outlined), findsOneWidget);
      final button = tester.widget<SegmentedButton<DashboardViewMode>>(
        find.byType(SegmentedButton<DashboardViewMode>),
      );
      expect(button.selected, {DashboardViewMode.table});
      expect(
        _containerOf(tester).read(dashboardViewModeProvider),
        DashboardViewMode.table,
      );
    });

    testWidgets('renders the localized segment labels', (tester) async {
      await tester.pumpWidget(_wrap(const DashboardViewModeToggle()));
      await tester.pumpAndSettle();
      final l10n = L10N.of(
        tester.element(find.byType(DashboardViewModeToggle)),
      );
      expect(find.text(l10n.dashboardViewModeTable), findsOneWidget);
      expect(find.text(l10n.dashboardViewModeHeatmap), findsOneWidget);
    });

    testWidgets('tapping the heatmap segment switches the provider mode', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const DashboardViewModeToggle()));
      await tester.pumpAndSettle();
      final container = _containerOf(tester);

      await tester.tap(find.byIcon(Icons.grid_on_outlined));
      await tester.pumpAndSettle();
      expect(
        container.read(dashboardViewModeProvider),
        DashboardViewMode.heatmap,
      );
      final button = tester.widget<SegmentedButton<DashboardViewMode>>(
        find.byType(SegmentedButton<DashboardViewMode>),
      );
      expect(button.selected, {DashboardViewMode.heatmap});

      await tester.tap(find.byIcon(Icons.table_rows_outlined));
      await tester.pumpAndSettle();
      expect(
        container.read(dashboardViewModeProvider),
        DashboardViewMode.table,
      );
    });

    testWidgets('reflects an externally-set mode', (tester) async {
      await tester.pumpWidget(_wrap(const DashboardViewModeToggle()));
      await tester.pumpAndSettle();
      _containerOf(tester)
          .read(dashboardViewModeProvider.notifier)
          .setMode(DashboardViewMode.heatmap);
      await tester.pumpAndSettle();
      final button = tester.widget<SegmentedButton<DashboardViewMode>>(
        find.byType(SegmentedButton<DashboardViewMode>),
      );
      expect(button.selected, {DashboardViewMode.heatmap});
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
          _wrap(const DashboardViewModeToggle(), locale: locale),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$locale');
      }
    });
  });
}
