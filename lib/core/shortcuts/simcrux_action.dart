// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_license/crux_license.dart';
import 'package:crux_shortcut_action/crux_shortcut_action.dart';
import 'package:flutter/widgets.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// Every user-facing action in simcrux. Single source of truth for the
/// command palette, the desktop menu bar, the toolbar, and the keyboard
/// shortcut system.
///
/// Implements [CruxAction] so the cross-suite command palette
/// (`CommandPalette<SimcruxAction>`) and any future shared
/// infrastructure can reason about the action without depending on
/// simcrux's specific enum shape. Mirrors the NetCrux / WaveCrux
/// pattern; namespaced via the `simcrux.` prefix so action ids do not
/// collide across products in shared telemetry / settings surfaces.
enum SimcruxAction implements CruxAction {
  /// Open a `simcrux.yaml` project file via file picker.
  openProject,

  /// Import a FuseSoC CAPI2 `.core` file: parse it, translate into a
  /// `simcrux.yaml`, write the result next to the source file, and
  /// surface any importer warnings to the user.
  importFusesoc,

  /// Import a `riscv-arch-test` checkout: enumerate it into one SimCrux
  /// test per architectural test, write the synthesized `simcrux.yaml`
  /// where the user chooses, and open it.
  ///
  /// The scan is over somebody else's git checkout, so the user picks the
  /// source directory and then the destination file — the importer never
  /// writes into the tree it read.
  importRiscvArchTest,

  /// Import a riscv-formal `checks/` directory (the `.sby` jobs
  /// `genchecks.py` wrote): enumerate it into one SimCrux test per bounded
  /// proof, write the synthesized `simcrux.yaml` where the user chooses,
  /// and open it.
  importRiscvFormal,

  /// Close the currently open project.
  closeProject,

  /// Close the active workspace tab. Cmd/Ctrl+W — the universal "close"
  /// convention, matching WaveCrux and LintCrux (suite keyboard-parity
  /// pass). SimCrux tabs *are* projects, so this closes the active
  /// project's tab; [closeProject] keeps its explicit label and moves to
  /// Cmd/Ctrl+Shift+W.
  closeTab,

  /// Run the active project's regression (or the selected suite when
  /// a filter is active).
  runRegression,

  /// Re-run the currently selected test in the inspector pane.
  reRunSelected,

  /// Cancel the in-flight regression.
  cancelRegression,

  /// Export the completed run — JUnit XML, JSON, CSV or HTML — through the
  /// Export Results dialog.
  ///
  /// Open-core in every tier: the four exporters are open-core, and none of
  /// the formats is a paid capability.
  ///
  /// This is the GUI door onto `ExporterRegistry`. Without it the formats
  /// are reachable only through `--export` and `--ci`, and a GUI user has
  /// no export path at all.
  exportResults,

  /// Quit the application.
  quit,

  /// Toggle the left test/run browser pane.
  toggleTestBrowser,

  /// Toggle the right inspector / detail pane.
  toggleInspector,

  /// Toggle the bottom log-stream pane.
  toggleLogPanel,

  /// Flip the app between the light and dark color themes
  /// (Cmd/Ctrl+Shift+K, matching WaveCrux / NetCrux / LintCrux).
  /// Activates the opposite-brightness default preset — brightness in
  /// SimCrux is driven by the active color-theme preset (the WaveCrux
  /// model), not the legacy `AppThemeMode` flag, which `MaterialApp`
  /// never reads.
  toggleTheme,

  // `focusTestBrowser` / `focusRunResults` lived here. They never had a
  // handler — dispatching either only showed a "not yet implemented" snack —
  // while `Cmd/Ctrl+Shift+1` and `+2` stayed bound to them, so the chords
  // fired a notice for an action no menu or palette would admit to having.
  // They were also redundant: `CruxFocusRegionScope` already moves keyboard
  // focus between the toolbar, the Tests panel, the results table, the
  // Details panel, the Log panel and the status strip on F6 / Shift+F6, which
  // is the capability per-pane focus commands would have duplicated. Removed
  // rather than implemented; the two chords are free for a real Navigate
  // surface if one is ever wanted. Persisted user rebindings survive —
  // `KeymapCodec.decode` skips ids it no longer knows.

