// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:crux_workspace/crux_workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/dashboard/providers/regression_runner.dart';
import 'package:simcrux/features/dashboard/widgets/dashboard_view.dart';
import 'package:simcrux/features/panel_layout/widgets/simcrux_ide_layout.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/statistics/widgets/simcrux_stats_strip.dart';
import 'package:simcrux/features/watcher/providers/auto_reload_notifier.dart';
import 'package:simcrux/features/watcher/widgets/auto_reload_snackbar_host.dart';
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';
import 'package:simcrux/features/workspace/widgets/regression_status_bar.dart';
import 'package:simcrux/features/workspace/widgets/simcrux_docks.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// Per-tab dashboard scaffold. Sits inside crux_workspace's PaneHost
/// IndexedStack — each tab's payload supplies the config-file path the
/// regression runner targets.
///
/// Lifecycle on first build inside a per-tab `ProviderContainer`:
///
/// 1. Read the tab's [SimcruxTabPayload] from [WorkspaceTab.payload].
/// 2. If `payload.configPath` is non-empty and the per-tab
///    [activeConfigProvider] is still null (the tab has never been
///    armed), kick the per-tab [regressionRunnerProvider] to load the
///    config. The runner publishes it to [activeConfigProvider] and the
///    dashboard rebuilds — but the regression itself does **not** start
///    unless the user has turned on `autoRunOnOpen`, which is off by
///    default by design. Opening a config arms a tab; running
///    it is a separate, deliberate act.
/// 3. Render the SimcruxIdeLayout with the dashboard in the center pane
///    and the inspector in the right pane — the per-tab regression view,
///    parented to the per-tab Riverpod scope.
///
/// When `payload.configPath` is empty, renders a placeholder inviting
/// the user to pick a config file. No live UI path creates such a tab
/// anymore (the empty-tab "+" and "New Config" affordances were
/// removed); this stays as defensive handling for restored state.
class RegressionTabContent extends ConsumerStatefulWidget {
  /// Creates a [RegressionTabContent] for the given [tab].
  const RegressionTabContent({required this.tab, super.key});

  /// The workspace tab whose payload this content widget targets.
  final WorkspaceTab<SimcruxTabPayload> tab;

  @override
  ConsumerState<RegressionTabContent> createState() =>
      _RegressionTabContentState();
}

