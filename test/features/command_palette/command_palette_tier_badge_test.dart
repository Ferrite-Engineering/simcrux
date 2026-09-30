// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/shortcuts/simcrux_action.dart';
import 'package:simcrux/core/shortcuts/simcrux_action_context.dart';
import 'package:simcrux/features/command_palette/widgets/command_palette_dialog.dart';
import 'package:simcrux/features/workspace/providers/simcrux_action_context_provider.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/l10n/generated/app_localizations_en.dart';
import 'package:simcrux/l10n/generated/app_localizations_ja.dart';
import 'package:simcrux/l10n/generated/app_localizations_ko.dart';
import 'package:simcrux/l10n/generated/app_localizations_zh.dart';
import 'package:simcrux/shared/widgets/simcrux_feature_tier_badge.dart';

/// The command palette renders a [SimCruxFeatureTierBadge] on every Pro action row
/// (via the palette's `trailingBuilder` wired to `SimcruxAction.requiredTier`)
/// and none on open-core rows. This makes Pro actions distinguishable from
/// free ones in the palette.
Future<void> _pumpPalette(
  WidgetTester tester, {
  Locale locale = const Locale('en'),
}) async {
  // Roomy surface so several filtered rows render (the list virtualizes).
  tester.view.physicalSize = const Size(1200, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        // The palette lists visible AND enabled actions, so it needs a
        // context where the gated ones are live — otherwise the Pro actions
        // (which require a loaded config / results) never render and the
        // badge assertions have nothing to find.
        simcruxActionContextProvider.overrideWithValue(
          const SimcruxActionContext(
            hasOpenTab: true,
            hasConfig: true,
            hasResults: true,
            hasSelectedTest: true,
            paneCount: 2,
            tabCountInActivePane: 2,
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
          body: CommandPaletteDialog(onAction: (_) {}),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _search(WidgetTester tester, String query) async {
  await tester.enterText(find.byType(TextField), query);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Pro action rows render a SimCruxFeatureTierBadge', (
    tester,
  ) async {
    await _pumpPalette(tester);
    // "Trend" fuzzy-matches the (Pro) trend-chart actions.
    await _search(tester, 'Trend');
    expect(find.byType(SimCruxFeatureTierBadge), findsWidgets);
  });

  testWidgets('open-core action rows render no badge', (tester) async {
    await _pumpPalette(tester);
    // "toggle" matches only the free view-toggle actions — no Pro label is a
    // subsequence of it.
    await _search(tester, 'toggle');
    expect(find.textContaining('Toggle'), findsWidgets);
    expect(find.byType(SimCruxFeatureTierBadge), findsNothing);
  });

  testWidgets('Pro badge renders for a Pro action in every locale', (
    tester,
  ) async {
    final byLocale = <Locale, L10N>{
      const Locale('en'): L10NEn(),
      const Locale('zh', 'CN'): L10NZhCn(),
      const Locale('zh'): L10NZh(),
      const Locale('ja'): L10NJa(),
      const Locale('ko'): L10NKo(),
    };
    for (final entry in byLocale.entries) {
      await _pumpPalette(tester, locale: entry.key);
      // Filter to a known Pro action by its localized label.
      await _search(
        tester,
        SimcruxAction.showTrendChart.label(entry.value),
      );
      expect(
        find.byType(SimCruxFeatureTierBadge),
        findsWidgets,
        reason: 'locale ${entry.key.languageCode}',
      );
    }
  });
}
