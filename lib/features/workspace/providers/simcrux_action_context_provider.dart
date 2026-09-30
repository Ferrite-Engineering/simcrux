// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/core/shortcuts/simcrux_action_context.dart';
import 'package:simcrux/domain/models/dashboard_row.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/dashboard/providers/regression_runner.dart';
import 'package:simcrux/features/diagnostics/providers/diagnostics_enabled_provider.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/features/workspace/providers/container_managers.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';

/// Root-scope mirror of the **active tab's** per-tab gating flags.
///
/// The action-discovery surfaces (menu bar, command palette, toolbar) and the
/// keyboard dispatch path evaluate enablement at the root scope and cannot
/// `ref.watch` a tab container's providers, so this re-emits the active tab's
/// config / run / results / selection state up to the root. Mirrors NetCrux's
/// and LintCrux's providers of the same name.
@immutable
class ActiveTabActionFlags {
  /// Creates a flags snapshot. Defaults describe an empty tab.
  const ActiveTabActionFlags({
    this.hasConfig = false,
    this.runInProgress = false,
    this.hasResults = false,
    this.hasSelectedTest = false,
  });

  /// Whether the active tab has a loaded regression config.
  final bool hasConfig;

  /// Whether a regression is executing in the active tab.
  final bool runInProgress;

  /// Whether the active tab's dashboard has at least one row.
  final bool hasResults;

  /// Whether a test row is selected in the active tab.
  final bool hasSelectedTest;

  /// Returns a copy with the given fields replaced.
  ActiveTabActionFlags copyWith({
    bool? hasConfig,
    bool? runInProgress,
    bool? hasResults,
    bool? hasSelectedTest,
  }) => ActiveTabActionFlags(
    hasConfig: hasConfig ?? this.hasConfig,
    runInProgress: runInProgress ?? this.runInProgress,
    hasResults: hasResults ?? this.hasResults,
    hasSelectedTest: hasSelectedTest ?? this.hasSelectedTest,
  );

  @override
  bool operator ==(Object other) =>
      other is ActiveTabActionFlags &&
      other.hasConfig == hasConfig &&
      other.runInProgress == runInProgress &&
      other.hasResults == hasResults &&
      other.hasSelectedTest == hasSelectedTest;

  @override
  int get hashCode =>
      Object.hash(hasConfig, runInProgress, hasResults, hasSelectedTest);
}

/// See [ActiveTabActionFlags].
final activeTabActionFlagsProvider =
    NotifierProvider<ActiveTabActionFlagsNotifier, ActiveTabActionFlags>(
      ActiveTabActionFlagsNotifier.new,
      name: 'activeTabActionFlagsProvider',
    );

/// Rebinds to the active tab's container whenever the active tab changes,
/// subscribing to each mirrored per-tab provider and re-emitting its gating
/// projection.
class ActiveTabActionFlagsNotifier extends Notifier<ActiveTabActionFlags> {
  bool _disposed = false;

  /// Applies [update] to the *current* [state] on a microtask.
  ///
  /// The mirrored providers are `container.listen`ed and one can notify while
  /// the widget tree is mid-build — writing `state` there throws. Applying to
  /// the live `state` keeps a batch of listeners firing in one tick from
  /// clobbering one another.
  void _apply(ActiveTabActionFlags Function(ActiveTabActionFlags) update) {
    scheduleMicrotask(() {
      if (_disposed) return;
      final next = update(state);
      if (next != state) state = next;
    });
  }

  @override
  ActiveTabActionFlags build() {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    final activeTabId = ref.watch(
      workspaceProvider.select((ws) => ws.value?.activeTabId),
    );
    if (activeTabId == null) return const ActiveTabActionFlags();

    // The managers provider throws when unbound (its default is an explicit
    // UnsupportedError telling the host to override it in bootstrap). Widget
    // tests that never bind it still build this notifier, so treat "unbound"
    // as "no tab available" rather than exploding a menu render.
    final ProviderContainer container;
    try {
      container = ref
          .watch(workspaceContainerManagersProvider)
          .tabs
          .containerFor(activeTabId);
    } on Object {
      return const ActiveTabActionFlags();
    }

    bool running(AsyncValue<RegressionRunState?> run) {
      final value = run.value;
      return value != null && !value.isFinished;
    }

    final subs = <ProviderSubscription<Object?>>[
      container.listen<RegressionConfig?>(
        activeConfigProvider,
        (_, next) => _apply((s) => s.copyWith(hasConfig: next != null)),
      ),
      container.listen<AsyncValue<RegressionRunState?>>(
        regressionRunnerProvider,
        (_, next) => _apply((s) => s.copyWith(runInProgress: running(next))),
      ),
      container.listen<AsyncValue<List<DashboardRow>>>(
        dashboardRowsProvider,
        (_, next) => _apply(
          (s) => s.copyWith(hasResults: next.value?.isNotEmpty ?? false),
        ),
      ),
      container.listen<SelectedTest?>(
        selectedTestProvider,
        (_, next) => _apply((s) => s.copyWith(hasSelectedTest: next != null)),
      ),
    ];
    for (final sub in subs) {
      ref.onDispose(sub.close);
    }

    return ActiveTabActionFlags(
      hasConfig: container.read(activeConfigProvider) != null,
      runInProgress: running(container.read(regressionRunnerProvider)),
      hasResults:
          container.read(dashboardRowsProvider).value?.isNotEmpty ?? false,
      hasSelectedTest: container.read(selectedTestProvider) != null,
    );
  }
}

/// Builds the [SimcruxActionContext] every action-discovery surface and the
/// keyboard dispatch path feed to the descriptor selectors in
/// `simcrux_action_descriptors.dart`. Centralizing it here guarantees all
/// surfaces gate on identical state. Tests override this provider directly
/// with a literal context to drive a surface into a precise state.
final simcruxActionContextProvider = Provider<SimcruxActionContext>((ref) {
  final workspace = ref.watch(workspaceProvider).value;
  final flags = ref.watch(activeTabActionFlagsProvider);
  return SimcruxActionContext(
    hasOpenTab: workspace?.activeTabId != null,
    hasConfig: flags.hasConfig,
    runInProgress: flags.runInProgress,
    hasResults: flags.hasResults,
    hasSelectedTest: flags.hasSelectedTest,
    diagnosticsEnabled: ref.watch(diagnosticsEnabledProvider),
    paneCount: workspace?.panes.length ?? 1,
    tabCountInActivePane: workspace == null
        ? 0
        : workspace.tabsForPane(workspace.activePaneId).length,
  );
}, name: 'simcruxActionContextProvider');
