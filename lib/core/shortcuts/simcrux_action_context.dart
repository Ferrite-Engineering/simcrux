// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';

/// The state snapshot every action-discovery surface gates on.
///
/// Menu bar, command palette, toolbar, and the keyboard dispatch path all read
/// one of these, so a command greys out identically wherever the user meets
/// it. Before this type SimCrux had **no** enablement: every menu item and
/// toolbar button was live regardless of state, so Run Regression and Cancel
/// Regression were permanently lit side by side and "Re-run Selected Test" was
/// clickable with nothing selected.
@immutable
class SimcruxActionContext {
  /// Creates a context snapshot. Defaults describe a cold start: no tab, no
  /// config, nothing running, single pane.
  const SimcruxActionContext({
    this.hasOpenTab = false,
    this.hasConfig = false,
    this.runInProgress = false,
    this.hasResults = false,
    this.hasSelectedTest = false,
    this.diagnosticsEnabled = true,
    this.paneCount = 1,
    this.tabCountInActivePane = 0,
  });

  /// Whether the workspace has an active tab. Gates everything that reads or
  /// mutates per-tab state — without a tab those handlers resolve the empty
  /// root scope and no-op.
  final bool hasOpenTab;

  /// Whether the active tab has a loaded regression config. Gates the run
  /// commands and every analysis surface, all of which operate on one.
  final bool hasConfig;

  /// Whether a regression is currently executing in the active tab. Gates
  /// Cancel *on* and the run commands *off*, so the two are never lit at
  /// once — the ambiguity the old always-enabled pair created.
  final bool runInProgress;

  /// Whether the active tab holds at least one result row. Gates the trend,
  /// heatmap, flaky-test and PR-annotation surfaces: all of them summarize
  /// results, and with none they render an empty shell.
  final bool hasResults;

  /// Whether a test row is selected in the active tab. Gates Re-run Selected
  /// Test, which has nothing to re-run without one.
  final bool hasSelectedTest;

  /// Whether the diagnostics surfaces are enabled
  /// (`diagnosticsEnabledProvider`: always in debug/profile, opt-in via
  /// Settings in release). Gates the Tab Diagnostics drawer, mirroring
  /// WaveCrux's `ActionRequirement.diagnosticsEnabled`. Defaults to `true`
  /// so a literal test context matches the debug-build behavior.
  final bool diagnosticsEnabled;

  /// How many panes the workspace has. Gates the pane commands.
  final int paneCount;

  /// How many tabs the active pane holds. Gates Next / Previous Tab.
  final int tabCountInActivePane;

  @override
  bool operator ==(Object other) =>
      other is SimcruxActionContext &&
      other.hasOpenTab == hasOpenTab &&
      other.hasConfig == hasConfig &&
      other.runInProgress == runInProgress &&
      other.hasResults == hasResults &&
      other.hasSelectedTest == hasSelectedTest &&
      other.diagnosticsEnabled == diagnosticsEnabled &&
      other.paneCount == paneCount &&
      other.tabCountInActivePane == tabCountInActivePane;

  @override
  int get hashCode => Object.hash(
    hasOpenTab,
    hasConfig,
    runInProgress,
    hasResults,
    hasSelectedTest,
    diagnosticsEnabled,
    paneCount,
    tabCountInActivePane,
  );
}