  /// Open the test/run search dialog.
  openSearch,

  /// Open the command palette overlay.
  openCommandPalette,

  /// Open the settings screen.
  openSettings,

  /// Open the about box.
  openAbout,

  /// Run a manual "Check for Updates" against the release manifest.
  ///
  /// Open-core, every tier: staying on a current build is not a paid
  /// feature. Unlike the launch / periodic / on-resume checks, this
  /// one ignores the Settings → General "Automatically check for
  /// updates" toggle — an explicit request always runs.
  checkForUpdates,

  /// Open the beta issue reporter — the in-app "file a GitHub issue
  /// with my diagnostics attached" flow.
  ///
  /// Open-core, every tier, and deliberately un-gated: the users most
  /// likely to hit a bug during the public beta are open-core users,
  /// and a support channel behind a paywall is not a support channel.
  submitIssue,

  /// Open the online SimCrux documentation (docs.simcrux.app) in the user's
  /// browser. Open Core and never tier-gated — every suite Help menu leads
  /// with it.
  openDocumentation,

  /// Split the active pane horizontally (creating a new pane to the
  /// right). The active tab moves to the new pane when the source
  /// pane has more than one tab; otherwise the new pane opens empty.
  splitPaneRight,

  /// Close the active pane, merging its tabs into the surviving pane.
  /// No-op when the workspace is already single-pane.
  closePane,

  /// Toggle focus to the other pane when the workspace is split,
  /// no-op when single-pane.
  focusOtherPane,

  /// Move the active tab to the other pane. Command-palette only —
  /// the gesture equivalent is the existing drag-tab-to-pane drop
  /// target on the package's `ViewerTabBar`.
  moveTabToOtherPane,

  /// Open the CXP cross-probe panel — shows currently-connected
  /// peers and a rolling log of recent cross-probe events.
  openCrossProbePanel,

  /// Open the Pro Seed Failure Heatmap screen.
  ///
  /// Open-core builds register the action so it shows up in the
  /// command palette / menu inventory, but the actual screen lives
  /// behind the `seedFailureHeatmapOpenerProvider` extension point.
  /// The Pro overlay installs the opener implementation; in an
  /// open-core build the dispatcher resolves to a no-op (with the
  /// Pro tier badge surfacing the upgrade context in the menu UI).
  openSeedFailureHeatmap,

  /// Open the Pro per-test trend chart screen.
  ///
  /// Open-core surfaces the action through the
  /// `perTestTrendChartOpenerProvider` extension point; the Pro
  /// overlay registers the screen as part of its `proOverrides`.
  showTrendChart,

  /// Open the Pro per-suite trend chart screen.
  ///
  /// Open-core surfaces the action through the
  /// `perSuiteTrendChartOpenerProvider` extension point.
  showSuiteTrendChart,

  /// Open the Pro calendar-heatmap trend screen.
  ///
  /// Open-core surfaces the action through the
  /// `calendarHeatmapOpenerProvider` extension point.
  showCalendarHeatmap,

  /// Open the Pro Flaky Tests panel (the standalone flakiness view).
  ///
  /// Open-core surfaces the action through the
  /// `flakyTestsPanelOpenerProvider` extension point; the Pro overlay
  /// registers the opener in its `proOverrides`. The
  /// flaky-detection feature also surfaces through the dashboard row
  /// annotation and the Settings → Flaky Test Detection section; this
  /// action is the panel's activation entry point.
  showFlakyTests,

  /// Open the Pro retention policy settings dialog (or scroll the
  /// settings screen to the trend retention section).
  ///
  /// Open-core surfaces the action through the
  /// `retentionPolicySettingsOpenerProvider` extension point.
  configureRetentionPolicy,

