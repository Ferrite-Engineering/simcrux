// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_status_bar/crux_status_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/dashboard_view_mode.dart';
import 'package:simcrux/domain/interfaces/trend_store.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_banners_extensions.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_view_mode_provider.dart';
import 'package:simcrux/features/dashboard/widgets/dashboard_filter_bar.dart';
import 'package:simcrux/features/dashboard/widgets/dashboard_filter_presets_bar.dart';
import 'package:simcrux/features/dashboard/widgets/dashboard_heatmap_view.dart';
import 'package:simcrux/features/dashboard/widgets/dashboard_results_table.dart';
import 'package:simcrux/features/dashboard/widgets/dashboard_view.dart';
import 'package:simcrux/features/dashboard/widgets/dashboard_view_mode_toggle.dart';
import 'package:simcrux/features/dashboard/widgets/simcrux_toolbar.dart';
import 'package:simcrux/features/inspector/providers/test_trend_provider.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

import '../../../support/answered_telemetry.dart';

Widget _wrap(
  Widget child, {
  Locale locale = const Locale('en'),
  List<Override> overrides = const [],
}) {
  return ProviderScope(
    overrides: [
      ...answeredTelemetryOverrides(),
      // Keep trend surfaces static: the leaf trend provider is
      // overridden with fixed data so the RunDeltaStrip inside
      // DashboardView never touches a real TrendStore.
      recentTrendDeltasProvider.overrideWith(
        (ref) async => const <TrendDelta>[],
      ),
      ...overrides,
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
      home: Scaffold(body: child),
    ),
  );
}

ProviderContainer _containerOf(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(DashboardView)));

void _useDesktopSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1600, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  group('DashboardView', () {
    testWidgets('renders the full dashboard chrome with the table view', (
      tester,
    ) async {
      _useDesktopSurface(tester);
      await tester.pumpWidget(_wrap(const DashboardView()));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // The tier-1 action toolbar was hoisted out of the center pane up to
      // the tab shell; DashboardView does not own it.
      expect(find.byType(SimcruxToolbar), findsNothing);
      expect(find.byType(DashboardFilterPresetsBar), findsOneWidget);
      expect(find.byType(DashboardFilterBar), findsOneWidget);
      expect(find.byType(DashboardViewModeToggle), findsOneWidget);
      expect(find.byType(DashboardResultsTable), findsOneWidget);
      expect(find.byType(DashboardHeatmapView), findsNothing);
      // Run totals belong to the window-bottom RegressionStatusBar, not to a
      // second strip stacked inside this pane.
      expect(find.byType(CruxStatusBar), findsNothing);
      // The empty table body renders its localized placeholder.
      expect(
        find.text(
          L10N.of(tester.element(find.byType(Scaffold))).dashboardEmpty,
        ),
        findsOneWidget,
      );
    });

    testWidgets('tapping the heatmap segment swaps the body view', (
      tester,
    ) async {
      _useDesktopSurface(tester);
      await tester.pumpWidget(_wrap(const DashboardView()));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.grid_on_outlined));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        _containerOf(tester).read(dashboardViewModeProvider),
        DashboardViewMode.heatmap,
      );
      expect(find.byType(DashboardHeatmapView), findsOneWidget);
      expect(find.byType(DashboardResultsTable), findsNothing);
    });

    testWidgets('inspector-focused mode falls back to the table body', (
      tester,
    ) async {
      _useDesktopSurface(tester);
      await tester.pumpWidget(_wrap(const DashboardView()));
      await tester.pumpAndSettle();
      _containerOf(tester)
          .read(dashboardViewModeProvider.notifier)
          .setMode(DashboardViewMode.inspectorFocused);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(DashboardResultsTable), findsOneWidget);
      expect(find.byType(DashboardHeatmapView), findsNothing);
    });

    testWidgets('renders extension-contributed banners above the chrome', (
      tester,
    ) async {
      _useDesktopSurface(tester);
      await tester.pumpWidget(
        _wrap(
          const DashboardView(),
          overrides: [
            dashboardBannersProvider.overrideWithValue(const [
              SizedBox(key: Key('pro-banner'), height: 24),
            ]),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final banner = find.byKey(const Key('pro-banner'));
      expect(banner, findsOneWidget);
      // The banner sits above the dashboard's own chrome (the toolbar now
      // lives in the tab shell, above this widget entirely).
      expect(
        tester.getTopLeft(banner).dy,
        lessThan(tester.getTopLeft(find.byType(DashboardFilterPresetsBar)).dy),
      );
    });

    // The dashboard shipped overflowing at the app's own default window
    // size: the filter bar wraps its chips, so a centre pane narrow enough
    // to wrap them three deep needed more height than the pane had, and
    // Flutter reported the shortfall as striped banners over the results
    // table. The chrome is capped and scrolls now; these pin that it stays
    // silent at the sizes the layout can actually produce.
    group('cramped panes', () {
      Future<void> pumpAt(WidgetTester tester, Size size) async {
        tester.view
          ..physicalSize = size
          ..devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(_wrap(const DashboardView()));
        await tester.pumpAndSettle();
      }

      testWidgets('a default-window-sized centre pane does not overflow', (
        tester,
      ) async {
        await pumpAt(tester, const Size(620, 460));
        expect(tester.takeException(), isNull);
      });

      testWidgets('the shortest pane the layout allows does not overflow — '
          'this is the log divider dragged to its stop', (tester) async {
        // Matches SimcruxIdeLayout's centerMinSize.
        await pumpAt(tester, const Size(620, 200));
        expect(tester.takeException(), isNull);
      });

      testWidgets('a pane narrower than the table scrolls it horizontally '
          'rather than squeezing the columns to single letters', (
        tester,
      ) async {
        await pumpAt(tester, const Size(420, 700));
        expect(tester.takeException(), isNull);
        final scrollers = tester.widgetList<SingleChildScrollView>(
          find.descendant(
            of: find.byType(DashboardResultsTable),
            matching: find.byType(SingleChildScrollView),
          ),
        );
        expect(
          scrollers.any((s) => s.scrollDirection == Axis.horizontal),
          isTrue,
        );
      });

      testWidgets('a roomy pane leaves the table unscrolled', (tester) async {
        await pumpAt(tester, const Size(1600, 1200));
        expect(tester.takeException(), isNull);
        final scrollers = tester.widgetList<SingleChildScrollView>(
          find.descendant(
            of: find.byType(DashboardResultsTable),
            matching: find.byType(SingleChildScrollView),
          ),
        );
        expect(
          scrollers.any((s) => s.scrollDirection == Axis.horizontal),
          isFalse,
        );
      });
    });

    testWidgets('locale sweep renders without exceptions', (tester) async {
      _useDesktopSurface(tester);
      for (final locale in const [
        Locale('en'),
        Locale('zh', 'CN'),
        Locale('zh'),
        Locale('ja'),
        Locale('ko'),
      ]) {
        await tester.pumpWidget(_wrap(const DashboardView(), locale: locale));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$locale');
      }
    });
  });
}
