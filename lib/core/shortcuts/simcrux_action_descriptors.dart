// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:simcrux/core/shortcuts/action_category.dart';
import 'package:simcrux/core/shortcuts/simcrux_action.dart';
import 'package:simcrux/core/shortcuts/simcrux_action_context.dart';
import 'package:simcrux/core/shortcuts/simcrux_action_descriptor.dart';

/// The single source of truth for where every [SimcruxAction] appears and
/// when it is enabled.
///
/// ## IMPORTANT — adding a new action
///
/// This is an **exhaustive `switch`**. Adding a value to [SimcruxAction] fails
/// to compile until a case lands here, which is the guardrail keeping every
/// new action wired into the single source of truth.
SimcruxActionDescriptor descriptorFor(SimcruxAction action) => switch (action) {
  // ── Always available, workspace-independent ───────────────────────
  // Opening a config creates its own tab; the app-level commands never
  // depend on workspace state.
  // On the toolbar too: Open leads the canonical common block, Settings
  // closes it, and Import FuseSoC is SimCrux's own file chrome.
  SimcruxAction.openProject ||
  SimcruxAction.importFusesoc ||
  SimcruxAction.openSettings => const SimcruxActionDescriptor(
    surfaces: _everywhere,
  ),

  // ── The two RISC-V imports — menu + palette, never the toolbar ────
  // Same always-available shape as Import FuseSoC (an import creates its
  // own tab and depends on no workspace state), but off the toolbar: the
  // canonical common toolbar block is Open / Import / Run / Cancel / Close
  // / Search / Settings in every suite product, and a third import button
  // would push it past that shared shape for a command a user runs once
  // per checkout rather than once per session.
  SimcruxAction.importRiscvArchTest ||
  SimcruxAction.importRiscvFormal ||
  SimcruxAction.reopenRecentProject ||
  SimcruxAction.openAppDiagnostics ||
  SimcruxAction.openAbout ||
  SimcruxAction.openDocumentation ||
  SimcruxAction.checkForUpdates ||
  SimcruxAction.submitIssue ||
  SimcruxAction.openPluginManager ||
  SimcruxAction.reloadPlugins ||
  SimcruxAction.quit => const SimcruxActionDescriptor(
    surfaces: _menuPalette,
  ),

  // ── Command palette opener — menu only ────────────────────────────
  // Self-referential inside the palette, but it MUST stay reachable from
  // the menu, or unbinding its shortcut would make the palette
  // permanently inaccessible with no recovery path.
  SimcruxAction.openCommandPalette => const SimcruxActionDescriptor(
    surfaces: _menuOnly,
  ),

  // ── Cross-probe panel — always openable ───────────────────────────
  // The panel is the peer-discovery status surface, so it stays openable
  // at zero peers: hiding it would hide the only place that explains why
  // no peers are connected.
  SimcruxAction.openCrossProbePanel => const SimcruxActionDescriptor(
    surfaces: _everywhere,
  ),

  // ── Needs an open tab ─────────────────────────────────────────────
  // Close and Search complete the canonical common toolbar block.
  SimcruxAction.closeProject ||
  SimcruxAction.openSearch => const SimcruxActionDescriptor(
    surfaces: _everywhere,
    isEnabled: _requiresTab,
  ),

  // closeTab (Cmd/Ctrl+W, suite keyboard-parity pass) is menu + palette
  // only: the canonical common toolbar block's close slot stays with
  // closeProject above, mirroring WaveCrux where closeTab is likewise
  // not a toolbar action.
  SimcruxAction.closeTab ||
  SimcruxAction.closeAllTabs ||
  SimcruxAction.closeAllProjects ||
  SimcruxAction.pinActiveProject ||
  SimcruxAction.toggleTestBrowser ||
  SimcruxAction.toggleInspector ||
  SimcruxAction.toggleLogPanel => const SimcruxActionDescriptor(
    surfaces: _menuPalette,
    isEnabled: _requiresTab,
  ),

  // There is deliberately no surfaceless entry here. The two focus stubs
  // that used to occupy one were removed rather than left hidden: hiding a
  // stub from the menu and palette does not unbind its chord, so
  // `Cmd/Ctrl+Shift+1`/`+2` went on firing a "not yet implemented" notice
  // for an action nothing else in the UI admitted existed. A descriptor
  // with an empty `surfaces` set is for an action reachable some other
  // real way, not for one that does nothing.

  // ── Tab Diagnostics — needs a tab, gated on diagnostics opt-in ────
  // WaveCrux parity: the drawer opens for the active tab and honors the
  // diagnostics-enabled setting (always on in debug/profile, Settings
  // opt-in in release), mirroring WaveCrux's
  // `ActionRequirement.diagnosticsEnabled`.
  SimcruxAction.openTabDiagnostics => const SimcruxActionDescriptor(
    surfaces: _menuPalette,
    isEnabled: _requiresTabAndDiagnostics,
  ),

  // ── Needs a loaded config ─────────────────────────────────────────
  SimcruxAction.switchProject ||
  SimcruxAction.searchAcrossProjects ||
  SimcruxAction.configureRetentionPolicy => const SimcruxActionDescriptor(
    surfaces: _menuPalette,
    isEnabled: _requiresConfig,
  ),

  // Sits with the other config-needing actions rather than hidden, and
  // alongside configureRetentionPolicy above for the same reason: both open a
  // Pro Settings section body in a dialog, and both are also reachable from
  // the Settings rail. See the note on dispatchPrAnnotations below.
  SimcruxAction.configurePrAnnotationTarget => const SimcruxActionDescriptor(
    surfaces: _menuPalette,
    isEnabled: _requiresConfig,
  ),

  // ── Running a regression ──────────────────────────────────────────
  // A run needs a config, and starting a second over a live one is not
  // supported — so the run commands grey out while one is in flight and
  // Cancel greys out when none is. Before this the two were permanently
  // lit side by side, and the toolbar gave no clue which was live.
  SimcruxAction.runRegression => const SimcruxActionDescriptor(
    surfaces: _everywhere,
    isEnabled: _canStartRun,
  ),
  SimcruxAction.cancelRegression => const SimcruxActionDescriptor(
    surfaces: _everywhere,
    isEnabled: _requiresRunInProgress,
  ),
  // Re-run needs a selected test as well as an idle runner.
  SimcruxAction.reRunSelected => const SimcruxActionDescriptor(
    surfaces: _everywhere,
    isEnabled: _canReRunSelected,
  ),

  // ── Needs results to summarize ────────────────────────────────────
  // Every one of these renders a chart, table, or annotation payload
  // built from the result set; with none they are an empty shell.
  SimcruxAction.openSeedFailureHeatmap ||
  SimcruxAction.showTrendChart ||
  SimcruxAction.showSuiteTrendChart ||
  SimcruxAction.showCalendarHeatmap ||
  SimcruxAction.showFlakyTests ||
  // Manual PR-annotation dispatch belongs in this group on the merits: it
  // posts a payload built from the result set, so with no results it has
  // nothing to send.
  //
  // It is not a stub: the Pro overlay's Settings UI, dispatch service and
  // opener are real, and so is the auto-dispatch run-completion hook. Hiding
  // it behind an empty surface set would keep a built feature out of reach.
  SimcruxAction.dispatchPrAnnotations ||
  // Export needs a completed run for the same reason. The dialog itself
  // re-checks and shows `exportEmpty` rather than trusting the grey-out: the
  // palette drops disabled actions but a keyboard binding does not.
  SimcruxAction.exportResults => const SimcruxActionDescriptor(
    surfaces: _menuPalette,
    isEnabled: _requiresResults,
  ),

  // ── Theme — browsable, always enabled ─────────────────────────────
  // Flipping light/dark is workspace-independent.
  SimcruxAction.toggleTheme => const SimcruxActionDescriptor(
    surfaces: _menuPalette,
  ),

  // ── Pane management ───────────────────────────────────────────────
  SimcruxAction.splitPaneRight => const SimcruxActionDescriptor(
    surfaces: _menuPalette,
    isEnabled: _requiresTabSinglePane,
  ),
  SimcruxAction.closePane ||
  SimcruxAction.focusOtherPane => const SimcruxActionDescriptor(
    surfaces: _menuPalette,
    isEnabled: _requiresMultiPane,
  ),
  SimcruxAction.moveTabToOtherPane => const SimcruxActionDescriptor(
    surfaces: _menuPalette,
    isEnabled: _requiresTabMultiPane,
  ),
};

