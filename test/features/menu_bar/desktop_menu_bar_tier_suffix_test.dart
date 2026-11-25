// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/shortcuts/simcrux_action.dart';
import 'package:simcrux/features/menu_bar/widgets/desktop_menu_bar.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// The native desktop menu bar can render only string labels, so Pro/ENT
/// items mark their tier with a localized parenthetical suffix appended to
/// the label (open-core items get none). This asserts the wiring in
/// `DesktopMenuBar.makeItem` — a Pro action's menu label ends with " (PRO)",
/// a free action's does not — across locales.

/// Recursively collects every leaf [PlatformMenuItem] label from a menu tree.
Iterable<String> _labels(List<PlatformMenuItem> items) sync* {
  for (final item in items) {
    if (item is PlatformMenu) {
      yield* _labels(item.menus);
    } else if (item is PlatformMenuItemGroup) {
      yield* _labels(item.members);
    } else {
      yield item.label;
    }
  }
}

Future<List<String>> _menuLabels(
  WidgetTester tester, {
  required Locale locale,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        locale: locale,
        theme: ThemeData(platform: TargetPlatform.macOS),
        localizationsDelegates: const [
          L10N.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: L10N.supportedLocales,
        home: DesktopMenuBar(
          onAction: (_) {},
          child: const SizedBox(),
        ),
      ),
    ),
  );
  await tester.pump();
  final bar = tester.widget<PlatformMenuBar>(find.byType(PlatformMenuBar));
  return _labels(bar.menus).toList();
}

void main() {
  group('Edit commands', () {
    Widget app(TargetPlatform platform) => ProviderScope(
      child: MaterialApp(
        theme: ThemeData(platform: platform),
        localizationsDelegates: const [
          L10N.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: L10N.supportedLocales,
        home: DesktopMenuBar(
          onAction: (_) {},
          child: const SizedBox(),
        ),
      ),
    );

    testWidgets('the macOS Edit menu leads with Cut, Copy, Paste and Select '
        'All on their Cmd chords', (tester) async {
      await tester.pumpWidget(app(TargetPlatform.macOS));
      await tester.pumpAndSettle();
      final l10n = L10N.of(tester.element(find.byType(PlatformMenuBar)));
      final bar = tester.widget<PlatformMenuBar>(find.byType(PlatformMenuBar));
      final edit = bar.menus.whereType<PlatformMenu>().firstWhere(
        (m) => m.label == l10n.actionCategoryEdit,
      );
      final first = (edit.menus.first as PlatformMenuItemGroup).members;
      expect(
        [for (final i in first) i.label],
        [
          l10n.menuEditCut,
          l10n.menuEditCopy,
          l10n.menuEditPaste,
          l10n.menuEditSelectAll,
        ],
      );
      expect(
        [for (final i in first) i.label],
        [
          'Cut',
          'Copy',
          'Paste',
          'Select All',
        ],
      );
      for (final item in first) {
        final chord = item.shortcut! as SingleActivator;
        expect(chord.meta, isTrue, reason: item.label);
      }
    });

    for (final platform in [TargetPlatform.windows, TargetPlatform.linux]) {
      testWidgets('on $platform there is no native menu bar and no Copy item '
          'in the in-window one', (tester) async {
        await tester.pumpWidget(app(platform));
        await tester.pumpAndSettle();
        expect(find.byType(PlatformMenuBar), findsNothing);
        final bar = tester.widget<MenuBar>(find.byType(MenuBar));
        final labels = <String>[];
        void visit(Widget w) {
          if (w is SubmenuButton) {
            w.menuChildren.forEach(visit);
          } else if (w is MenuItemButton && w.child is Text) {
            labels.add((w.child! as Text).data ?? '');
          }
        }

        bar.children.forEach(visit);
        expect(labels, isNotEmpty);
        expect(labels, isNot(contains('Copy')));
        expect(labels, isNot(contains('Select All')));
      });
    }
  });

  testWidgets('Pro menu items get the (PRO) suffix, free items do not', (
    tester,
  ) async {
    final labels = await _menuLabels(tester, locale: const Locale('en'));
    final l10n = L10N.of(
      tester.element(find.byType(DesktopMenuBar)),
    );

    // A Pro action (showTrendChart lives in the Tools menu) → suffixed.
    final proLabel = SimcruxAction.showTrendChart.label(l10n);
    expect(
      labels,
      contains('$proLabel (PRO)'),
      reason: 'Pro menu item must carry the (PRO) suffix',
    );

    // A free action (openProject) → no suffix, and never a stray (PRO).
    final freeLabel = SimcruxAction.openProject.label(l10n);
    expect(labels, contains(freeLabel));
    expect(
      labels.where((l) => l.startsWith(freeLabel)),
      everyElement(isNot(contains('(PRO)'))),
    );
  });

  testWidgets('the (PRO) suffix is present in every locale', (tester) async {
    for (final locale in const [
      Locale('en'),
      Locale('zh', 'CN'),
      Locale('zh'),
      Locale('ja'),
      Locale('ko'),
    ]) {
      final labels = await _menuLabels(tester, locale: locale);
      expect(
        labels.any((l) => l.endsWith(' (PRO)')),
        isTrue,
        reason: 'locale ${locale.toLanguageTag()} has no (PRO)-suffixed item',
      );
    }
  });
}
