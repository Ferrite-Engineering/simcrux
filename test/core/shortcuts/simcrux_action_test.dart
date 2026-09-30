// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_license/crux_license.dart';
import 'package:crux_shortcut_action/crux_shortcut_action.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/shortcuts/action_tier_label.dart';
import 'package:simcrux/core/shortcuts/simcrux_action.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/l10n/generated/app_localizations_en.dart';
import 'package:simcrux/l10n/generated/app_localizations_ja.dart';
import 'package:simcrux/l10n/generated/app_localizations_ko.dart';
import 'package:simcrux/l10n/generated/app_localizations_zh.dart';

/// The complete set of Pro-tier actions. Kept here as the test's own
/// declaration so a mis-classified tier (a Pro action flipped to open-core,
/// or vice versa) fails this test even though the exhaustive switch compiles.
/// The exhaustive `switch` in `SimcruxAction.requiredTier` (no `default`) is
/// the *compile-time* guard: a brand-new action can't ship without a tier.
const _proActions = <SimcruxAction>{
  SimcruxAction.openSeedFailureHeatmap,
  SimcruxAction.showTrendChart,
  SimcruxAction.showSuiteTrendChart,
  SimcruxAction.showCalendarHeatmap,
  SimcruxAction.showFlakyTests,
  SimcruxAction.configureRetentionPolicy,
  SimcruxAction.dispatchPrAnnotations,
  SimcruxAction.configurePrAnnotationTarget,
  // Multi-project registry semantics. `NoopProjectRegistry` holds one
  // project, clears recents, and pins nothing, so none of these can do
  // their advertised job in an open-core build. `closeAllTabs` is the
  // open-core capability that stands in for the tab-closing half of
  // `closeAllProjects` and is deliberately absent from this set.
  SimcruxAction.switchProject,
  SimcruxAction.reopenRecentProject,
  SimcruxAction.closeAllProjects,
  SimcruxAction.pinActiveProject,
  SimcruxAction.searchAcrossProjects,
  SimcruxAction.openPluginManager,
  SimcruxAction.reloadPlugins,
};

void main() {
  group('SimcruxAction implements CruxAction', () {
    test('id is namespaced with simcrux.', () {
      for (final action in SimcruxAction.values) {
        expect(action.id, startsWith('simcrux.'));
        expect(action.id, equals('simcrux.${action.name}'));
      }
    });

    test('every action maps to a category', () {
      for (final action in SimcruxAction.values) {
        expect(action.category, isA<ActionCategory>());
      }
    });

    test('action categories cover the standard set', () {
      final categories = SimcruxAction.values.map((a) => a.category).toSet();
      expect(
        categories,
        containsAll(<ActionCategory>[
          ActionCategory.file,
          ActionCategory.view,
          ActionCategory.search,
          ActionCategory.tools,
          ActionCategory.help,
        ]),
      );
    });

    test('nothing claims ActionCategory.navigate', () {
      // `ActionCategory` is the shared cross-suite enum, so `navigate` stays
      // in it for the products that use it. SimCrux has no Navigate action
      // and renders no Navigate menu: the only two that ever claimed the
      // category were unimplemented focus stubs, and keyboard navigation here
      // is F6 / Shift+F6 region traversal, owned by the focus system rather
      // than by a dispatchable action. If an action lands in this category,
      // `menu_layout.dart` needs a Navigate section to put it in.
      expect(
        SimcruxAction.values.where(
          (a) => a.category == ActionCategory.navigate,
        ),
        isEmpty,
      );
    });
  });

  group('SimcruxActionLabel.label', () {
    test('every action has a non-empty label in English', () {
      final l10n = L10NEn();
      for (final action in SimcruxAction.values) {
        final label = action.label(l10n);
        expect(
          label,
          isNotEmpty,
          reason: 'Missing English label for ${action.id}',
        );
      }
    });

    test('every action has a non-empty label in CJK locales', () {
      final locales = <L10N>[
        L10NZh(),
        L10NJa(),
        L10NKo(),
      ];
      for (final l10n in locales) {
        for (final action in SimcruxAction.values) {
          expect(
            action.label(l10n),
            isNotEmpty,
            reason: 'Missing ${l10n.localeName} label for ${action.id}',
          );
        }
      }
    });

    test('English label is distinct from action id', () {
      final l10n = L10NEn();
      for (final action in SimcruxAction.values) {
        expect(action.label(l10n), isNot(equals(action.id)));
      }
    });
  });

  group('SimcruxActionIntent', () {
    test('wraps and re-exposes the action', () {
      const intent = SimcruxActionIntent(SimcruxAction.openProject);
      expect(intent.action, equals(SimcruxAction.openProject));
      expect(intent, isA<Intent>());
    });
  });

  group('SimcruxAction.requiredTier', () {
    test('every action declares a tier', () {
      for (final action in SimcruxAction.values) {
        expect(action.requiredTier, isA<LicenseTier>());
      }
    });

    test('the declared Pro actions require LicenseTier.pro', () {
      for (final action in _proActions) {
        expect(action.requiredTier, LicenseTier.pro, reason: action.id);
      }
    });

    test('every other action is open-core (no tier badge)', () {
      for (final action in SimcruxAction.values) {
        if (_proActions.contains(action)) continue;
        expect(action.requiredTier, LicenseTier.openCore, reason: action.id);
      }
    });

    test('the actions above open-core are exactly the declared Pro set '
        '(a flipped tier fails here even though the switch compiles)', () {
      final aboveOpenCore = SimcruxAction.values
          .where((a) => a.requiredTier != LicenseTier.openCore)
          .toSet();
      expect(aboveOpenCore, _proActions);
    });

    test('no action requires the edu tier directly (gate on pro instead)', () {
      // Gating a feature on LicenseTier.edu is meaningless — EDU is
      // feature-equivalent to Pro. Guards against an accidental edu mapping.
      for (final action in SimcruxAction.values) {
        expect(action.requiredTier, isNot(LicenseTier.edu), reason: action.id);
      }
    });
  });

  group('tierLabelSuffix', () {
    test('pro → localized parenthetical PRO suffix', () {
      expect(tierLabelSuffix(LicenseTier.pro, L10NEn()), ' (PRO)');
    });

    test('enterprise → localized parenthetical ENT suffix', () {
      expect(tierLabelSuffix(LicenseTier.enterprise, L10NEn()), ' (ENT)');
    });

    test('openCore and edu → empty (no upgrade marker)', () {
      final l10n = L10NEn();
      expect(tierLabelSuffix(LicenseTier.openCore, l10n), isEmpty);
      expect(tierLabelSuffix(LicenseTier.edu, l10n), isEmpty);
    });

    test('pro suffix is non-empty and contains the badge text in every '
        'CJK locale', () {
      for (final l10n in <L10N>[L10NZh(), L10NJa(), L10NKo()]) {
        final suffix = tierLabelSuffix(LicenseTier.pro, l10n);
        expect(suffix, isNotEmpty, reason: l10n.localeName);
        expect(suffix, contains(l10n.tierBadgePro), reason: l10n.localeName);
      }
    });
  });
}
