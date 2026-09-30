// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/shortcuts/action_category.dart';
import 'package:simcrux/core/shortcuts/simcrux_action.dart';
import 'package:simcrux/core/shortcuts/simcrux_action_context.dart';
import 'package:simcrux/core/shortcuts/simcrux_action_descriptor.dart';
import 'package:simcrux/core/shortcuts/simcrux_action_descriptors.dart';

void main() {
  // The descriptor table replaced the old deny-set helpers
  // (kMenuHiddenActions / menuVisibleActions / groupedActions). These exercise
  // the same invariants through `groupedActionsFor` / `paletteActionsFor`,
  // which additionally understand enablement.
  const loaded = SimcruxActionContext(
    hasOpenTab: true,
    hasConfig: true,
    hasResults: true,
    hasSelectedTest: true,
    paneCount: 2,
    tabCountInActivePane: 2,
  );

  group('command-palette reachability', () {
    test('openCommandPalette is reachable from the menu (recovery path)', () {
      // Must appear in the menu bar so unbinding Cmd/Ctrl+Shift+P can never
      // make the palette permanently inaccessible.
      expect(
        isActionVisibleIn(
          SimcruxAction.openCommandPalette,
          SimcruxActionSurface.menu,
          loaded,
        ),
        isTrue,
      );
    });

    test('openCommandPalette is excluded from the palette itself', () {
      expect(
        paletteActionsFor(loaded),
        isNot(contains(SimcruxAction.openCommandPalette)),
      );
    });

    test('openCommandPalette is grouped under View in the menu', () {
      // VS Code lists the palette opener at the top of View; the suite
      // menu-consistency pass follows it.
      expect(
        groupedActionsFor(
          SimcruxActionSurface.menu,
          loaded,
        )[ActionCategory.view],
        contains(SimcruxAction.openCommandPalette),
      );
    });
  });

  group('groupedActionsFor', () {
    test('returns a key for every ActionCategory', () {
      final grouped = groupedActionsFor(SimcruxActionSurface.menu, loaded);
      for (final cat in ActionCategory.values) {
        expect(grouped.containsKey(cat), isTrue);
      }
    });

    test('groups actions to match their category', () {
      final grouped = groupedActionsFor(SimcruxActionSurface.menu, loaded);
      for (final entry in grouped.entries) {
        for (final action in entry.value) {
          expect(action.category, entry.key);
        }
      }
    });

    test('includes disabled actions — the menu greys them rather than '
        'making them vanish', () {
      const empty = SimcruxActionContext();
      final menu = groupedActionsFor(
        SimcruxActionSurface.menu,
        empty,
      ).values.expand((x) => x);
      expect(menu, contains(SimcruxAction.runRegression));
      expect(isActionEnabled(SimcruxAction.runRegression, empty), isFalse);
    });
  });
}
