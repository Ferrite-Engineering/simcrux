// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/features/dashboard/models/dashboard_filter.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/dashboard/providers/filter_presets_provider.dart';
import 'package:simcrux/features/dashboard/widgets/dashboard_filter_presets_bar.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

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

ProviderContainer _containerOf(WidgetTester tester) =>
    ProviderScope.containerOf(
      tester.element(find.byType(DashboardFilterPresetsBar)),
    );

void main() {
  group('DashboardFilterPresetsBar', () {
    testWidgets('renders one unselected chip per saved preset', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const DashboardFilterPresetsBar()));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final presets = _containerOf(tester).read(filterPresetsProvider);
      expect(presets, isNotEmpty);
      expect(find.byType(ChoiceChip), findsNWidgets(presets.length));
      for (final preset in presets) {
        expect(find.widgetWithText(ChoiceChip, preset.name), findsOneWidget);
      }
      for (final chip in tester.widgetList<ChoiceChip>(
        find.byType(ChoiceChip),
      )) {
        expect(chip.selected, isFalse);
      }
    });

    testWidgets('tapping a preset chip applies its filter and selects it', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const DashboardFilterPresetsBar()));
      await tester.pumpAndSettle();
      final container = _containerOf(tester);
      final preset = container.read(filterPresetsProvider).first;

      await tester.tap(find.widgetWithText(ChoiceChip, preset.name));
      await tester.pumpAndSettle();
      expect(container.read(dashboardFilterProvider), preset.filter);
      final chip = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, preset.name),
      );
      expect(chip.selected, isTrue);
    });

    testWidgets('re-renders when the preset list is replaced', (tester) async {
      await tester.pumpWidget(_wrap(const DashboardFilterPresetsBar()));
      await tester.pumpAndSettle();
      final container = _containerOf(tester);
      final custom = FilterPreset(
        name: 'Slow fails',
        filter: DashboardFilter(
          statuses: const {TestStatus.fail},
          minRuntime: const Duration(seconds: 5),
        ),
      );
      container.read(filterPresetsProvider.notifier).replaceAll([custom]);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(ChoiceChip), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, custom.name), findsOneWidget);
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
          _wrap(const DashboardFilterPresetsBar(), locale: locale),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$locale');
      }
    });
  });
}
