// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_license/crux_license.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/shortcuts/action_category.dart';
import 'package:simcrux/core/shortcuts/action_tier_label.dart';
import 'package:simcrux/core/shortcuts/simcrux_action.dart';
import 'package:simcrux/core/shortcuts/simcrux_action_context.dart';
import 'package:simcrux/core/shortcuts/simcrux_action_descriptor.dart';
import 'package:simcrux/core/shortcuts/simcrux_action_descriptors.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// The two beta-release-infrastructure actions and their tier /
/// discoverability contract.
///
/// The tier assertions are the load-bearing half: `SimcruxAction.requiredTier`
/// is the single source of truth every action surface reads, so a
/// misclassified action would put a PRO badge on a free support channel (and,
/// post-beta, gate it behind a licence).
const _betaInfraActions = <SimcruxAction>[
  SimcruxAction.checkForUpdates,
  SimcruxAction.submitIssue,
];

const _locales = [
  Locale('en'),
  Locale('zh', 'CN'),
  Locale('ja'),
  Locale('ko'),
];

void main() {
  group('beta-release infrastructure actions', () {
    test('are open-core in every tier — no badge, no gate', () {
      for (final action in _betaInfraActions) {
        expect(
          action.requiredTier,
          LicenseTier.openCore,
          reason:
              '${action.id} must stay free: an update check and a bug-report '
              'channel are not paid features',
        );
      }
    });

    test('render no tier suffix on the native menu bar', () async {
      final l10n = await L10N.delegate.load(const Locale('en'));
      for (final action in _betaInfraActions) {
        expect(
          tierLabelSuffix(action.requiredTier, l10n),
          isEmpty,
          reason: '${action.id} must not carry a "(PRO)" suffix',
        );
      }
    });

    test('live in the Help category', () {
      for (final action in _betaInfraActions) {
        expect(action.category, ActionCategory.help);
      }
    });

    test('appear in the browsable menu inventory', () {
      for (final action in _betaInfraActions) {
        expect(
          isActionVisibleIn(action, SimcruxActionSurface.menu, _anyContext),
          isTrue,
          reason: '${action.name} must stay menu-reachable',
        );
      }
    });

    test('appear in the command palette', () {
      // Both are workspace-independent, so they are listed even on a cold
      // start — a user with nothing open can still report a bug or check
      // for an update.
      for (final action in _betaInfraActions) {
        expect(
          paletteActionsFor(const SimcruxActionContext()),
          contains(action),
        );
      }
    });

    test('are grouped under Help in the menu-bar grouping', () {
      final help =
          groupedActionsFor(
            SimcruxActionSurface.menu,
            _anyContext,
          )[ActionCategory.help] ??
          const [];
      for (final action in _betaInfraActions) {
        expect(help, contains(action));
      }
    });

    test('carry a namespaced, stable action id', () {
      expect(SimcruxAction.checkForUpdates.id, 'simcrux.checkForUpdates');
      expect(SimcruxAction.submitIssue.id, 'simcrux.submitIssue');
    });

    test('have a non-empty localized label in every shipped locale', () async {
      for (final locale in _locales) {
        final l10n = await L10N.delegate.load(locale);
        for (final action in _betaInfraActions) {
          expect(
            action.label(l10n).trim(),
            isNotEmpty,
            reason: '${action.id} has no label in $locale',
          );
        }
      }
    });

    test('labels are translated, not English copies', () async {
      final en = await L10N.delegate.load(const Locale('en'));
      for (final locale in _locales.skip(1)) {
        final l10n = await L10N.delegate.load(locale);
        for (final action in _betaInfraActions) {
          expect(
            action.label(l10n),
            isNot(action.label(en)),
            reason: '${action.id} looks untranslated in $locale',
          );
        }
      }
    });

    test('labels use the U+2026 ellipsis, per house style', () async {
      final l10n = await L10N.delegate.load(const Locale('en'));
      for (final action in _betaInfraActions) {
        expect(action.label(l10n), isNot(contains('...')));
      }
    });
  });
}

/// Neither beta action is gated on workspace state, so any context serves.
const _anyContext = SimcruxActionContext();
