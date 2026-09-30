// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_command_palette/crux_command_palette.dart';
import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:crux_keybindings/crux_keybindings.dart'
    show formatShortcutLabel;
import 'package:crux_license/crux_license.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/core/shortcuts/shortcut_bindings_provider.dart';
import 'package:simcrux/core/shortcuts/simcrux_action.dart';
import 'package:simcrux/core/shortcuts/simcrux_action_descriptors.dart';
import 'package:simcrux/features/workspace/providers/simcrux_action_context_provider.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/shared/widgets/simcrux_feature_tier_badge.dart';

/// SimCrux-specific wrapper around the cross-suite
/// [CommandPalette]<[SimcruxAction]> widget.
///
/// Responsibilities:
/// - Pick the visible action list.
/// - Resolve action labels through simcrux's [L10N] class.
/// - Pass the active key bindings so each row can render its shortcut.
/// - Dispatch the selected action by invoking [onAction], leaving the
///   actual handler logic to the caller (typically the app-level
///   [ShortcutManagerWidget] dispatch in `lib/app.dart`).
class CommandPaletteDialog extends ConsumerWidget {
  /// Creates a simcrux command palette wrapper.
  const CommandPaletteDialog({required this.onAction, super.key});

  /// Called when the user picks an action. The dialog has already closed
  /// itself by the time this fires.
  final ValueChanged<SimcruxAction> onAction;

  /// Shows the palette as a modal dialog over [context].
  ///
  /// Re-entrancy guarded ([ModalGuard]): Cmd/Ctrl+Shift+P auto-repeat or a
  /// double-press must not stack multiple palettes. Guarded inside the
  /// opener so every caller is covered.
  static Future<void> show(
    BuildContext context, {
    required ValueChanged<SimcruxAction> onAction,
  }) {
    return ModalGuard.run(
      'commandPalette',
      () => CommandPalette.show<SimcruxAction>(
        context,
        // The descriptor table is the single source of truth for every
        // surface. `paletteActionsFor` returns visible AND enabled actions:
        // the palette has no greyed state, so a command that would be inert
        // is omitted rather than shown and silently doing nothing.
        actions: paletteActionsFor(
          ProviderScope.containerOf(
            context,
            listen: false,
          ).read(simcruxActionContextProvider),
        ),
        labelFor: (a) => a.label(L10N.of(context)),
        onAction: onAction,
        hintText: L10N.of(context).commandPaletteSearchHint,
        noResultsLabel: L10N.of(context).commandPaletteNoResults,
        bindings: _readBindings(context),
        activatorLabel: formatShortcutLabel,
        trailingBuilder: _tierBadge,
      ),
    );
  }

  /// Trailing widget for a palette row: a `SimCruxFeatureTierBadge` for any
  /// Pro/Enterprise action, or `null` (no trailing widget) for open-core
  /// actions. Tier comes from the single source of truth on the action
  /// itself ([SimcruxAction.requiredTier]) — no per-surface wiring.
  static Widget? _tierBadge(SimcruxAction action) =>
      action.requiredTier == LicenseTier.openCore
      ? null
      : SimCruxFeatureTierBadge(requiredTier: action.requiredTier);

  /// Reads the active bindings via a one-shot `ProviderScope.containerOf`
  /// lookup so [show] can be invoked from anywhere without a `WidgetRef`
  /// in hand.
  static Map<SimcruxAction, ShortcutActivator?> _readBindings(
    BuildContext context,
  ) {
    final container = ProviderScope.containerOf(context, listen: false);
    return container.read(shortcutBindingsProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10N.of(context);
    final bindings = ref.watch(shortcutBindingsProvider);
    return CommandPalette<SimcruxAction>(
      actions: paletteActionsFor(ref.watch(simcruxActionContextProvider)),
      labelFor: (a) => a.label(l10n),
      onAction: onAction,
      hintText: l10n.commandPaletteSearchHint,
      noResultsLabel: l10n.commandPaletteNoResults,
      bindings: bindings,
      activatorLabel: formatShortcutLabel,
      trailingBuilder: _tierBadge,
    );
  }
}
