// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_menu_bar/crux_menu_bar.dart';
import 'package:simcrux/core/shortcuts/action_category.dart';
import 'package:simcrux/core/shortcuts/simcrux_action.dart';

/// Declarative ordering and grouping of SimCrux's menu-bar actions, in the
/// suite-wide canonical group order (see the shared `crux_menu_bar` README).
///
/// This table is the single source of truth for the *order* menu items appear
/// in and *where the separators fall*. Before it, SimCrux rendered every
/// category as one undifferentiated run in enum-declaration order, and its
/// File menu opened with Open Config… followed immediately by Run Regression,
/// Re-run Selected Test and Cancel Regression — three Tools verbs sitting in
/// the File menu.
///
/// ## Canonical group order
///
/// - **File** — Open/Import | Projects | Close
/// - **View** — Command Palette | Panels | Panes | Appearance
/// - **Navigate** — (empty until the focus actions ship)
/// - **Search** — Find | Find across projects
/// - **Tools** — Run | Analysis | Plugins | Diagnostics (last)
/// - **Help** — Documentation | Report Issue | Check for Updates | About
///
/// ## Not in this table on purpose
///
/// `openSettings` and `quit` are placed by `CruxDesktopMenuBar` from
/// [kAppMenuActions] because their placement is platform-specific. `openAbout`
/// and `checkForUpdates` *are* here, under Help — their Windows/Linux home —
/// and the macOS renderer hoists them into the application menu.
///
/// `ActionCategory.edit` has no entry: SimCrux has no editing actions, so no
/// Edit menu renders.
const CruxMenuLayout<SimcruxAction> kMenuLayout = {
  // ── File ──────────────────────────────────────────────────────────────────
  ActionCategory.file: [
    // Open leads, then every importer, in the order the ecosystems were
    // wired: FuseSoC, then the two RISC-V flows. One group, because they
    // are one job — "turn something that is not a simcrux.yaml into one".
    [
      SimcruxAction.openProject,
      SimcruxAction.importFusesoc,
      SimcruxAction.importRiscvArchTest,
      SimcruxAction.importRiscvFormal,
    ],
    [
      SimcruxAction.switchProject,
      SimcruxAction.reopenRecentProject,
      SimcruxAction.pinActiveProject,
    ],
    // Close Tab (Cmd/Ctrl+W) leads the close group, mirroring WaveCrux
    // and LintCrux (suite keyboard-parity pass). SimCrux tabs *are*
    // projects, so Close Project closes the same active tab under its
    // project-flavored label at Cmd/Ctrl+Shift+W.
    [
      SimcruxAction.closeTab,
      SimcruxAction.closeAllTabs,
      SimcruxAction.closeProject,
      SimcruxAction.closeAllProjects,
    ],
  ],

  // ── View ──────────────────────────────────────────────────────────────────
  ActionCategory.view: [
    [
      SimcruxAction.openCommandPalette,
    ],
    [
      SimcruxAction.toggleTestBrowser,
      SimcruxAction.toggleInspector,
      SimcruxAction.toggleLogPanel,
      SimcruxAction.openCrossProbePanel,
    ],
    [
      SimcruxAction.splitPaneRight,
      SimcruxAction.closePane,
      SimcruxAction.focusOtherPane,
      SimcruxAction.moveTabToOtherPane,
    ],
    // Appearance closes the View menu in every suite product.
    [
      SimcruxAction.toggleTheme,
    ],
  ],

  // ── Navigate ──────────────────────────────────────────────────────────────
  // No entries, and no action in the category: the two focus stubs that
  // would have filled it were removed rather than implemented (they only
  // ever showed a "not yet implemented" notice, while F6 / Shift+F6 region
  // traversal already moves focus between panes). No Navigate menu renders.

  // ── Search ────────────────────────────────────────────────────────────────
  ActionCategory.search: [
    [
      SimcruxAction.openSearch,
    ],
    [
      SimcruxAction.searchAcrossProjects,
    ],
  ],

  // ── Tools ─────────────────────────────────────────────────────────────────
  ActionCategory.tools: [
    // Run commands lead Tools, where LintCrux already keeps its Run All
    // Engines / Cancel Run pair. These three used to sit in File.
    [
      SimcruxAction.runRegression,
      SimcruxAction.reRunSelected,
      SimcruxAction.cancelRegression,
    ],
    [
      SimcruxAction.showTrendChart,
      SimcruxAction.showSuiteTrendChart,
      SimcruxAction.showCalendarHeatmap,
      SimcruxAction.openSeedFailureHeatmap,
      SimcruxAction.showFlakyTests,
      SimcruxAction.configureRetentionPolicy,
    ],
    // The PR-annotation pair. Both are reachable in the Pro overlay (its
    // Settings UI configures the target), so they get a menu home. Dispatch leads
    // and configuration follows it — the user reaches for dispatch first and
    // only needs the target dialog when it reports there is no target.
    [
      SimcruxAction.dispatchPrAnnotations,
      SimcruxAction.configurePrAnnotationTarget,
    ],
    // Export sits on its own: it consumes the run rather than analysing it,
    // and it is the only open-core entry among the result-consuming groups.
    // Not in File — this menu table exists because verbs kept accreting
    // there, and "export" is a verb over the active run, not a file command.
    [SimcruxAction.exportResults],
    [
      SimcruxAction.openPluginManager,
      SimcruxAction.reloadPlugins,
    ],
    // Tools ends with the diagnostics group in every product: the per-tab
    // drawer, then the process-wide dialog — matching WaveCrux.
    [
      SimcruxAction.openTabDiagnostics,
      SimcruxAction.openAppDiagnostics,
    ],
  ],

  // ── Help ──────────────────────────────────────────────────────────────────
  // About and Check for Updates are hoisted into the macOS application menu.
  ActionCategory.help: [
    [
      SimcruxAction.openDocumentation,
    ],
    [
      SimcruxAction.submitIssue,
    ],
    [
      SimcruxAction.checkForUpdates,
    ],
    [
      SimcruxAction.openAbout,
    ],
  ],
};

/// The four actions whose menu placement the host platform decides.
const CruxAppMenuActions<SimcruxAction> kAppMenuActions = CruxAppMenuActions(
  about: SimcruxAction.openAbout,
  checkForUpdates: SimcruxAction.checkForUpdates,
  settings: SimcruxAction.openSettings,
  quit: SimcruxAction.quit,
);
