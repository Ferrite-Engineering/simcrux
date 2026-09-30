// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:crux_issue_reporter/crux_issue_reporter.dart';
import 'package:crux_license/crux_license.dart';
import 'package:crux_project/crux_project.dart' show kCruxProjectExtension;
import 'package:crux_settings_ui/crux_settings_ui.dart';
import 'package:crux_telemetry/crux_telemetry.dart';
import 'package:crux_theme/crux_theme.dart';
import 'package:crux_updates/crux_updates.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/core/help_urls.dart';
import 'package:simcrux/core/platform_utils.dart';
import 'package:simcrux/core/router/app_router.dart';
import 'package:simcrux/core/shortcuts/simcrux_action.dart';
import 'package:simcrux/core/simcrux_url_launcher.dart';
import 'package:simcrux/domain/enums/riscv_import_kind.dart';
import 'package:simcrux/domain/models/riscv_import_result.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/features/about/simcrux_about_dialog.dart';
import 'package:simcrux/features/command_palette/widgets/command_palette_dialog.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/dashboard/providers/regression_runner.dart';
import 'package:simcrux/features/dashboard/providers/seed_failure_heatmap_opener.dart';
import 'package:simcrux/features/diagnostics/widgets/app_diagnostics_dialog.dart';
import 'package:simcrux/features/diagnostics/widgets/tab_diagnostics_drawer.dart';
import 'package:simcrux/features/dialogs/confirm_dialog.dart';
import 'package:simcrux/features/export/export_results_flow.dart';
import 'package:simcrux/features/flaky_detection/providers/flaky_tests_panel_opener.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/features/panel_layout/providers/panel_layout_provider.dart';
import 'package:simcrux/features/projects/providers/cross_project_search_opener.dart';
import 'package:simcrux/features/projects/providers/project_list_openers.dart';
import 'package:simcrux/features/projects/providers/project_switcher_opener.dart';
import 'package:simcrux/features/remote/providers/cross_probe_visibility_provider.dart';
import 'package:simcrux/features/search/widgets/search_dialog.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/settings/screens/settings_screen.dart';
import 'package:simcrux/features/trend_tracking/providers/trend_screen_openers.dart';
import 'package:simcrux/features/viewer/providers/right_dock_provider.dart';
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';
import 'package:simcrux/features/workspace/providers/container_managers.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';
import 'package:simcrux/features/workspace/widgets/open_config_tab.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/driver_plugin/plugin_action_openers.dart';
import 'package:simcrux/services/import/fusesoc_importer.dart';
import 'package:simcrux/services/import/riscv_arch_test_importer.dart';
import 'package:simcrux/services/import/riscv_formal_check_importer.dart';
import 'package:simcrux/services/lifecycle/app_exit_coordinator.dart';
import 'package:simcrux/services/lifecycle/app_exit_provider.dart';
import 'package:simcrux/services/pr_annotation/pr_annotation_action_openers.dart';
import 'package:simcrux/services/telemetry/project_opened_event.dart';

/// Builds and owns the `SimcruxAction → VoidCallback` dispatch table
/// that the keyboard-shortcut manager, the native menu bar, and the
/// command palette all route through. Extracted out of
/// `SimcruxApp.build` (which had grown a 350-line handler map inline);
/// keeping it here — next to [SimcruxAction] and its `requiredTier` /
/// localized-label surfaces — gives the action model one home.
///
/// One source of truth: if an action has a handler entry, both the
/// keyboard activator and the palette/menu selection route to the same
/// closure. Actions without an entry still surface in the palette/menu
/// (so the keybinding inventory stays discoverable) and are a no-op
/// until their handler lands.
class SimcruxActionHandlers {
  const SimcruxActionHandlers._();

