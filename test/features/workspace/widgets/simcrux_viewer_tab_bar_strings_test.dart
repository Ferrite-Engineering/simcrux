// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/features/workspace/widgets/simcrux_viewer_tab_bar_strings.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

Future<SimcruxViewerTabBarStrings> _stringsFor(
  WidgetTester tester,
  Locale locale,
) async {
  late SimcruxViewerTabBarStrings strings;
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: const [
        L10N.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: L10N.supportedLocales,
      home: Builder(
        builder: (context) {
          strings = SimcruxViewerTabBarStrings(L10N.of(context));
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return strings;
}

void main() {
  group('SimcruxViewerTabBarStrings — locale sweep', () {
    for (final locale in const [
      Locale('en'),
      Locale('zh', 'CN'),
      Locale('zh'),
      Locale('ja'),
      Locale('ko'),
    ]) {
      testWidgets('resolves every field for $locale', (tester) async {
        final strings = await _stringsFor(tester, locale);
        // Every field must resolve to a non-empty string in every
        // supported locale; otherwise the ViewerTabBar will render a
        // blank tooltip or label.
        expect(strings.closeTabTooltip, isNotEmpty);
        expect(strings.newTabTooltip, isNotEmpty);
        expect(strings.newTabDefaultDisplayName, isNotEmpty);
        expect(strings.unnamedTabFallback, isNotEmpty);
        expect(strings.closeTabMenuItem, isNotEmpty);
        expect(strings.closeOtherTabsMenuItem, isNotEmpty);
        expect(strings.closeTabsToTheRightMenuItem, isNotEmpty);
        expect(strings.moveToNewWindowMenuItem, isNotEmpty);
        expect(strings.multiWindowUnavailableTooltip, isNotEmpty);
        expect(strings.activePaneAccessibilityLabel, isNotEmpty);
        expect(strings.dragToPaneAccessibilityHint, isNotEmpty);
        expect(strings.reorderHandleTooltip, isNotEmpty);
        // The per-chip close button names its tab, so several open tabs are
        // not announced as a row of identical "Close tab" buttons.
        expect(strings.closeTabTooltipFor('uart.yaml'), contains('uart.yaml'));
        expect(
          strings.closeTabTooltipFor('uart.yaml'),
          isNot(strings.closeTabTooltip),
        );
      });
    }
  });
}
