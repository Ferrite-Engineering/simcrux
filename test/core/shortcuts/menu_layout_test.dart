// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_menu_bar/crux_menu_bar.dart';
import 'package:crux_shortcut_action/crux_shortcut_action.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/shortcuts/menu_layout.dart';
import 'package:simcrux/core/shortcuts/simcrux_action.dart';
import 'package:simcrux/core/shortcuts/simcrux_action_context.dart';
import 'package:simcrux/core/shortcuts/simcrux_action_descriptor.dart';
import 'package:simcrux/core/shortcuts/simcrux_action_descriptors.dart';

void main() {
  group('kMenuLayout', () {
    test('covers exactly the menu-visible action set', () {
      final placed = <SimcruxAction>{
        ...cruxMenuLayoutActions(kMenuLayout),
        ...kAppMenuActions.desktopFolded,
      };
      final menuVisible = SimcruxAction.values
          .where(
            (a) =>
                descriptorFor(a).surfaces.contains(SimcruxActionSurface.menu),
          )
          .toSet();
      expect(
        placed,
        equals(menuVisible),
        reason:
            'A menu-visible action is missing from kMenuLayout (or the table '
            'places an action that is no longer menu-visible). Give it a home '
            'in the appropriate category group in menu_layout.dart.',
      );
    });

    test('places no action more than once', () {
      final seen = <SimcruxAction>{};
      for (final groups in kMenuLayout.values) {
        for (final group in groups) {
          for (final action in group) {
            expect(
              seen.add(action),
              isTrue,
              reason: '$action appears more than once in kMenuLayout',
            );
          }
        }
      }
    });

    test('does not place the app-folded actions (Settings / Quit)', () {
      final placed = cruxMenuLayoutActions(kMenuLayout);
      for (final action in kAppMenuActions.desktopFolded) {
        expect(placed, isNot(contains(action)));
      }
      expect(placed, contains(kAppMenuActions.about));
      expect(placed, contains(kAppMenuActions.checkForUpdates));
    });

    test('places each action in the category its own mapping declares', () {
      kMenuLayout.forEach((category, groups) {
        for (final group in groups) {
          for (final action in group) {
            expect(
              action.category,
              category,
              reason:
                  '$action is placed under $category but its category is '
                  '${action.category}',
            );
          }
        }
      });
    });

    test('leads View with the command palette and Help with Documentation', () {
      expect(kMenuLayout[ActionCategory.view]!.first, [
        SimcruxAction.openCommandPalette,
      ]);
      expect(kMenuLayout[ActionCategory.help]!.first, [
        SimcruxAction.openDocumentation,
      ]);
      expect(kMenuLayout[ActionCategory.help]!.last, [SimcruxAction.openAbout]);
    });

    test('leads Tools with the run commands, and File holds none of them', () {
      // Running a regression is a Tools verb. These three used to sit at the
      // top of the File menu, right under Open Config….
      expect(kMenuLayout[ActionCategory.tools]!.first, [
        SimcruxAction.runRegression,
        SimcruxAction.reRunSelected,
        SimcruxAction.cancelRegression,
      ]);
      final file = kMenuLayout[ActionCategory.file]!.expand((g) => g);
      expect(file, isNot(contains(SimcruxAction.runRegression)));
      expect(file, isNot(contains(SimcruxAction.reRunSelected)));
      expect(file, isNot(contains(SimcruxAction.cancelRegression)));
    });

    test('declares no Edit menu — SimCrux has no editing actions', () {
      expect(kMenuLayout.containsKey(ActionCategory.edit), isFalse);
    });
  });

  group('enablement', () {
    test('Run and Cancel are never both enabled', () {
      // The old toolbar and menu lit both permanently, so the UI never told
      // the user whether a regression was in flight.
      const idle = SimcruxActionContextFixtures.idle;
      const running = SimcruxActionContextFixtures.running;
      for (final ctx in [idle, running, const SimcruxActionContext()]) {
        expect(
          isActionEnabled(SimcruxAction.runRegression, ctx) &&
              isActionEnabled(SimcruxAction.cancelRegression, ctx),
          isFalse,
          reason: 'Run and Cancel must never be simultaneously live',
        );
      }
      expect(isActionEnabled(SimcruxAction.runRegression, idle), isTrue);
      expect(isActionEnabled(SimcruxAction.cancelRegression, idle), isFalse);
      expect(isActionEnabled(SimcruxAction.runRegression, running), isFalse);
      expect(isActionEnabled(SimcruxAction.cancelRegression, running), isTrue);
    });

    test('Re-run Selected needs a selection and an idle runner', () {
      expect(
        isActionEnabled(
          SimcruxAction.reRunSelected,
          SimcruxActionContextFixtures.idle,
        ),
        isFalse,
        reason: 'nothing is selected',
      );
      expect(
        isActionEnabled(
          SimcruxAction.reRunSelected,
          const SimcruxActionContext(
            hasOpenTab: true,
            hasConfig: true,
            hasSelectedTest: true,
          ),
        ),
        isTrue,
      );
    });

    test('the menu keeps disabled actions; the palette drops them', () {
      const empty = SimcruxActionContext();
      final menu = groupedActionsFor(
        SimcruxActionSurface.menu,
        empty,
      ).values.expand((x) => x);
      expect(menu, contains(SimcruxAction.runRegression));
      expect(
        paletteActionsFor(empty),
        isNot(contains(SimcruxAction.runRegression)),
      );
    });
  });
}

/// Shared contexts for the enablement assertions.
abstract final class SimcruxActionContextFixtures {
  /// A config is loaded and no regression is running.
  static const idle = SimcruxActionContext(hasOpenTab: true, hasConfig: true);

  /// A regression is in flight.
  static const running = SimcruxActionContext(
    hasOpenTab: true,
    hasConfig: true,
    runInProgress: true,
  );
}