  /// Constructs the handler map.
  ///
  /// [builderContext] is the `MaterialApp.router` builder context —
  /// used only by the file-picker flows (which need a context for the
  /// post-import snackbar). Dialog / route-push actions instead resolve
  /// a context from *inside* the navigator via [_navigatorContext],
  /// because the builder context sits above the router's Navigator.
  static Map<SimcruxAction, VoidCallback> build(
    BuildContext builderContext,
    WidgetRef ref,
  ) {
    // Resolve the per-tab container for the active tab so app-level
    // actions (Run Regression, Cancel, Re-run Selected) reach the
    // correct per-tab provider scope. The dashboard providers
    // (regressionRunnerProvider, activeConfigProvider,
    // selectedTestIdProvider, …) are per-tab overrides; reading them
    // from the root container would hit a different instance with no
    // loaded config.
    ProviderContainer? activeTabContainer() {
      final ws = ref.read(workspaceProvider).value;
      final id = ws?.activeTabId;
      if (id == null) return null;
      final managers = ref.read(workspaceContainerManagersProvider);
      return managers.tabs.containerFor(id);
    }

    // The `context` captured by the MaterialApp.router builder closure
    // is ABOVE the Navigator that the router creates — `showDialog`,
    // `GoRouter.of(context).go(...)`, and `Navigator.of(context).push(...)`
    // all walk up looking for a navigator and find none. Operations that
    // need a dialog or a route push must resolve a context from INSIDE
    // the navigator tree first. We pull that from the router's
    // `navigatorKey.currentState`. Returns null while the navigator
    // hasn't mounted yet.
    BuildContext? navigatorContext() {
      final router = ref.read(appRouterProvider);
      return router.routerDelegate.navigatorKey.currentState?.context;
    }

    final handlers = <SimcruxAction, VoidCallback>{
      // ── File ──────────────────────────────────────────────
      SimcruxAction.openProject: () => unawaited(
        _openProjectFromPicker(builderContext, ref),
      ),
      SimcruxAction.importFusesoc: () => unawaited(
        _importFusesocFromPicker(builderContext, ref),
      ),
      SimcruxAction.importRiscvArchTest: () => unawaited(
        _importRiscvFromPicker(
          builderContext,
          ref,
          RiscvImportKind.archTest,
        ),
      ),
      SimcruxAction.importRiscvFormal: () => unawaited(
        _importRiscvFromPicker(
          builderContext,
          ref,
          RiscvImportKind.formal,
        ),
      ),
      SimcruxAction.closeProject: () {
        final ws = ref.read(workspaceProvider).value;
        final id = ws?.activeTabId;
        if (id == null) {
          _snackInfo(navigatorContext(), (l10n) => l10n.snackNoProjectOpen);
          return;
        }
        unawaited(
          ref.read(workspaceProvider.notifier).closeTab(id),
        );
      },
      // Cmd/Ctrl+W (suite keyboard-parity pass). SimCrux tabs *are*
      // projects, so closing the active tab is closing the active
      // project — both close actions share one implementation.
      SimcruxAction.closeTab: () {
        final ws = ref.read(workspaceProvider).value;
        final id = ws?.activeTabId;
        if (id == null) {
          _snackInfo(navigatorContext(), (l10n) => l10n.snackNoProjectOpen);
          return;
        }
        unawaited(
          ref.read(workspaceProvider.notifier).closeTab(id),
        );
      },
      // Close-all-but-pinned is a Pro multi-project registry
      // contract: `NoopProjectRegistry` pins nothing and holds one
      // project, so open-core has no implementation to offer and
      // routes to the Pro-gated message. The Pro overlay's opener
      // gates, confirms, and reconciles registry + workspace.
      SimcruxAction.closeAllProjects: () {
        final ctx = navigatorContext();
        final opener = ref.read(closeAllProjectsOpenerProvider);
        if (opener == null || ctx == null) {
          _snackProGated(ctx, SimcruxAction.closeAllProjects);
          return;
        }
        opener(ctx);
      },
      // The tier-free tab-closing capability. No registry, no
      // pinning: confirm, then close every open workspace tab.
      SimcruxAction.closeAllTabs: () {
        final ctx = navigatorContext();
        if (ref.read(workspaceProvider).value?.tabs.isEmpty ?? true) {
          _snackInfo(ctx, (l10n) => l10n.snackNoProjectOpen);
          return;
        }
        unawaited(_closeAllTabs(ctx, ref));
      },
      SimcruxAction.runRegression: () {
        final tabContainer = activeTabContainer();
        final config = tabContainer?.read(activeConfigProvider);
        if (tabContainer == null || config == null) {
          _snackInfo(navigatorContext(), (l10n) => l10n.snackNoProjectOpen);
          return;
        }
        // Re-read (re-parse) the project file from disk on every Run,
        // rather than running the in-memory `activeConfigProvider` parse
        // captured when the tab was armed/opened. An edit made to
        // `simcrux.yaml` since then (a changed `timeout:`, an added/removed
        // `tests:` entry, …) must take effect on the next Run without an app
        // relaunch. This mirrors the file-watcher `AutoReloadNotifier.
        // rerun()` path, which already reloads from disk for the same reason;
        // `startFromConfigPath` records a load error + AsyncError if the
        // (now edited) YAML no longer parses, so a bad edit surfaces in the
        // tab's error body instead of silently running the stale config.
        unawaited(
          tabContainer
              .read(regressionRunnerProvider.notifier)
              .startFromConfigPath(config.projectFilePath),
        );
      },
      SimcruxAction.cancelRegression: () {
        final tabContainer = activeTabContainer();
        if (tabContainer == null) {
          _snackInfo(navigatorContext(), (l10n) => l10n.snackNoProjectOpen);
          return;
        }
        unawaited(
          tabContainer.read(regressionRunnerProvider.notifier).cancel(),
        );
      },
      // Export Results. Without this the four exporters are reachable only
      // through `--export` / `--ci`; this is the GUI door onto the same
      // `ExporterRegistry`. Open-core in every tier — no format here is a paid
      // capability, so there is no opener seam and no tier gate.
      //
      // ModalGuard: the menu entry and the palette both dispatch here, and a
      // double-activation must not stack two save panels over each other.
      SimcruxAction.exportResults: () {
        final ctx = navigatorContext();
        final tabContainer = activeTabContainer();
        if (ctx == null) return;
        if (tabContainer == null) {
          _snackInfo(ctx, (l10n) => l10n.snackNoProjectOpen);
          return;
        }
        unawaited(
          ModalGuard.run(
            'exportResults',
            () => runExportResultsFlow(
              context: ctx,
              tabContainer: tabContainer,
            ),
          ),
        );
      },
      SimcruxAction.reRunSelected: () {
        final tabContainer = activeTabContainer();
        if (tabContainer == null) {
          _snackInfo(navigatorContext(), (l10n) => l10n.snackNoProjectOpen);
          return;
        }
        final spec = tabContainer.read(selectedTestProvider)?.spec;
        if (spec == null) {
          _snackInfo(navigatorContext(), (l10n) => l10n.snackNoTestSelected);
          return;
        }
        // `submitSpecs` runs exactly the specs it is handed and leaves
        // `activeConfigProvider` untouched. Narrowing the config and
        // routing through `start()` instead would (a) still flatten and
        // run every *other* suite's tests, since `start()` submits every
        // suite, and (b) publish the narrowed config as the active one,
        // silently shrinking the next plain "Run Regression".
        unawaited(
          tabContainer.read(regressionRunnerProvider.notifier).submitSpecs(
            <TestSpec>[spec],
            concurrency: 1,
          ),
        );
      },
      // Orderly shutdown: cancel every in-flight regression (across
      // every tab, via the app-scoped registry) so their simulator
      // process trees are reaped, then terminate. `exit(0)` on its own
      // orphaned every running vvp/verilator/make→python tree plus its
      // work dir. The coordinator's grace budget bounds the wait, so a
      // wedged driver delays the quit rather than blocking it.
      SimcruxAction.quit: () => unawaited(_quit(ref)),
      // ── View / panel toggles ──────────────────────────────
      // panelLayoutProvider is app-scoped (not per-tab) so
      // reading from ref is correct.
      SimcruxAction.toggleTestBrowser: () => unawaited(
        ref.read(panelLayoutProvider.notifier).toggleTestBrowser(),
      ),
      SimcruxAction.toggleInspector: () => unawaited(
        ref.read(panelLayoutProvider.notifier).toggleRunDetails(),
      ),
      SimcruxAction.toggleLogPanel: () => unawaited(
        ref.read(panelLayoutProvider.notifier).toggleLogPanel(),
      ),
      // Flip between the default light and dark presets. Brightness in
      // SimCrux is driven by the active color-theme preset —
      // `MaterialApp.themeMode` in app.dart derives from the preset's
      // brightness via `themeModeFromBrightness`, and the legacy
      // `AppSettings.themeMode` flag is never read — so the toggle
      // activates the opposite-brightness *default* preset (the WaveCrux
      // model; see WaveCrux's theme_brightness_toggle.dart). Activation
      // flows through the SimCrux color-theme notifier
      // (simcrux_color_theme_bootstrap.dart), which persists
      // `activeThemeName` so the choice survives a restart.
      SimcruxAction.toggleTheme: () {
        final current = ref.read(cruxColorThemeProvider);
        final presets = builtinPresets();
        final next = current.brightness == Brightness.dark
            ? presets[cruxLightPresetId]!
            : presets[cruxDarkPresetId]!;
        ref.read(cruxColorThemeProvider.notifier).activate(next);
      },
      // Split-pane actions. Fire-and-forget —
      // mutations resolve quickly against the in-memory
      // workspace; the autosave debounce handles persistence.
      SimcruxAction.splitPaneRight: () => unawaited(
        ref.read(workspaceProvider.notifier).splitPaneRight(),
      ),
      SimcruxAction.closePane: () {
        final ws = ref.read(workspaceProvider).value;
        if (ws == null || ws.panes.length < 2) return;
        unawaited(
          ref.read(workspaceProvider.notifier).closePane(ws.activePaneId),
        );
      },
      SimcruxAction.focusOtherPane: () => unawaited(
        ref.read(workspaceProvider.notifier).focusOtherPane(),
      ),
      SimcruxAction.moveTabToOtherPane: () {
        final ws = ref.read(workspaceProvider).value;
        if (ws == null || ws.panes.length < 2) return;
        final activeTabId = ws.activeTabId;
        if (activeTabId == null) return;
        final otherPane = ws.panes
            .firstWhere((p) => p.id != ws.activePaneId)
            .id;
        unawaited(
          ref
              .read(workspaceProvider.notifier)
              .moveTabToPane(activeTabId, otherPane),
        );
      },
      // ── Navigate ──────────────────────────────────────────
      // No entries: the two focus stubs that lived here were removed with
      // their actions. F6 / Shift+F6 region traversal is the keyboard
      // navigation SimCrux ships, and it is handled by the focus system,
      // not by a dispatchable action.
      // ── Search ────────────────────────────────────────────
      SimcruxAction.openSearch: () {
        final ctx = navigatorContext();
        if (ctx == null) return;
        // Search the ACTIVE tab's regression config (test / suite /
        // simulator); Enter or a click selects the test in the shared
        // per-tab selection provider. Falls back to a no-op when no tab
        // is mounted (nothing to search).
        final tabContainer = activeTabContainer();
        if (tabContainer == null) return;
        unawaited(SimcruxSearchDialog.open(ctx, tabContainer));
      },
      // ── Tools / Help ─────────────────────────────────────
      SimcruxAction.openSettings: () {
        final ctx = navigatorContext();
        if (ctx == null) return;
        // The suite-shared Settings shell (crux_settings_ui): same clamped
        // modal dialog, title row, close x, and non-dismissible barrier as
        // the other three Crux apps. Note: barrierDismissible:false also
        // disables Escape (Flutter routes the DismissIntent through the
        // barrier flag) — closing is the x button, deliberately.
        // ModalGuard: Cmd/Ctrl+, auto-repeat or a double-tap on the menu /
        // palette entry must not stack a second settings surface. Guarded
        // here because SimCrux has no static SettingsScreen opener — this
        // dispatch is the single open path.
        unawaited(
          ModalGuard.run(
            'settings',
            () => openCruxSettings(
              ctx,
              title: L10N.of(ctx).settingsTitle,
              closeTooltip: L10N.of(ctx).dialogClose,
              asDialog: isDesktopPlatform,
              bodyBuilder: (_) => const SettingsBody(),
            ),
          ),
        );
      },
      SimcruxAction.openAbout: () {
        final ctx = navigatorContext();
        if (ctx != null) {
          unawaited(SimcruxAboutDialog.openAdaptive(ctx, ref));
        }
      },
      // Tab Diagnostics (suite UI-consistency pass) — opens the per-tab
      // drawer as a WaveCrux-style non-modal OverlayEntry. The opener
      // resolves the active tab's container itself (and follows the
      // active tab thereafter), so no container is passed here.
      SimcruxAction.openTabDiagnostics: () {
        final ctx = navigatorContext();
        if (ctx == null) return;
        if (activeTabContainer() == null) {
          _snackInfo(ctx, (l10n) => l10n.snackNoProjectOpen);
          return;
        }
        unawaited(TabDiagnosticsDrawer.open(ctx));
      },
      // App Diagnostics. The dialog shipped without an opener, so the only
      // thing that ever mounted it was a widget test.
      SimcruxAction.openAppDiagnostics: () {
        final ctx = navigatorContext();
        if (ctx != null) {
          unawaited(AppDiagnosticsDialog.show(ctx));
        }
      },
      // Manual update check. Always runs — `checkNow()` ignores the
      // Settings → General auto-check toggle by contract. The outcome
      // surfaces as a snackbar ("up to date" / "couldn't check"); an
      // available update surfaces through the persistent `UpdateBanner`
      // rather than a second toast. Needs a navigator-side context for
      // `ScaffoldMessenger.of`.
      SimcruxAction.checkForUpdates: () {
        final ctx = navigatorContext();
        if (ctx != null) {
          // ModalGuard at the dispatch site (the helper lives in the shared
          // `crux_updates` package): a repeated gesture must not run two
          // overlapping checks.
          unawaited(
            ModalGuard.run(
              'checkForUpdates',
              () => runManualUpdateCheck(ctx, ref),
            ),
          );
        }
      },
      // Beta issue reporter — modal on desktop, pushed route on mobile
      // (SimCrux ships desktop + web only, so always the modal).
      // `openAdaptive` invalidates the session-context provider first, so
      // every report carries a fresh snapshot.
      SimcruxAction.submitIssue: () {
        final ctx = navigatorContext();
        if (ctx != null) {
          // ModalGuard at the dispatch site (the opener lives in the shared
          // `crux_issue_reporter` package), mirroring WaveCrux.
          unawaited(
            ModalGuard.run(
              'issueReporter',
              () => CruxIssueReporterDialog.openAdaptive(ctx),
            ),
          );
        }
      },
      // Documentation — hands docs.simcrux.app to the platform browser
      // through a swappable seam so widget tests need no url_launcher
      // channel.
      SimcruxAction.openDocumentation: () {
        unawaited(simcruxLaunchUrl(Uri.parse(HelpUrls.docs)));
      },
      SimcruxAction.openCrossProbePanel: () {
        // The cross-probe surface is a right-dock tab. Toggle the
        // feature; turning it on reveals its tab (opening the right region
        // if hidden) — the same reveal semantics as the other products.
        final willShow = !ref.read(crossProbeVisibleProvider);
        ref.read(crossProbeVisibleProvider.notifier).toggle();
        if (willShow) {
          ref
              .read(rightDockTabProvider.notifier)
              .reveal(kRightDockTabCrossProbe);
        }
      },
      SimcruxAction.openSeedFailureHeatmap: () {
        // Open-core ships the action so it stays discoverable
        // in the command palette / menu inventory; the screen
        // lives behind [seedFailureHeatmapOpenerProvider],
        // which the Pro overlay registers in `proOverrides`.
        final ctx = navigatorContext();
        final opener = ref.read(seedFailureHeatmapOpenerProvider);
        if (opener == null || ctx == null) {
          _snackProGated(ctx, SimcruxAction.openSeedFailureHeatmap);
          return;
        }
        opener(ctx);
      },
      // Trend tracking openers. Open-core
      // builds register the actions and dispatch through the
      // opener provider; the Pro overlay's `proOverrides`
      // installs the concrete openers (which in turn
      // FeatureGate-check before mounting the screens).
      SimcruxAction.showTrendChart: () {
        final ctx = navigatorContext();
        final opener = ref.read(perTestTrendChartOpenerProvider);
        if (opener == null || ctx == null) {
          _snackProGated(ctx, SimcruxAction.showTrendChart);
          return;
        }
        opener(ctx);
      },
      SimcruxAction.showSuiteTrendChart: () {
        final ctx = navigatorContext();
        final opener = ref.read(perSuiteTrendChartOpenerProvider);
        if (opener == null || ctx == null) {
          _snackProGated(ctx, SimcruxAction.showSuiteTrendChart);
          return;
        }
        opener(ctx);
      },
      SimcruxAction.showCalendarHeatmap: () {
        final ctx = navigatorContext();
        final opener = ref.read(calendarHeatmapOpenerProvider);
        if (opener == null || ctx == null) {
          _snackProGated(ctx, SimcruxAction.showCalendarHeatmap);
          return;
        }
        opener(ctx);
      },
      // The Flaky Tests panel's activation entry
      // point. Open-core builds register the action for
      // discoverability; the Pro overlay's `proOverrides` installs
      // the concrete opener (which FeatureGate-checks before
      // mounting the panel).
      SimcruxAction.showFlakyTests: () {
        final ctx = navigatorContext();
        final opener = ref.read(flakyTestsPanelOpenerProvider);
        if (opener == null || ctx == null) {
          _snackProGated(ctx, SimcruxAction.showFlakyTests);
          return;
        }
        opener(ctx);
      },
      SimcruxAction.configureRetentionPolicy: () {
        final ctx = navigatorContext();
        final opener = ref.read(retentionPolicySettingsOpenerProvider);
        if (opener == null || ctx == null) {
          _snackProGated(ctx, SimcruxAction.configureRetentionPolicy);
          return;
        }
        opener(ctx);
      },
      // PR annotation. Open core ships
      // only NoopPrAnnotationDispatcher and NoopPrAnnotationTargetStore,
      // so both openers are null here and the Pro-gated snack is the
      // correct response. The Pro overlay registers a real target store,
      // a Settings section and a dispatch opener, so a Pro user reaches
      // the feature rather than a snack.
      SimcruxAction.configurePrAnnotationTarget: () {
        final ctx = navigatorContext();
        final opener = ref.read(prAnnotationSettingsOpenerProvider);
        if (opener == null || ctx == null) {
          _snackProGated(ctx, SimcruxAction.configurePrAnnotationTarget);
          return;
        }
        opener(ctx);
      },
      SimcruxAction.dispatchPrAnnotations: () {
        final ctx = navigatorContext();
        final opener = ref.read(prAnnotationDispatchOpenerProvider);
        if (opener == null || ctx == null) {
          _snackProGated(ctx, SimcruxAction.dispatchPrAnnotations);
          return;
        }
        opener(ctx);
      },
      // Plugin SDK surfaces. Open-core ships
      // only NoopSimulatorDriverPluginRegistry, so the null
      // opener default correctly surfaces the Pro-gated snack;
      // the Pro overlay overrides both openers with the real
      // Settings → Plugins panel + directory re-scan.
      SimcruxAction.openPluginManager: () {
        final ctx = navigatorContext();
        final opener = ref.read(pluginManagerOpenerProvider);
        if (opener == null || ctx == null) {
          _snackProGated(ctx, SimcruxAction.openPluginManager);
          return;
        }
        opener(ctx);
      },
      SimcruxAction.reloadPlugins: () {
        final ctx = navigatorContext();
        final opener = ref.read(reloadPluginsOpenerProvider);
        if (opener == null || ctx == null) {
          _snackProGated(ctx, SimcruxAction.reloadPlugins);
          return;
        }
        opener(ctx);
      },
      // ── Multi-project ─────────────────────────────────────
      SimcruxAction.switchProject: () {
        final ctx = navigatorContext();
        final opener = ref.read(projectSwitcherOpenerProvider);
        if (opener == null || ctx == null) {
          _snackProGated(ctx, SimcruxAction.switchProject);
          return;
        }
        opener(ctx);
      },
      // Recents exist only in the Pro registry — the open-core
      // NoopProjectRegistry clears them by construction, so an
      // open-core dispatch here could only ever report "no recent
      // projects", which contradicts the PRO badge the palette and
      // menu bar render beside the entry. Route through the seam so
      // open-core says "requires SimCrux Pro" and the Pro overlay's
      // opener gates before reopening.
      SimcruxAction.reopenRecentProject: () {
        final ctx = navigatorContext();
        final opener = ref.read(reopenRecentProjectOpenerProvider);
        if (opener == null || ctx == null) {
          _snackProGated(ctx, SimcruxAction.reopenRecentProject);
          return;
        }
        opener(ctx);
      },
      // Pins live only in the Pro registry: the open-core
      // NoopProjectRegistry records the active tab but pins nothing, so a
      // direct toggle here changed no state and said nothing. Route through
      // the seam like the other registry actions; the Pro overlay's opener
      // gates, then toggles the pin.
      SimcruxAction.pinActiveProject: () {
        final ctx = navigatorContext();
        final opener = ref.read(pinActiveProjectOpenerProvider);
        if (opener == null || ctx == null) {
          _snackProGated(ctx, SimcruxAction.pinActiveProject);
          return;
        }
        opener(ctx);
      },
      SimcruxAction.searchAcrossProjects: () {
        final ctx = navigatorContext();
        final opener = ref.read(crossProjectSearchOpenerProvider);
        if (opener == null || ctx == null) {
          _snackProGated(ctx, SimcruxAction.searchAcrossProjects);
          return;
        }
        opener(ctx);
      },
    };
    // Wire Cmd+Shift+P to open the command palette. Selecting
    // an action from the palette dispatches through the same
    // handlers map above. Actions without a handler entry
    // still appear in the palette so the keybinding surface
    // stays discoverable; selecting them is a no-op until
    // their handler lands.
    handlers[SimcruxAction.openCommandPalette] = () {
      final ctx = navigatorContext();
      if (ctx == null) return;
      unawaited(
        CommandPaletteDialog.show(
          ctx,
          onAction: (action) => handlers[action]?.call(),
        ),
      );
    };
    return handlers;
  }