  /// Dispatch the current run's failures to the configured PR /
  /// MR / webhook target as PR annotations.
  ///
  /// Open-core surfaces the action through the
  /// `prAnnotationDispatchOpenerProvider` extension point; the Pro overlay
  /// builds the batch from the active run's full result set, posts it, and
  /// reports the outcome.
  ///
  /// The Pro overlay's target-configuration Settings UI makes both openers
  /// reachable, so the action has a menu entry and palette surfaces; an
  /// empty surface set would keep manual dispatch out of a user's hands.
  dispatchPrAnnotations,

  /// Open the PR Annotation target configuration surface — the platform
  /// (GitHub / GitLab / webhook), the repository / MR number, the auth token
  /// (persisted to the OS keychain via `crux_secrets`) and a test-connection
  /// button.
  ///
  /// Open-core surfaces the action through the
  /// `prAnnotationSettingsOpenerProvider` extension point; the Pro overlay
  /// hosts the same body it registers on the Settings rail as
  /// `pro.pr_annotation` inside a desktop dialog. That double placement is
  /// deliberate and follows [configureRetentionPolicy], which pairs a Tools
  /// action with the `pro.retention` Settings category in exactly the same
  /// way.
  configurePrAnnotationTarget,

  /// Open the project switcher dialog (Ctrl/Cmd+P). Searchable list
  /// of currently-open and recently-closed projects; selecting an
  /// open project sets it active, selecting a recent project
  /// re-opens it.
  ///
  /// Pro-tier feature; FeatureGate at activation. The switcher is a
  /// view onto the Pro multi-project registry — open-core ships no
  /// switcher widget and `projectSwitcherOpenerProvider` defaults to
  /// null.
  switchProject,

  /// Reopen the most-recently-closed project from the
  /// recent-projects list. Convenience around the project switcher
  /// for the common workflow.
  ///
  /// Pro-tier feature; FeatureGate at activation. Recents exist only
  /// in the Pro registry — [NoopProjectRegistry] clears them by
  /// construction.
  reopenRecentProject,

  /// Pin or unpin the active project tab. Pinned tabs survive the
  /// [closeAllProjects] action.
  ///
  /// Pro-tier feature; FeatureGate at activation.
  pinActiveProject,

  /// Close every open project that is not pinned.
  ///
  /// Pro-tier feature; FeatureGate at activation. "Except pinned" is a
  /// contract only the Pro registry can honor, so the whole action is
  /// Pro; the tier-free tab-closing capability is [closeAllTabs].
  closeAllProjects,

  /// Close every open workspace tab, after confirmation.
  ///
  /// Open-core, unconditional: this is the plain tab-closing
  /// capability — no project registry, no pinning, no recents. It is
  /// what [closeAllProjects] actually did in an open-core build, given
  /// its own honest name so free users keep the capability while the
  /// registry-aware, pin-respecting variant carries the PRO badge.
  closeAllTabs,

  /// Open the cross-project search dialog (Ctrl/Cmd+Shift+F).
  /// Searches test names, failure messages, and file paths across
  /// every currently-open project; results group by project with a
  /// click-to-jump that switches active project plus selects the
  /// matched test.
  ///
  /// Pro-tier feature; surfaced via the
  /// `crossProjectSearchOpenerProvider` extension point.
  searchAcrossProjects,

  /// Open the Settings → Plugins panel showing every installed
  /// custom simulator driver plugin. Lets the user enable / disable
  /// plugin support (the one-time safety acknowledgment) and inspect
  /// installed manifests; the Pro overlay's section also installs from a
  /// zip, disables and uninstalls individual plugins.
  ///
  /// Pro-tier feature; dispatched through the
  /// `pluginManagerOpenerProvider` seam. The Pro overlay's opener
  /// opens the Settings dialog whose Plugins section (contributed
  /// via `extraSettingsSectionsProvider`) renders `SimCruxFeatureTierBadge`
  /// and gates on `proFeatureUnlocked`. Open-core builds surface the
  /// Pro-gated snackbar (the opener default is null).
  openPluginManager,

