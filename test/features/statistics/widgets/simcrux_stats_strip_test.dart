// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/features/statistics/widgets/simcrux_stats_strip.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

Widget _wrap({Locale locale = const Locale('en')}) => ProviderScope(
  child: MaterialApp(
    locale: locale,
    localizationsDelegates: const [
      L10N.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: L10N.supportedLocales,
    home: const Scaffold(body: SimcruxStatsStrip()),
  ),
);

void main() {
  group('SimcruxStatsStrip', () {
    testWidgets('the disclosure control is named with the full word', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_wrap());
      await tester.pump();

      final l10n = L10N.of(tester.element(find.byType(SimcruxStatsStrip)));
      // The visible caption is the short "Stats"; a screen reader hears
      // "Statistics", once, as a button with a collapsed state.
      expect(find.text(l10n.statsStripLabel), findsOneWidget);
      expect(
        tester.getSemantics(find.bySemanticsLabel(l10n.statisticsStripTitle)),
        isSemantics(
          label: l10n.statisticsStripTitle,
          isButton: true,
          hasExpandedState: true,
          isFocusable: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );
      handle.dispose();
    });

    for (final locale in const [
      Locale('en'),
      Locale('zh', 'CN'),
      Locale('zh'),
      Locale('ja'),
      Locale('ko'),
    ]) {
      testWidgets('renders without exceptions in $locale', (tester) async {
        await tester.pumpWidget(_wrap(locale: locale));
        await tester.pump();
        expect(tester.takeException(), isNull);
      });
    }
  });
}