class _RegressionTabContentState extends ConsumerState<RegressionTabContent> {
  bool _kicked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeKickRunner());
  }

  @override
  void didUpdateWidget(covariant RegressionTabContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tab.payload.configPath != widget.tab.payload.configPath) {
      // The tab's payload changed (e.g. user picked a config from the
      // placeholder); re-arm.
      _kicked = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeKickRunner());
    }
  }

  void _maybeKickRunner() {
    if (_kicked) return;
    if (!mounted) return;
    final path = widget.tab.payload.configPath;
    if (path.isEmpty) return;
    final existingConfig = ref.read(activeConfigProvider);
    if (existingConfig != null) {
      _kicked = true;
      return;
    }
    _kicked = true;
    unawaited(_loadConfig(path));
  }

  Future<void> _loadConfig(String path) async {
    // Opening a config *arms* the tab; it does not start the regression
    // unless the user has opted in: opening a file must not launch two
    // hundred tests, which in a real setup also checks out simulator licences
    // on a misclick.
    final autoStart = await _autoRunOnOpen();
    if (!mounted) return;
    await ref
        .read(regressionRunnerProvider.notifier)
        .startFromConfigPath(path, autoStart: autoStart);
  }

  /// The user's `autoRunOnOpen` preference, defaulting to `false`.
  ///
  /// Prefers the already-loaded settings, and only falls back to reading the
  /// service when they have not arrived yet — which on a command-line launch
  /// is the common case, and where a plain `?? false` would silently ignore
  /// the preference of every user who did opt in.
  ///
  /// It reads the *service* rather than awaiting `appSettingsProvider.future`
  /// on purpose: awaiting an async provider here would hand this path to
  /// Riverpod's failure retry, and a settings load with no platform channel
  /// behind it would leave the tab loading forever. Failure resolves to
  /// `false` — never start a run the user did not ask for.
  Future<bool> _autoRunOnOpen() async {
    final cached = ref.read(appSettingsProvider).value;
    if (cached != null) return cached.autoRunOnOpen;
    try {
      final settings = await ref.read(settingsServiceProvider).load();
      return settings.autoRunOnOpen;
    } on Object {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10N.of(context);
    final config = ref.watch(activeConfigProvider);
    final loadError = ref.watch(configLoadErrorProvider);
    // Make sure the file watcher is armed whenever the per-tab config
    // is loaded. autoReloadNotifierProvider lives in the per-tab scope
    // because it ref.listens activeConfigProvider; each tab's watcher
    // is independent (`per_tab_auto_reload_test.dart` verifies this).
    ref
      ..watch(autoReloadNotifierProvider)
      // A failed load is spoken as well as drawn. The error pane never takes
      // focus and desktop screen readers ignore live regions, so without
      // this a broken config sounded exactly like one still loading.
      ..listen<ConfigLoadError?>(configLoadErrorProvider, (previous, next) {
        if (next == null || next == previous) return;
        if (next.path != widget.tab.payload.configPath) return;
        final strings = L10N.of(context);
        announceCrux(
          context,
          '${strings.configLoadFailedTitle}\n'
          '${strings.configLoadFailedDetail(next.path, next.message)}',
          assertive: true,
        );
      });

    if (widget.tab.payload.configPath.isEmpty) {
      return Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                l10n.projectScreenPlaceholder,
                style: Theme.of(context).textTheme.bodyLarge,
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      );
    }

    // No AppBar, and no toolbar either: the toolbar is app-level chrome now,
    // mounted once in `WorkspaceScreen` above the PaneHost. Building it here
    // put one toolbar *inside every tab*, so a split pane rendered two
    // side-by-side strips and closing the last tab took the strip with it —
    // the only product in the suite that did either.
    //
    // The Tab Diagnostics drawer is no longer a Scaffold end-drawer here:
    // it opens as a non-modal OverlayEntry via `TabDiagnosticsDrawer.open`
    // (Cmd/Ctrl+Shift+I / Tools menu / palette — suite UI-consistency
    // pass), scoped to the active tab's container by the opener.
    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: config == null
                // Before the IDE layout exists the tab's body is its main
                // surface, so lost focus comes back here.
                ? CruxFocusRegion(
                    primary: true,
                    child: _loadingOrErrorBody(context, l10n, loadError),
                  )
                : AutoReloadSnackbarHost(
                    // The shared cross-probe panel docks as a fixed-width
                    // side panel on the far right of the IDE layout when
                    // `crossProbeVisibleProvider` is set (toolbar toggle /
                    // action / its own close chevron). Its own `ProviderScope`
                    // is this per-tab scope, so its controller reads the active
                    // tab's selection.
                    // Each region is a CruxDock: Tests and Log render as
                    // titled headers (the auto-hiding strip); the right dock
                    // tabs Details with the on-demand Cross-Probe panel — the
                    // CXP panel moved inside the layout, off its old fixed
                    // 340 px bolt-on Row.
                    child: SimcruxIdeLayout(
                      testBrowserBuilder: (_) => const SimcruxLeftDock(),
                      runResultsBuilder: (_) => const DashboardView(),
                      runDetailsBuilder: (_) => const SimcruxRightDock(),
                      logPanelBuilder: (_) => const SimcruxBottomDock(),
                    ),
                  ),
          ),
          // The bottom chrome is one keyboard region (an F6 stop). The IDE
          // layout above supplies its own regions, so this is not nested in
          // one.
          CruxFocusRegion(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Live statistics strip. Docks ABOVE the status
                // bar: the status bar is identity ("which config am I looking
                // at"), the strip is ambient telemetry, and telemetry sitting
                // below identity would put the least-durable information
                // closest to the window edge. Collapsed by default, so it
                // costs one 24 px disclosure row until the user asks for it.
                const SimcruxStatsStrip(),
                // Tab-spanning bottom status bar: surfaces the config
                // file identity the top band omits + a compact run
                // summary, on the shared cross-suite CruxStatusBar chrome.
                RegressionStatusBar(configPath: widget.tab.payload.configPath),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Body shown when `activeConfigProvider` is null. Two states:
  ///
  /// 1. A load error was recorded for this tab's `configPath` —
  ///    render the failing path and the loader's reason verbatim so
  ///    the user can fix the YAML (or pick a different file).
  /// 2. No error yet — the loader is still in-flight, so show a
  ///    transient "Loading…" message instead of a stale empty state.
  Widget _loadingOrErrorBody(
    BuildContext context,
    L10N l10n,
    ConfigLoadError? loadError,
  ) {
    final theme = Theme.of(context);
    if (loadError != null && loadError.path == widget.tab.payload.configPath) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.error_outline,
                  size: 48,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(height: 16),
                Text(
                  l10n.configLoadFailedTitle,
                  style: theme.textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                SelectableText(
                  l10n.configLoadFailedDetail(
                    loadError.path,
                    loadError.message,
                  ),
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(
                l10n.configLoadingPlaceholder,
                style: theme.textTheme.bodyLarge,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