  /// Re-scan the configured plugin directory and refresh the
  /// installed-plugin list. Dispatched from Settings → Plugins and
  /// from the command palette so plugin authors developing locally
  /// can pick up manifest / executable changes without restarting
  /// the app.
  ///
  /// Dispatched through the `reloadPluginsOpenerProvider` seam.
  /// Open-core builds surface the Pro-gated snackbar (the opener
  /// default is null; the default registry enumerates nothing
  /// anyway). The Pro overlay's opener re-queries the subprocess
  /// registry and reports the installed count — or, before the
  /// plugin-safety acknowledgment is granted, points the user at
  /// Settings → Plugins.
  reloadPlugins,

  /// Open the per-tab Tab Diagnostics drawer for the active tab.
  ///
  /// Suite UI-consistency pass: the drawer widget already existed but was
  /// wired only as an unreachable Scaffold `endDrawer`. It now opens as a
  /// WaveCrux-style non-modal OverlayEntry drawer (Cmd/Ctrl+Shift+I,
  /// Tools menu, command palette) — the same reachability WaveCrux gives
  /// its Tab Diagnostics surface.
  openTabDiagnostics,

  /// Open the process-wide App Diagnostics dialog.
  ///
  /// The dialog itself already existed but nothing opened it — no menu
  /// item, no palette entry, no button — so the only way to see it was
  /// a widget test. It is the suite-wide diagnostics surface (WaveCrux
  /// and LintCrux both carry it in Tools), which is what makes its
  /// absence from the menu a consistency gap rather than a missing
  /// feature.
  openAppDiagnostics;

  @override
  String get id => 'simcrux.$name';

