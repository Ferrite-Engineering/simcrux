// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_workspace/crux_workspace.dart';
import 'package:flutter/foundation.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// SimCrux's [ViewerTabBarStrings] implementation, delegating to the
/// ARB-generated [L10N] instance.
///
/// Constructed once per build via `L10N.of(context)`; passed to
/// `PaneHost.strings` (which forwards to each pane's `ViewerTabBar`).
/// The package's `ViewerTabBarStringsEn` default is replaced so users
/// running zh-CN / zh / ja / ko see the localized labels.
class SimcruxViewerTabBarStrings extends ViewerTabBarStrings {
  /// Creates a strings adapter that delegates to the supplied [l10n].
  const SimcruxViewerTabBarStrings(this._l10n);

  final L10N _l10n;

  @override
  String get revealTabMenuItem {
    if (defaultTargetPlatform == TargetPlatform.windows) {
      return _l10n.tabContextMenuRevealInExplorer;
    }
    if (defaultTargetPlatform == TargetPlatform.linux) {
      return _l10n.tabContextMenuRevealInFiles;
    }
    return _l10n.tabContextMenuRevealInFinder;
  }

  @override
  String get closeTabTooltip => _l10n.viewerTabBarCloseTabTooltip;

  // Names the tab: with several tabs open, a screen reader otherwise hears
  // one "Close tab" button per chip and cannot tell which tab each closes.
  @override
  String closeTabTooltipFor(String name) => _l10n.tabChipCloseTooltip(name);

  @override
  String get newTabTooltip => _l10n.viewerTabBarNewTabTooltip;

  @override
  String get newTabDefaultDisplayName =>
      _l10n.viewerTabBarNewTabDefaultDisplayName;

  @override
  String get unnamedTabFallback => _l10n.viewerTabBarUnnamedTabFallback;

  @override
  String get closeTabMenuItem => _l10n.viewerTabBarCloseTabMenuItem;

  @override
  String get closeOtherTabsMenuItem => _l10n.viewerTabBarCloseOtherTabsMenuItem;

  @override
  String get closeTabsToTheRightMenuItem =>
      _l10n.viewerTabBarCloseTabsToTheRightMenuItem;

  @override
  String get moveToNewWindowMenuItem =>
      _l10n.viewerTabBarMoveToNewWindowMenuItem;

  @override
  String get multiWindowUnavailableTooltip =>
      _l10n.viewerTabBarMultiWindowUnavailableTooltip;

  @override
  String get activePaneAccessibilityLabel =>
      _l10n.viewerTabBarActivePaneAccessibilityLabel;

  @override
  String get dragToPaneAccessibilityHint =>
      _l10n.viewerTabBarDragToPaneAccessibilityHint;

  @override
  String get reorderHandleTooltip => _l10n.viewerTabBarReorderHandleTooltip;

  // The two scroll chevrons. These carry English defaults on the interface,
  // because they were added after four products had already subclassed it —
  // which means forgetting to override them is silent, and ships English to
  // the four non-English locales rather than failing to compile.
  @override
  String get scrollTabsLeftTooltip => _l10n.viewerTabBarScrollTabsLeftTooltip;

  @override
  String get scrollTabsRightTooltip => _l10n.viewerTabBarScrollTabsRightTooltip;
}