// ── derived selectors (the API every surface consumes) ───────────────────────

/// Whether [action] structurally appears in [surface] under [context].
bool isActionVisibleIn(
  SimcruxAction action,
  SimcruxActionSurface surface,
  SimcruxActionContext context,
) => descriptorFor(action).surfaces.contains(surface);

/// Whether [action] is currently enabled under [context].
bool isActionEnabled(SimcruxAction action, SimcruxActionContext context) =>
    descriptorFor(action).isEnabled(context);

/// Actions to render in [surface] under [context], grouped by
/// [ActionCategory]. Disabled actions are *included* — the menu greys them
/// out; only structurally-hidden actions are omitted.
Map<ActionCategory, List<SimcruxAction>> groupedActionsFor(
  SimcruxActionSurface surface,
  SimcruxActionContext context,
) {
  final result = <ActionCategory, List<SimcruxAction>>{
    for (final category in ActionCategory.values) category: <SimcruxAction>[],
  };
  for (final action in SimcruxAction.values) {
    if (isActionVisibleIn(action, surface, context)) {
      result[action.category]!.add(action);
    }
  }
  return result;
}

/// Actions to list in the command palette — visible **and** enabled.
List<SimcruxAction> paletteActionsFor(SimcruxActionContext context) =>
    SimcruxAction.values
        .where(
          (a) =>
              isActionVisibleIn(a, SimcruxActionSurface.palette, context) &&
              isActionEnabled(a, context),
        )
        .toList();