  /// The minimum license tier required to *use* this action.
  ///
  /// Single source of truth for tier metadata across every action
  /// surface: the command palette renders a `SimCruxFeatureTierBadge` for any
  /// action whose tier is above [LicenseTier.openCore]; the native
  /// desktop menu bar appends a localized `tierLabelSuffix` (e.g.
  /// `" (PRO)"`); the app dispatcher can gate on it. Declaring it here,
  /// once, means a new Pro action gets its badge + suffix automatically
  /// by returning `LicenseTier.pro` — no per-surface wiring.
  ///
  /// The switch is intentionally **exhaustive with no `default`**: adding
  /// a new [SimcruxAction] value fails to compile until its tier is
  /// classified here, so a Pro action can never ship tier-less and
  /// invisible in the palette / menu. (Mirrors the WaveCrux / NetCrux /
  /// LintCrux `requiredTier` convention; SimCrux carries it on the enum
  /// directly rather than a separate `ActionDescriptor`.)
  LicenseTier get requiredTier {
    switch (this) {
      // Pro-tier actions. Every one is surfaced in
      // open-core builds for discoverability but activates only through a
      // Pro extension-point override; the tier badge/suffix communicates
      // the upgrade context.
      case SimcruxAction.openSeedFailureHeatmap:
      case SimcruxAction.showTrendChart:
      case SimcruxAction.showSuiteTrendChart:
      case SimcruxAction.showCalendarHeatmap:
      case SimcruxAction.showFlakyTests:
      case SimcruxAction.configureRetentionPolicy:
      case SimcruxAction.dispatchPrAnnotations:
      case SimcruxAction.configurePrAnnotationTarget:
      case SimcruxAction.pinActiveProject:
      case SimcruxAction.searchAcrossProjects:
      case SimcruxAction.openPluginManager:
      case SimcruxAction.reloadPlugins:
      // Multi-project registry semantics. Open-core
      // ships `NoopProjectRegistry`: one project, no recents, no
      // pinning. Every action whose *meaning* is defined by the
      // persistent registry is therefore Pro in every product that has
      // one — switching between open projects, reopening a recent, and
      // closing all-but-pinned all resolve to nothing under the no-op
      // default. The tier-free capability that `closeAllProjects` was
      // really providing in an open-core build ships separately and
      // honestly as [closeAllTabs].
      case SimcruxAction.switchProject:
      case SimcruxAction.reopenRecentProject:
      case SimcruxAction.closeAllProjects:
        return LicenseTier.pro;
      // Open-core actions — no tier badge / suffix. CXP cross-probe
      // receive (the panel) is open-core for every product; only CXP
      // *originate* (the Pro row menu) is gated, and that is not an action.
      case SimcruxAction.openProject:
      case SimcruxAction.importFusesoc:
      // The two RISC-V imports are open-core for the same reason the whole
      // `riscv:` config path is: a compatibility verdict is correctness,
      // and monetizing the door to RVI's own test suite would be tolling a
      // standard.
      case SimcruxAction.importRiscvArchTest:
      case SimcruxAction.importRiscvFormal:
      case SimcruxAction.closeProject:
      case SimcruxAction.runRegression:
      case SimcruxAction.reRunSelected:
      case SimcruxAction.cancelRegression:
      // Export is open-core in every format. The four exporters have always
      // been open-core and the `--export` CLI flag has never been gated;
      // charging for the GUI door onto a capability the binary already gives
      // away for free would be a tier boundary drawn around a menu item.
      case SimcruxAction.exportResults:
      case SimcruxAction.quit:
      case SimcruxAction.toggleTestBrowser:
      case SimcruxAction.toggleInspector:
      case SimcruxAction.toggleLogPanel:
      case SimcruxAction.openSearch:
      case SimcruxAction.openCommandPalette:
      case SimcruxAction.openSettings:
      case SimcruxAction.openAbout:
      // Update check + issue reporter: beta-release infrastructure, free
      // to every tier in every build.
      case SimcruxAction.checkForUpdates:
      case SimcruxAction.submitIssue:
      case SimcruxAction.openDocumentation:
      case SimcruxAction.splitPaneRight:
      case SimcruxAction.closePane:
      case SimcruxAction.focusOtherPane:
      case SimcruxAction.moveTabToOtherPane:
      case SimcruxAction.openCrossProbePanel:
      // Opening and closing a single project work standalone under
      // `NoopProjectRegistry`, as does closing every workspace tab, so
      // all three stay open-core. LintCrux classifies `openProject` /
      // `closeActiveProject` the same way.
      case SimcruxAction.closeAllTabs:
      case SimcruxAction.closeTab:
      // The theme toggle operates on the app shell, which is never a paid
      // capability — open core in every suite product.
      case SimcruxAction.toggleTheme:
      // Diagnostics is support infrastructure, free in every build — the
      // report is what a bug filer pastes into an issue.
      case SimcruxAction.openTabDiagnostics:
      case SimcruxAction.openAppDiagnostics:
        return LicenseTier.openCore;
    }
  }

