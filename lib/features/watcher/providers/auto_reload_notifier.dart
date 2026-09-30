// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:crux_settings/crux_settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/domain/enums/regression_trigger.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/dashboard/providers/regression_runner.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/watcher/providers/auto_reload_arming_coordinator.dart';
import 'package:simcrux/services/watcher/suite_source_watcher.dart';

/// State surfaced by [autoReloadNotifierProvider].
///
/// `prompt` mode keeps a buffer of pending change events so the UI
/// can render a snackbar listing what changed; `auto` mode drains the
/// buffer immediately; `off` mode never fills it.
class AutoReloadState {
  /// Creates an [AutoReloadState].
  const AutoReloadState({
    this.pendingPaths = const <String>{},
    this.lastRerunAt,
  });

  /// Distinct file paths that have changed since the last rerun.
  /// In `prompt` mode this powers the snackbar's "N file changed"
  /// indicator; in `auto` mode the set is drained on every event so
  /// it is always empty between rerun ticks.
  final Set<String> pendingPaths;

  /// Most recent rerun trigger timestamp (used by tests + the
  /// diagnostics dashboard).
  final DateTime? lastRerunAt;

  /// Returns a copy with the given fields replaced.
  AutoReloadState copyWith({
    Set<String>? pendingPaths,
    DateTime? lastRerunAt,
  }) => AutoReloadState(
    pendingPaths: pendingPaths ?? this.pendingPaths,
    lastRerunAt: lastRerunAt ?? this.lastRerunAt,
  );
}

/// The auto-rerun controller — owns the [SuiteSourceWatcher] and
/// reacts to events according to the user's [AutoReloadMode]
/// setting.
///
/// Lifecycle:
///
/// - Build: watches both [activeConfigProvider] and the user's
///   [AppSettings.autoReloadMode]. Re-arms the file watcher whenever
///   either changes.
/// - Event: when a watched file fires `modified` or `deleted`:
///   * `off`: do nothing.
///   * `auto`: re-run the active suite immediately.
///   * `prompt`: append the path to [AutoReloadState.pendingPaths]
///     so the UI can show a snackbar. The user accepts (calls
///     `rerun()`) or dismisses (calls `dismiss()`).
final NotifierProvider<AutoReloadNotifier, AutoReloadState>
autoReloadNotifierProvider =
    NotifierProvider<AutoReloadNotifier, AutoReloadState>(
      AutoReloadNotifier.new,
    );

/// Notifier backing [autoReloadNotifierProvider].
class AutoReloadNotifier extends Notifier<AutoReloadState> {
  SuiteSourceWatcher? _watcher;
  StreamSubscription<SuiteSourceChange>? _subscription;

  /// The project key (config path) this notifier is registered under with
  /// the arming coordinator, or null when it has no active config.
  String? _armedKey;

  /// Factory hook for tests. Production wires the default
  /// `SuiteSourceWatcher` constructor.
  SuiteSourceWatcher Function() watcherFactory = SuiteSourceWatcher.new;

  /// Resolved once in [build]; captured because `ref.read` is illegal
  /// inside the [_release] dispose callback where it is also needed.
  late final AutoReloadArmingCoordinator _coordinator;

  @override
  AutoReloadState build() {
    _coordinator = ref.read(autoReloadArmingCoordinatorProvider);
    ref
      ..onDispose(_release)
      ..listen(activeConfigProvider, (_, _) => _rearm())
      ..listen(appSettingsProvider, (_, _) => _rearm());
    _rearm();
    return const AutoReloadState();
  }

  /// Elects this notifier as the single armer for the active project (via
  /// the root [AutoReloadArmingCoordinator]) and, when elected, arms the
  /// file watcher. A second tab of the same project registers as a standby
  /// and does not arm — so one source edit fires one rerun, not one per
  /// tab. On a project change the previous key is released, which promotes
  /// a standby tab (if any) to arm in this one's place.
  void _rearm() {
    final config = ref.read(activeConfigProvider);
    final newKey = config?.projectFilePath;
    if (_armedKey != null && _armedKey != newKey) {
      _coordinator.unregister(_armedKey!, this);
      _armedKey = null;
    }
    _disposeWatcher();
    if (config == null || newKey == null) return;
    _armedKey = newKey;
    final active = _coordinator.register(newKey, this, _armIfElected);
    if (active) _armWatcher(config);
  }

  /// Coordinator promotion callback: fired when a previously-active tab
  /// released this project and this notifier is now the elected armer.
  void _armIfElected() {
    final config = ref.read(activeConfigProvider);
    if (config == null) return;
    _armWatcher(config);
  }

  void _armWatcher(RegressionConfig config) {
    _disposeWatcher();
    final watcher = watcherFactory();
    _watcher = watcher;
    _subscription = watcher.events.listen(_onChange);
    watcher.watch(config);
  }

  /// Releases the coordinator registration and disposes the watcher.
  /// Runs on notifier disposal (tab close), so a standby tab is promoted.
  void _release() {
    if (_armedKey != null) {
      _coordinator.unregister(_armedKey!, this);
      _armedKey = null;
    }
    _disposeWatcher();
  }

  void _disposeWatcher() {
    unawaited(_subscription?.cancel());
    _subscription = null;
    _watcher?.dispose();
    _watcher = null;
  }

  void _onChange(SuiteSourceChange change) {
    final mode = ref
        .read(appSettingsProvider)
        .maybeWhen<AutoReloadMode>(
          data: (s) => s.autoReloadMode,
          orElse: () => AutoReloadMode.prompt,
        );
    switch (mode) {
      case AutoReloadMode.off:
        return;
      case AutoReloadMode.auto:
        _enqueueAndRerun(change.path);
      case AutoReloadMode.prompt:
        state = state.copyWith(
          pendingPaths: <String>{...state.pendingPaths, change.path},
        );
    }
  }

  void _enqueueAndRerun(String path) {
    state = AutoReloadState(
      pendingPaths: <String>{...state.pendingPaths, path},
    );
    unawaited(rerun());
  }

  /// Re-runs the active regression and clears the pending-paths set.
  ///
  /// Used both by the `auto` path (called from `_enqueueAndRerun`)
  /// and by the snackbar's "Re-run now" button (in `prompt` mode).
  ///
  /// The rerun re-reads the project file from disk via
  /// [RegressionRunner.startFromConfigPath] rather than re-running the
  /// in-memory [activeConfigProvider] parse. The watcher fires precisely
  /// because the file changed on disk (its mtime moved), so re-running the
  /// pre-edit parse would silently execute stale config — the very edit
  /// that triggered the reload would be ignored.
  Future<void> rerun() async {
    final config = ref.read(activeConfigProvider);
    if (config == null) return;
    state = state.copyWith(
      pendingPaths: const <String>{},
      lastRerunAt: DateTime.now().toUtc(),
    );
    await ref
        .read(regressionRunnerProvider.notifier)
        // The one non-default trigger in the GUI: this is what makes
        // `regression.completed{trigger}` able to answer "does auto-reload get
        // used at all", which is otherwise invisible — an auto-reloaded run
        // and a hand-started one are identical by the time they reach the
        // scheduler. Note the snackbar's "Re-run now" button also lands here,
        // and is counted as `auto` deliberately: it is the watcher's prompt
        // mode, so it measures the same adoption.
        .startFromConfigPath(
          config.projectFilePath,
          trigger: RegressionTrigger.auto,
        );
  }

  /// Clears the pending-paths set without re-running (snackbar
  /// "Dismiss" button).
  void dismiss() {
    state = state.copyWith(pendingPaths: const <String>{});
  }
}