// ── surface sets ─────────────────────────────────────────────────────────────

const Set<SimcruxActionSurface> _everywhere = {
  SimcruxActionSurface.toolbar,
  SimcruxActionSurface.menu,
  SimcruxActionSurface.palette,
};

const Set<SimcruxActionSurface> _menuPalette = {
  SimcruxActionSurface.menu,
  SimcruxActionSurface.palette,
};

const Set<SimcruxActionSurface> _menuOnly = {SimcruxActionSurface.menu};

// ── enablement predicates (top-level for const tear-off) ─────────────────────

bool _requiresTab(SimcruxActionContext c) => c.hasOpenTab;
bool _requiresTabAndDiagnostics(SimcruxActionContext c) =>
    c.hasOpenTab && c.diagnosticsEnabled;
bool _requiresConfig(SimcruxActionContext c) => c.hasConfig;
bool _requiresResults(SimcruxActionContext c) => c.hasResults;
bool _requiresRunInProgress(SimcruxActionContext c) => c.runInProgress;
bool _canStartRun(SimcruxActionContext c) => c.hasConfig && !c.runInProgress;
bool _canReRunSelected(SimcruxActionContext c) =>
    c.hasSelectedTest && !c.runInProgress;
bool _requiresMultiPane(SimcruxActionContext c) => c.paneCount >= 2;
bool _requiresTabSinglePane(SimcruxActionContext c) =>
    c.hasOpenTab && c.paneCount == 1;
bool _requiresTabMultiPane(SimcruxActionContext c) =>
    c.hasOpenTab && c.paneCount >= 2;