  @override
  ActionCategory get category {
    switch (this) {
      case SimcruxAction.openProject:
      case SimcruxAction.importFusesoc:
      case SimcruxAction.importRiscvArchTest:
      case SimcruxAction.importRiscvFormal:
      case SimcruxAction.switchProject:
      case SimcruxAction.reopenRecentProject:
      case SimcruxAction.pinActiveProject:
      case SimcruxAction.closeTab:
      case SimcruxAction.closeProject:
      case SimcruxAction.closeAllProjects:
      case SimcruxAction.closeAllTabs:
        return ActionCategory.file;
      // Quit lives in the "App" category so it renders at the top of the
      // macOS application menu (the menu labelled with the app name), as
      // standard. The desktop menu bar's Windows / Linux branch moves the
      // App-category items into the File menu so users on those platforms
      // see "Exit" at the bottom of the File menu instead.
      // Settings and Quit live in the "App" category: on macOS the shared
      // menu bar renders them in the system application menu, and on
      // Windows / Linux it folds them into the bottom of the File menu.
      // Settings used to sit in Tools, which is where Windows and Linux
      // users actually saw it — not where any other suite product puts it.
      case SimcruxAction.openSettings:
      case SimcruxAction.quit:
        return ActionCategory.app;
      // VS Code lists the palette opener at the top of View; the suite
      // follows it, and every surface reads this one category.
      case SimcruxAction.openCommandPalette:
      case SimcruxAction.toggleTestBrowser:
      case SimcruxAction.toggleInspector:
      case SimcruxAction.toggleLogPanel:
      // Cross-probe is a panel, so it sits in View with the other panel
      // toggles — the suite's flagship cross-product feature was in a
      // different menu in half the products.
      case SimcruxAction.openCrossProbePanel:
      case SimcruxAction.splitPaneRight:
      case SimcruxAction.closePane:
      case SimcruxAction.focusOtherPane:
      case SimcruxAction.moveTabToOtherPane:
      // Appearance closes the View menu in every suite product.
      case SimcruxAction.toggleTheme:
        return ActionCategory.view;
      // No action maps to `ActionCategory.navigate`. The two focus stubs that
      // did were removed (see the enum above); F6 / Shift+F6 region traversal
      // covers keyboard navigation, and it is not a dispatchable action.
      case SimcruxAction.openSearch:
      case SimcruxAction.searchAcrossProjects:
        return ActionCategory.search;
      case SimcruxAction.openDocumentation:
      case SimcruxAction.openAbout:
      case SimcruxAction.checkForUpdates:
      case SimcruxAction.submitIssue:
        return ActionCategory.help;
      // Running a regression is a Tools verb, not a File one. LintCrux
      // already grouped its Run All Engines / Cancel Run there; SimCrux had
      // the same three commands sitting under File.
      case SimcruxAction.runRegression:
      case SimcruxAction.reRunSelected:
      case SimcruxAction.cancelRegression:
      case SimcruxAction.openSeedFailureHeatmap:
      case SimcruxAction.showTrendChart:
      case SimcruxAction.showSuiteTrendChart:
      case SimcruxAction.showCalendarHeatmap:
      case SimcruxAction.showFlakyTests:
      case SimcruxAction.configureRetentionPolicy:
      case SimcruxAction.dispatchPrAnnotations:
      case SimcruxAction.configurePrAnnotationTarget:
      case SimcruxAction.openPluginManager:
      case SimcruxAction.reloadPlugins:
      case SimcruxAction.exportResults:
      case SimcruxAction.openTabDiagnostics:
      case SimcruxAction.openAppDiagnostics:
        return ActionCategory.tools;
    }
  }
}

