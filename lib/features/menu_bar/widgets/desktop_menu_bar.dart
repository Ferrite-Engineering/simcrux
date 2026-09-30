// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_license/crux_license.dart';
import 'package:crux_menu_bar/crux_menu_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/core/license/simcrux_edition_line_strings.dart';
import 'package:simcrux/core/shortcuts/action_category.dart';
import 'package:simcrux/core/shortcuts/action_tier_label.dart';
import 'package:simcrux/core/shortcuts/menu_layout.dart';
import 'package:simcrux/core/shortcuts/shortcut_bindings_provider.dart';
import 'package:simcrux/core/shortcuts/simcrux_action.dart';
import 'package:simcrux/core/shortcuts/simcrux_action_descriptor.dart';
import 'package:simcrux/core/shortcuts/simcrux_action_descriptors.dart';
import 'package:simcrux/features/workspace/providers/simcrux_action_context_provider.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/shared/widgets/simcrux_icon_image.dart';

/// SimCrux's binding of the shared [CruxDesktopMenuBar] to its own action
/// catalog.
///
/// Everything structural — the two renderers (native macOS [PlatformMenuBar]
/// vs. the in-window VS Code-style menu bar on Windows/Linux), separator
/// grouping, the platform-idiomatic placement of About / Check for Updates /
/// Settings / Quit, the standard macOS application-menu tail and Window menu,
/// and the guard that keeps typing-hostile accelerators out of native key
/// equivalents — lives in `crux_menu_bar`. This widget supplies only what is
/// SimCrux's own: [kMenuLayout] for order and grouping, the descriptor table
/// for membership and enablement, and the localized labels.
///
/// Enablement is new here. Every item used to be live regardless of state, so
/// Run Regression and Cancel Regression were permanently lit side by side —
/// a user could not tell from the UI whether a regression was running.
class DesktopMenuBar extends ConsumerWidget {
  /// Creates the SimCrux desktop menu bar.
  const DesktopMenuBar({
    required this.onAction,
    required this.child,
    super.key,
  });

  /// Called when the user selects a menu item.
  final void Function(SimcruxAction) onAction;

  /// The widget tree below the menu bar.
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10N.of(context);
    final ctx = ref.watch(simcruxActionContextProvider);
    final bindings = ref.watch(shortcutBindingsProvider);
    final isMacOS = Theme.of(context).platform == TargetPlatform.macOS;

    return CruxDesktopMenuBar<SimcruxAction>(
      layout: kMenuLayout,
      appActions: kAppMenuActions,
      categoryLabel: (category) => category.label(l10n),
      categoryAcceleratorLabel: (category) => category.acceleratorLabel(l10n),
      windowMenuLabel: l10n.menuWindow,
      labelOf: (action) =>
          _label(action, l10n, isMacOS: isMacOS) +
          tierLabelSuffix(action.requiredTier, l10n),
      shortcutOf: (action) => bindings[action],
      isVisible: (action) =>
          isActionVisibleIn(action, SimcruxActionSurface.menu, ctx),
      isEnabled: (action) => isActionEnabled(action, ctx),
      onAction: onAction,
      // States the edition in force, disabled, above `About SimCrux`.
      // Null at Open Core, so this is safe to pass unconditionally: the
      // Pro overlay supplies the licence status that gives it a value.
      editionLine: cruxLicenseEditionLine(
        ref.watch(licenseStatusProvider),
        SimCruxEditionLineStrings(l10n),
      ),
      logo: const SimcruxIconImage(size: 18),
      child: child,
    );
  }

  /// The action's localized label, with the one platform-dependent override.
  ///
  /// Quit reads "Quit SimCrux" in the macOS application menu and "Exit" at the
  /// bottom of the Windows/Linux File menu — the native wording on each, and
  /// what VS Code does.
  static String _label(
    SimcruxAction action,
    L10N l10n, {
    required bool isMacOS,
  }) => action == SimcruxAction.quit && !isMacOS
      ? l10n.actionExit
      : action.label(l10n);
}
