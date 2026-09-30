// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Reachability contract for three actions whose machinery is easy to build
// and leave unreachable.
//
// Each has working machinery behind it and, without a surface, no way for a
// user to get there: `exportResults` is the only GUI door onto four
// exporters and nine translated ARB keys, and the PR-annotation pair is
// easy to hide behind an empty surface set under a stale deferral comment.
//
// The assertions below are deliberately about *discoverability*, not about
// what the handlers do — the handler behaviour has its own suites. A surface
// set is one line, it is silent when wrong, and it is exactly what regressed.

import 'package:crux_license/crux_license.dart';
import 'package:crux_menu_bar/crux_menu_bar.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/shortcuts/action_category.dart';
import 'package:simcrux/core/shortcuts/menu_layout.dart';
import 'package:simcrux/core/shortcuts/simcrux_action.dart';
import 'package:simcrux/core/shortcuts/simcrux_action_context.dart';
import 'package:simcrux/core/shortcuts/simcrux_action_descriptor.dart';
import 'package:simcrux/core/shortcuts/simcrux_action_descriptors.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// The three result-consuming actions surfaced on 2026-08-17.
const _surfacedActions = <SimcruxAction>[
  SimcruxAction.exportResults,
  SimcruxAction.dispatchPrAnnotations,
  SimcruxAction.configurePrAnnotationTarget,
];

/// A context with a project, a config and results — the state in which all
/// three are meant to be usable.
const _withResults = SimcruxActionContext(
  hasOpenTab: true,
  hasConfig: true,
  hasResults: true,
);

void main() {
  group('result-consuming actions are reachable', () {
    test('every one declares at least one surface', () {
      for (final action in _surfacedActions) {
        expect(
          descriptorFor(action).surfaces,
          isNotEmpty,
          reason:
              '${action.id} declares no surface, so no user can reach it '
              'however complete its implementation is: built machinery with '
              'no way in.',
        );
      }
    });

    test('every one is visible in the menu and listed in the palette', () {
      for (final action in _surfacedActions) {
        expect(
          isActionVisibleIn(action, SimcruxActionSurface.menu, _withResults),
          isTrue,
          reason: '${action.id} must be menu-reachable',
        );
        expect(
          paletteActionsFor(_withResults),
          contains(action),
          reason: '${action.id} must be listed in the command palette',
        );
      }
    });

    test('every one has a home in the Tools menu layout', () {
      // The menu-layout drift guard already checks this both ways for the
      // whole table; asserting it here too makes the failure name the
      // feature rather than the invariant.
      final placed = cruxMenuLayoutActions(kMenuLayout);
      for (final action in _surfacedActions) {
        expect(action.category, ActionCategory.tools);
        expect(placed, contains(action));
      }
    });

    test('none is offered before there is a run to consume', () {
      // Enablement, not visibility: the menu keeps them greyed rather than
      // hiding them, so the capability stays discoverable on a cold start.
      const cold = SimcruxActionContext(hasOpenTab: true, hasConfig: true);
      for (final action in _surfacedActions.where(
        (a) => a != SimcruxAction.configurePrAnnotationTarget,
      )) {
        expect(
          isActionEnabled(action, cold),
          isFalse,
          reason: '${action.id} needs results',
        );
      }
      // Configuring a target is the one that must work *before* a run —
      // it is how a user gets a target in the first place.
      expect(
        isActionEnabled(SimcruxAction.configurePrAnnotationTarget, cold),
        isTrue,
      );
    });

    test('export stays open-core; the PR-annotation pair stays Pro', () {
      // Charging for the GUI door onto a capability `--export` already gives
      // away free would be a tier boundary drawn around a menu item.
      expect(SimcruxAction.exportResults.requiredTier, LicenseTier.openCore);
      expect(
        SimcruxAction.dispatchPrAnnotations.requiredTier,
        LicenseTier.pro,
      );
      expect(
        SimcruxAction.configurePrAnnotationTarget.requiredTier,
        LicenseTier.pro,
      );
    });

    test('every one has a translated label in all five locales', () async {
      final en = await L10N.delegate.load(const Locale('en'));
      for (final locale in L10N.supportedLocales) {
        final l10n = await L10N.delegate.load(locale);
        for (final action in _surfacedActions) {
          expect(
            action.label(l10n).trim(),
            isNotEmpty,
            reason: '${action.id} has no label in $locale',
          );
          if (locale.languageCode != 'en') {
            expect(
              action.label(l10n),
              isNot(action.label(en)),
              reason: '${action.id} looks untranslated in $locale',
            );
          }
        }
      }
    });
  });
}