/// Localized label extension on [SimcruxAction]. Lives alongside the
/// enum because labels are L10N-coupled — the cross-suite [CruxAction]
/// interface stays Flutter- and L10N-free.
extension SimcruxActionLabel on SimcruxAction {
  /// The localized display label for this action (menu, command
  /// palette, toolbar tooltip).
  String label(L10N l10n) {
    switch (this) {
      case SimcruxAction.openProject:
        return l10n.actionOpenProject;
      case SimcruxAction.importFusesoc:
        return l10n.actionImportFusesoc;
      case SimcruxAction.importRiscvArchTest:
        return l10n.actionImportRiscvArchTest;
      case SimcruxAction.importRiscvFormal:
        return l10n.actionImportRiscvFormal;
      case SimcruxAction.closeProject:
        return l10n.actionCloseProject;
      case SimcruxAction.closeTab:
        return l10n.actionCloseTab;
      case SimcruxAction.toggleTheme:
        return l10n.actionToggleTheme;
      case SimcruxAction.runRegression:
        return l10n.actionRunRegression;
      case SimcruxAction.reRunSelected:
        return l10n.actionReRunSelected;
      case SimcruxAction.cancelRegression:
        return l10n.actionCancelRegression;
      case SimcruxAction.quit:
        return l10n.actionQuit;
      case SimcruxAction.toggleTestBrowser:
        return l10n.actionToggleTestBrowser;
      case SimcruxAction.toggleInspector:
        return l10n.actionToggleInspector;
      case SimcruxAction.toggleLogPanel:
        return l10n.actionToggleLogPanel;
      case SimcruxAction.openSearch:
        return l10n.actionOpenSearch;
      case SimcruxAction.openCommandPalette:
        return l10n.actionOpenCommandPalette;
      case SimcruxAction.openSettings:
        return l10n.actionOpenSettings;
      case SimcruxAction.openAbout:
        return l10n.actionOpenAbout;
      case SimcruxAction.checkForUpdates:
        return l10n.actionCheckForUpdates;
      case SimcruxAction.submitIssue:
        return l10n.actionSubmitIssue;
      case SimcruxAction.openDocumentation:
        return l10n.actionOpenDocumentation;
      case SimcruxAction.splitPaneRight:
        return l10n.actionSplitPaneRight;
      case SimcruxAction.closePane:
        return l10n.actionClosePane;
      case SimcruxAction.focusOtherPane:
        return l10n.actionFocusOtherPane;
      case SimcruxAction.moveTabToOtherPane:
        return l10n.actionMoveTabToOtherPane;
      case SimcruxAction.openCrossProbePanel:
        return l10n.actionOpenCrossProbePanel;
      case SimcruxAction.openSeedFailureHeatmap:
        return l10n.actionOpenSeedFailureHeatmap;
      case SimcruxAction.showTrendChart:
        return l10n.actionShowTrendChart;
      case SimcruxAction.showSuiteTrendChart:
        return l10n.actionShowSuiteTrendChart;
      case SimcruxAction.showCalendarHeatmap:
        return l10n.actionShowCalendarHeatmap;
      case SimcruxAction.showFlakyTests:
        return l10n.actionShowFlakyTests;
      case SimcruxAction.configureRetentionPolicy:
        return l10n.actionConfigureRetentionPolicy;
      case SimcruxAction.exportResults:
        return l10n.actionExportResults;
      case SimcruxAction.dispatchPrAnnotations:
        return l10n.actionDispatchPrAnnotations;
      case SimcruxAction.configurePrAnnotationTarget:
        return l10n.actionConfigurePrAnnotationTarget;
      case SimcruxAction.switchProject:
        return l10n.actionSwitchProject;
      case SimcruxAction.reopenRecentProject:
        return l10n.actionReopenRecentProject;
      case SimcruxAction.pinActiveProject:
        return l10n.actionPinActiveProject;
      case SimcruxAction.closeAllProjects:
        return l10n.actionCloseAllProjects;
      case SimcruxAction.closeAllTabs:
        return l10n.actionCloseAllTabs;
      case SimcruxAction.searchAcrossProjects:
        return l10n.actionSearchAcrossProjects;
      case SimcruxAction.openPluginManager:
        return l10n.actionOpenPluginManager;
      case SimcruxAction.reloadPlugins:
        return l10n.actionReloadPlugins;
      case SimcruxAction.openTabDiagnostics:
        return l10n.actionOpenTabDiagnostics;
      case SimcruxAction.openAppDiagnostics:
        return l10n.actionOpenAppDiagnostics;
    }
  }
}

/// Flutter [Intent] subclass used to dispatch a [SimcruxAction]
/// through Flutter's `Shortcuts` / `Actions` machinery. Each product
/// has its own Intent subtype so
/// `Actions.maybeInvoke<SimcruxActionIntent>` keeps dispatch
/// type-safe.
class SimcruxActionIntent extends Intent {
  /// Wraps [action] for dispatch through `Actions.invoke`.
  const SimcruxActionIntent(this.action);

  /// The user-facing action to fire.
  final SimcruxAction action;
}