  /// File → Close All Tabs — confirms, then closes every open
  /// workspace tab.
  ///
  /// The open-core tab-closing capability: no project registry, no
  /// pinning, no recents. The action is destructive and reachable from
  /// the menu and command palette, so it confirms first. When [context]
  /// is null the navigator has not mounted and there is nothing to
  /// close from.
  static Future<void> _closeAllTabs(
    BuildContext? context,
    WidgetRef ref,
  ) async {
    if (context == null || !context.mounted) return;
    final l10n = L10N.of(context);
    final confirmed = await showConfirmDialog(
      context: context,
      title: l10n.closeAllTabsConfirmTitle,
      body: l10n.closeAllTabsConfirmBody,
      cancelLabel: l10n.closeAllTabsConfirmCancel,
      confirmLabel: l10n.closeAllTabsConfirmConfirm,
    );
    if (!confirmed) return;

    final ws = ref.read(workspaceProvider).value;
    if (ws == null) return;
    final notifier = ref.read(workspaceProvider.notifier);
    for (final tab in ws.tabs) {
      await notifier.closeTab(tab.id);
    }
  }

  /// File → Open Project — picks a `simcrux.yaml` or a
  /// `<design>.crux-project` manifest and opens it as a new workspace tab.
  /// Mirrors the empty-canvas Open Config button, including its manifest
  /// resolution and feedback.
  static Future<void> _openProjectFromPicker(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final FilePickerResult? result;
    try {
      result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['yaml', 'yml', kCruxProjectExtension],
      );
    } on Object {
      return;
    }
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;
    await openConfigAsTab(
      ref: ref,
      context: context.mounted ? context : null,
      rawPath: path,
      source: 'yaml',
    );
  }

  /// File → Import FuseSoC `.core` File — runs the importer, writes
  /// the synthesized `simcrux.yaml` next to the source, and opens
  /// that file as a new workspace tab.
  static Future<void> _importFusesocFromPicker(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final FilePickerResult? result;
    try {
      result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['core'],
      );
    } on Object {
      return;
    }
    if (result == null || result.files.isEmpty) return;
    final corePath = result.files.single.path;
    if (corePath == null) return;
    String? outPath;
    String? failure;
    var warningCount = 0;
    try {
      final imported = await FuseSoCImporter().importFile(corePath);
      warningCount = imported.warnings.length;
      outPath = p.join(
        File(corePath).parent.path,
        imported.suggestedOutputFilename,
      );
      // Whether this path is already open decides how the tab is
      // refreshed below — check before the write, not after.
      final wasAlreadyOpen =
          ref
              .read(workspaceProvider)
              .value
              ?.tabs
              .any((t) => t.payload.configPath == outPath) ??
          false;
      await File(outPath).writeAsString(imported.simcruxYaml);
      unawaited(
        ref.read(appSettingsProvider.notifier).addRecentProject(outPath),
      );
      // Inside the try, after the write: an import that threw produced no
      // project to open, and counting it would answer "how often is the
      // importer reached" rather than "does the FuseSoC importer earn its
      // maintenance".
      ref.read(telemetryServiceProvider).record(projectOpenedEvent('fusesoc'));
      await ref
          .read(workspaceProvider.notifier)
          .openTab(
            displayName: p.basename(outPath),
            payload: SimcruxTabPayload(configPath: outPath),
          );
      if (wasAlreadyOpen) {
        // `openTab` de-dupes on the config path: it activated the tab it
        // found and returned, and that tab keeps the config it parsed the
        // first time — `RegressionTabContent` only arms a load when its
        // `activeConfigProvider` is still null. The file underneath was
        // just rewritten, so re-read it explicitly. Without this, a second
        // import of the same core looks like it did nothing at all.
        _activeTabContainer(ref)
            ?.read(regressionRunnerProvider.notifier)
            .startFromConfigPath(outPath)
            .ignore();
      }
    } on Object catch (e) {
      failure = '$e';
    }
    if (!context.mounted) return;
    final l10n = L10N.of(context);
    if (failure != null) {
      showCruxErrorSnack(context, l10n.fusesocImportFailed(failure));
    } else if (outPath != null) {
      showCruxInfoSnack(
        context,
        warningCount > 0
            ? l10n.fusesocImportSuccessWithWarnings(outPath, warningCount)
            : l10n.fusesocImportSuccess(outPath),
      );
    }
  }

  /// Resolves the active tab's per-tab [ProviderContainer].
  ///
  /// Mirrors the closure the run/cancel actions use. The dashboard
  /// providers (`regressionRunnerProvider`, `activeConfigProvider`, …)
  /// are per-tab overrides, so reading them from the root container
  /// would hit a different instance with no loaded config.
  static ProviderContainer? _activeTabContainer(WidgetRef ref) {
    final id = ref.read(workspaceProvider).value?.activeTabId;
    if (id == null) return null;
    try {
      return ref.read(workspaceContainerManagersProvider).tabs.containerFor(id);
    } on Object {
      // Not bound — headless tests, pre-hydration startup.
      return null;
    }
  }

  /// File → Import RISC-V Architectural Tests / Import riscv-formal Checks
  /// — enumerates the picked tree into one SimCrux test per architectural
  /// test (or per bounded proof), writes the synthesized `simcrux.yaml`
  /// where the user says, and opens it as a workspace tab.
  ///
  /// ## Two pickers, not one, and not a dialog
  ///
  /// Unlike the FuseSoC flow — which writes next to the `.core` file it
  /// read — an input here is a directory inside somebody else's git
  /// checkout (`riscv-arch-test`, riscv-formal). Writing a generated file
  /// into it would show up as untracked in their `git status`, or fail
  /// outright on a read-only checkout. So the source directory and the
  /// destination file are two separate picks. A bespoke import-options
  /// dialog would have been the third option and was rejected: it is a new
  /// shared-chrome surface, which suite UI consistency would then require
  /// in all four apps, for two flags the CLI already exposes.
  ///
  /// ## The one input this cannot supply
  ///
  /// `riscv.target.command` — the command that runs the user's own core for
  /// one architectural test — is required by the loader in `mode: normal`
  /// and is unknowable from a checkout. The importer raises
  /// `missing_target_command` for it, this handler surfaces the warning
  /// count, and the emitted YAML names it in its header comment. Scripted
  /// users pass `--target-command` to
  /// `simcrux import-riscv-arch-test` instead and get a config that loads
  /// with no edits.
  static Future<void> _importRiscvFromPicker(
    BuildContext context,
    WidgetRef ref,
    RiscvImportKind kind,
  ) async {
    final String? sourceDir;
    try {
      sourceDir = await FilePicker.getDirectoryPath();
    } on Object {
      return;
    }
    if (sourceDir == null) return;

    // Enumerate BEFORE asking where to save: a wrong-directory pick is the
    // common mistake, and there is no reason to make the user name an
    // output file for an import that was never going to produce one.
    String? failure;
    RiscvImportResult? imported;
    try {
      imported = switch (kind) {
        RiscvImportKind.archTest => RiscvArchTestImporter().importSuite(
          suitePath: sourceDir,
        ),
        RiscvImportKind.formal => RiscvFormalCheckImporter().importChecks(
          checksPath: sourceDir,
        ),
      };
    } on Object catch (e) {
      failure = '$e';
    }
    if (failure != null || imported == null) {
      if (!context.mounted) return;
      showCruxErrorSnack(
        context,
        L10N.of(context).riscvImportFailed(failure ?? ''),
      );
      return;
    }

    final String? outPath;
    try {
      outPath = await FilePicker.saveFile(
        // file_picker 12 requires bytes and writes the file itself; pass
        // empty so it only returns the chosen path and the real content is
        // written below. Same shape as the keymap export picker.
        bytes: Uint8List(0),
        fileName: imported.suggestedOutputFilename,
        allowedExtensions: const ['yaml', 'yml'],
        type: FileType.custom,
      );
    } on Object {
      return;
    }
    if (outPath == null) return;

    try {
      await File(outPath).writeAsString(imported.simcruxYaml);
      unawaited(
        ref.read(appSettingsProvider.notifier).addRecentProject(outPath),
      );
      // One token for both RISC-V importers. Which of the two the user reached
      // for is a question the telemetry does not ask, and splitting it would put
      // two near-identical rows on a dashboard for no decision either would
      // change.
      ref.read(telemetryServiceProvider).record(projectOpenedEvent('riscv'));
      await ref
          .read(workspaceProvider.notifier)
          .openTab(
            displayName: p.basename(outPath),
            payload: SimcruxTabPayload(configPath: outPath),
          );
    } on Object catch (e) {
      failure = '$e';
    }
    if (!context.mounted) return;
    final l10n = L10N.of(context);
    if (failure != null) {
      showCruxErrorSnack(context, l10n.riscvImportFailed(failure));
      return;
    }
    if (imported.warnings.isEmpty) {
      showCruxInfoSnack(
        context,
        l10n.riscvImportSuccess(imported.testCount, outPath),
      );
      return;
    }
    // Warnings are not a failure — the file was written and opened — but
    // `missing_target_command` means the config will not load until the
    // user fills in how to run their core, so it must not be silent.
    showCruxErrorSnack(
      context,
      l10n.riscvImportSuccessWithWarnings(
        imported.testCount,
        outPath,
        imported.warnings.length,
      ),
    );
  }

  // There is deliberately no "not yet implemented" snack helper either. Its
  // only two callers were the focus stubs, and a helper that exists to make
  // an unimplemented action *look* dispatched is how those survived a UI
  // consistency pass: hiding them from the menu and palette left the chords
  // bound, so the notice was all the user ever got. An action that cannot do
  // its job should not ship, bound or otherwise. Like
  // `snackActionNotAvailableYet`, the `snackActionNotYetImplemented` ARB key
  // is retained in all five locales against a future genuine stub.

  /// Snackbar shown when an action's extension-point opener provider is
  /// null — the overlay that supplies the screen is not installed.
  ///
  /// The message is selected from the action's own
  /// [SimcruxAction.requiredTier] so the snack can never contradict the
  /// tier badge the palette and menu bar render for the same action:
  /// a Pro-tier action says "requires SimCrux Pro", an open-core-tier
  /// action whose opener simply is not wired in this build says so
  /// without making a tier claim.
  static void _snackProGated(BuildContext? context, SimcruxAction action) {
    if (context == null || !context.mounted) return;
    final l10n = L10N.of(context);
    final label = action.label(l10n);
    showCruxInfoSnack(
      context,
      action.requiredTier == LicenseTier.openCore
          ? l10n.snackActionUnavailableInThisBuild(label)
          : l10n.snackActionRequiresPro(label),
    );
  }

  // There is deliberately no "not available yet" snack helper: every
  // action is reachable in some tier, and an unused not-available-yet
  // snack is an invitation to ship an unreachable action. The
  // `snackActionNotAvailableYet` ARB key is retained in all five locales —
  // it costs nothing and a future genuine deferral should not have to
  // re-translate it.

  /// Drains in-flight regressions through [appExitCoordinatorProvider]
  /// and then terminates via [processExitProvider].
  ///
  /// Exit code stays 0 even when the drain times out: the user asked to
  /// quit, and a wedged simulator is not a failure of the quit itself.
  /// The reap is best-effort by construction — see
  /// [AppExitCoordinator.kDefaultShutdownGrace].
  static Future<void> _quit(WidgetRef ref) async {
    await ref.read(appExitCoordinatorProvider).shutdown();
    ref.read(processExitProvider)(0);
  }

  /// Shows a plain informational snackbar (e.g. "No recent projects.").
  /// Takes a message builder rather than a resolved string so callers can
  /// stay `L10N`-free until the null/mounted guard below has run.
  static void _snackInfo(
    BuildContext? context,
    String Function(L10N l10n) message,
  ) {
    if (context == null || !context.mounted) return;
    final l10n = L10N.of(context);
    showCruxInfoSnack(context, message(l10n));
  }
}
