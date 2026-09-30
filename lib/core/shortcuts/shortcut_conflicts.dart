// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_keybindings/crux_keybindings.dart' as kb;
import 'package:flutter/widgets.dart';
import 'package:simcrux/core/shortcuts/shortcut_bindings.dart';
import 'package:simcrux/core/shortcuts/simcrux_action.dart';

/// Activator combinations more than one [SimcruxAction] is *intentionally*
/// allowed to share, so the live conflict detector doesn't flag them. SimCrux
/// has no by-design keyboard shadows today; the set exists so the wrapper has
/// the same shape as the other products if one is ever introduced.
const Set<Set<SimcruxAction>> kIntentionalShadows = {};

/// SimCrux-flavored conflict *resolution*: delegates to the cross-suite
/// `resolveShortcutConflicts`, injecting [defaultBindings], [SimcruxAction]
/// declaration order (for the deterministic tiebreak), and
/// [kIntentionalShadows].
///
/// Returns both the deterministic runtime activator map
/// ([kb.ShortcutConflictResolution.effectiveBindings] — fed to
/// `ShortcutManagerWidget` so a user-remapped binding wins its chord instead of
/// the enum-declaration-order accident) and the editor's owner/shadowed view.
kb.ShortcutConflictResolution<SimcruxAction> resolveShortcutConflicts(
  Map<SimcruxAction, ShortcutActivator> bindings,
) => kb.resolveShortcutConflicts(
  bindings,
  defaultBindings(),
  order: SimcruxAction.values,
  intentionalShadows: kIntentionalShadows,
);
