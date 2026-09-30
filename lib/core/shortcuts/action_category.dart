// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_shortcut_action/crux_shortcut_action.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

// Re-export ActionCategory so existing consumer imports of
// `package:simcrux/core/shortcuts/action_category.dart` continue to work
// after the enum moved to crux_shortcut_action. New code may equally
// well import the cross-suite package directly.
export 'package:crux_shortcut_action/crux_shortcut_action.dart'
    show ActionCategory;

/// Localized display name for each [ActionCategory].
///
/// The [ActionCategory] enum itself lives in `package:crux_shortcut_action`
/// so it can be shared across the suite; the SimCrux-specific localized
/// labels live here because they reference SimCrux's `L10N` class. Each
/// Crux product writes a parallel extension against its own L10N.
extension ActionCategoryLabel on ActionCategory {
  /// Returns the localized human-readable name for this category.
  String label(L10N l10n) => switch (this) {
    ActionCategory.app => l10n.actionCategoryApp,
    ActionCategory.file => l10n.actionCategoryFile,
    ActionCategory.edit => l10n.actionCategoryEdit,
    ActionCategory.view => l10n.actionCategoryView,
    ActionCategory.navigate => l10n.actionCategoryNavigate,
    ActionCategory.search => l10n.actionCategorySearch,
    ActionCategory.tools => l10n.actionCategoryTools,
    ActionCategory.help => l10n.actionCategoryHelp,
  };

  /// The localized top-level menu title with an Alt-accelerator mnemonic
  /// marker (`&`), for the Windows/Linux in-window `MnemonicMenuBar`. The `&`
  /// precedes the underlined accelerator key (e.g. `&File` → Alt+F).
  ///
  /// Each mnemonic is its own translated string rather than `'&' + label`.
  /// The computed form works only in Latin scripts: in Japanese it produced
  /// `&ファイル`, making the accelerator `フ` — a kana no physical keyboard
  /// emits, so Alt-navigation was unreachable in ja / ko / zh. The
  /// translations use the platform convention of appending the Latin key in
  /// parentheses, e.g. `ファイル(&F)`.
  ///
  /// The [app] category is never a top-level menu (macOS hoists it into the
  /// application menu, Windows/Linux fold it into File), so it keeps its
  /// plain [label].
  String acceleratorLabel(L10N l10n) => switch (this) {
    ActionCategory.app => l10n.actionCategoryApp,
    ActionCategory.file => l10n.actionCategoryFileMnemonic,
    ActionCategory.edit => l10n.actionCategoryEditMnemonic,
    ActionCategory.view => l10n.actionCategoryViewMnemonic,
    ActionCategory.navigate => l10n.actionCategoryNavigateMnemonic,
    ActionCategory.search => l10n.actionCategorySearchMnemonic,
    ActionCategory.tools => l10n.actionCategoryToolsMnemonic,
    ActionCategory.help => l10n.actionCategoryHelpMnemonic,
  };
}

// Per-surface action visibility lives in the descriptor table
// (`simcrux_action_descriptors.dart`) — the single source of truth every
// surface consumes via `groupedActionsFor` / `paletteActionsFor` /
// `isActionEnabled`, exactly as NetCrux and WaveCrux do.
//
// The `kMenuHiddenActions` / `kPaletteHiddenActions` / `menuVisibleActions` /
// `paletteVisibleActions` / `groupedActions` helpers that used to live here
// were removed in the suite menu-consistency pass. They encoded visibility as
// "everything, minus a hand-maintained deny-set", which could express no
// enablement at all — which is why every SimCrux menu item and toolbar button
// was live regardless of state, Run and Cancel included.
