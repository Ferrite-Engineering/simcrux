// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_workspace/crux_workspace.dart' as crux;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_view_mode_provider.dart';
import 'package:simcrux/features/dashboard/providers/regression_runner.dart';
import 'package:simcrux/features/inspector/providers/inspector_log_provider.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/features/watcher/providers/auto_reload_notifier.dart';
import 'package:simcrux/services/re_run_query/re_run_query_service_provider.dart';
import 'package:simcrux/services/result_store/result_store_provider.dart';

/// Function shape returned by [simcruxTabOverridesFactoryProvider] and
/// passed to `crux.TabContainerManager(overridesFactory: …)`. Each
/// freshly-created per-tab `ProviderContainer` calls it once with the
/// tab's [crux.TabId] and applies the returned list on top of the
/// root container.
typedef SimcruxTabOverridesFactory = List<Override> Function(crux.TabId);

/// Extension-point seam for the per-tab overrides factory.
///
/// **Open-core default.** Returns [simcruxTabOverrides] — the per-tab
/// list below, which gives each tab its own NotifierProvider instances
/// for dashboard filter / sort / selection / activeConfig / result
/// store / regression runner / auto-reload. Open-core's
/// [`NoopProjectRegistry`] is single-project, so per-tab isolation is
/// the only mechanism keeping two tabs (each with their own
/// `SimcruxTabPayload.configPath`) from sharing state.
///
/// **Pro override.** The Pro overlay's multi-project workspace
/// replaces this with a factory that
/// splits the providers two ways (see the Pro `proTabOverrides`):
///
/// - **Shared per project, not per tab:** filter, sort, selection,
///   activeConfig, result store, and trend store are bound to root
///   per-project family delegates keyed off `activeProjectIdProvider`,
///   so two tabs viewing the same project share that state while
///   different projects stay isolated.
/// - **Still per tab:** view state (dashboard view mode, selected test,
///   inspector log providers) *and* the regression runner and
///   auto-reload notifier remain per-tab overrides — each tab owns its
///   own in-flight scheduler subscription and its own source watcher.
///
/// The runner and auto-reload are per-tab in both open-core and Pro;
/// what Pro changes is that their per-tab instances resolve the
/// tab's-project delegates rather than fully independent state.
///
/// The factory provider is consulted once at app boot when
/// [`crux.TabContainerManager`] is constructed; the resolved function
/// is then used for every per-tab container during the session. Tests
/// that need to inject a different factory override this provider
/// before reading [`workspaceContainerManagersProvider`].
final Provider<SimcruxTabOverridesFactory> simcruxTabOverridesFactoryProvider =
    Provider<SimcruxTabOverridesFactory>((_) => simcruxTabOverrides);

/// Produces the SimCrux-specific per-tab Riverpod override list applied
/// on top of the `crux_workspace` package's [`crux.tabIdProvider`] when
/// the framework creates a fresh per-tab `ProviderContainer`.
///
/// Each override forces the referenced provider to materialize inside
/// the per-tab container rather than the root container, so per-tab
/// mutations stay scoped to their owning tab. Two kinds of provider
/// appear here:
///
/// 1. **Leaf state owners** (NotifierProviders) — `activeConfigProvider`,
///    `resultStoreProvider`, the dashboard filter / sort / selection /
///    view-mode notifiers, `selectedTestIdProvider`, and the
///    `regressionRunnerProvider` that owns the in-flight job-scheduler
///    state. Each tab carries an independent instance so that, for
///    example, switching tabs does not surface tab A's selection in
///    tab B's inspector.
/// 2. **Derived providers** (StreamProvider/Provider/family) —
///    `dashboardRowsProvider`, `dashboardTotalsProvider`,
///    `selectedTestProvider`, `inspectorLogSnapshotProvider`,
///    `fullInspectorLogProvider`. Derived providers must be overridden
///    at the same level as the providers they `ref.watch`; otherwise
///    Riverpod resolves the derived provider in the root container,
///    where the per-tab dependencies are not visible. The body of each
///    derived provider is exported as a top-level function so the
///    override and the original declaration share the same
///    implementation.
///
/// App-level providers stay in the root scope and are intentionally NOT
/// overridden here:
///
/// - `simulatorDriverRegistryProvider` — one registry of bundled simulator
///   drivers per app.
/// - `trendStoreProvider` — the SQLite trend store handle is global;
///   per-test queries are scoped through query parameters.
/// - `appSettingsProvider`, `licenseTierProvider`, `panelLayoutProvider`,
///   recent configs — settings and licensing are app-wide.
///
/// Scheduler concurrency is not in either list because nothing holds it
/// as shared state: each run carries its own `concurrency` and the
/// scheduler bounds it with a per-run semaphore, so N tabs running at once
/// can spawn up to N times that many simulators. There is no process-wide
/// pool.
List<Override> simcruxTabOverrides(crux.TabId tabId) {
  return <Override>[
    // ── Leaf per-tab state owners ─────────────────────────────────────
    activeConfigProvider.overrideWith(ActiveConfigNotifier.new),
    // Per-tab config-load error. Written by the per-tab
    // regressionRunnerProvider's `startFromConfigPath` failure path and
    // watched by the tab's RegressionTabContent — without this override
    // the notifier materializes at root, so tab A's broken-YAML banner
    // renders in tab B and a later tab's load clears tab A's error.
    configLoadErrorProvider.overrideWith(ConfigLoadErrorNotifier.new),
    resultStoreProvider.overrideWith(ResultStoreNotifier.new),
    dashboardFilterProvider.overrideWith(DashboardFilterNotifier.new),
    dashboardSortProvider.overrideWith(DashboardSortNotifier.new),
    dashboardSelectionProvider.overrideWith(DashboardSelectionNotifier.new),
    dashboardViewModeProvider.overrideWith(DashboardViewModeNotifier.new),
    selectedTestIdProvider.overrideWith(SelectedTestNotifier.new),
    regressionRunnerProvider.overrideWith(RegressionRunner.new),
    // Per-tab auto-reload notifier. Each tab gets its
    // own SuiteSourceWatcher arming against the per-tab
    // activeConfigProvider; only the tab(s) whose sources changed
    // re-run their regression. The cross-suite AutoReloadMode setting
    // stays root-scoped (app-wide); each tab's notifier reads it
    // through Riverpod's parent-lookup.
    autoReloadNotifierProvider.overrideWith(AutoReloadNotifier.new),

    // ── Derived providers (must materialize inside the per-tab scope) ─
    // Re-run query service: resolves specs/results against the per-tab
    // resultStoreProvider, so it must materialize in the same scope.
    reRunQueryServiceProvider.overrideWith(reRunQueryService),
    dashboardRowsProvider.overrideWith(dashboardRows),
    dashboardTotalsProvider.overrideWith(dashboardTotals),
    selectedTestProvider.overrideWith(selectedTest),
    inspectorLogSnapshotProvider.overrideWith(inspectorLogSnapshot),
    fullInspectorLogProvider.overrideWith(fullInspectorLog),
  ];
}
