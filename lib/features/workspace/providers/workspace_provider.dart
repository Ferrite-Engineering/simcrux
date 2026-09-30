// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_telemetry/crux_telemetry.dart';
import 'package:crux_workspace/crux_workspace.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';
import 'package:simcrux/features/workspace/services/simcrux_workspace_codec.dart';

/// Service-level provider exposing the underlying
/// [`crux_workspace`](https://github.com/Ferrite-Engineering/crux-shared)
/// [WorkspaceService] for SimCrux.
///
/// Override in tests to inject a `WorkspaceService` constructed against
/// a temp directory factory so the auto-managed `workspace.json` does
/// not leak across test runs.
final Provider<WorkspaceService<SimcruxTabPayload>>
simcruxWorkspaceServiceProvider = Provider<WorkspaceService<SimcruxTabPayload>>(
  (ref) => WorkspaceService<SimcruxTabPayload>(
    codec: const SimcruxWorkspaceCodec(),
  ),
);

/// SimCrux's [WorkspaceNotifier] subclass.
///
/// Inherits the full package mutation API directly (`openTab` /
/// `closeTab` / `reorderTab` / `moveTabToPane` / `setActiveTab` /
/// `setActivePane` / `splitPaneRight` / `closePane` / `focusOtherPane` /
/// `resetWorkspace` / `updateTabPayload` / `updateTabDisplayName` /
/// `replaceWith` / `saveAs` / `loadFrom` / `flushPendingSave`). No
/// SimCrux-named wrappers — consumers call the package methods directly;
/// backward-compat wrappers would only duplicate the package surface.
///
/// The subclass exists to keep the type slot reserved for CXP-emitter
/// wiring (the `notify_selection` emitter needs
/// somewhere to hook in without bouncing through a provider listen
/// chain) and so product-specific telemetry can override individual
/// mutation methods without forcing every consumer to switch to a
/// shim.
///
/// Construction binds the service late so [build] can resolve the
/// underlying [simcruxWorkspaceServiceProvider] through `ref` — Riverpod
/// resolves deps inside `build`, not at construction time.
class SimcruxWorkspaceNotifier extends WorkspaceNotifier<SimcruxTabPayload> {
  /// Creates a notifier wired through [simcruxWorkspaceServiceProvider].
  ///
  /// The shim resolves the real service on first `build` so test
  /// overrides on [simcruxWorkspaceServiceProvider] take effect
  /// transparently.
  SimcruxWorkspaceNotifier({this.restoreGate})
    : super(service: _LateBoundService());

  /// Replaces the settings-backed launch gate when non-null.
  ///
  /// Two injectors use it: `bootstrap()` under `--no-restore` (a
  /// `() async => false` gate skips this launch's workspace rehydration
  /// without touching the persisted preference or the document on disk),
  /// and tests that need a deterministic gate without stubbing the whole
  /// settings stack. Mirrors `NetcruxWorkspaceNotifier.restoreGate`.
  final Future<bool> Function()? restoreGate;

  /// `workspace.restored` is a **once-per-notifier** event, not a
  /// once-per-`build` one: Riverpod rebuilds this notifier whenever a
  /// dependency changes, and a counter that ticked on every rebuild would
  /// report session restores that never happened.
  bool _emittedRestored = false;

  /// Records through the seam **resolved now**, never through one captured in
  /// [build].
  ///
  /// It was held in a field because the notifier outlives individual mutations
  /// and `ref.read` is forbidden from the disposal path some of them run
  /// through — which the `ref.mounted` guard covers directly. What holding it
  /// cost is why it is gone: `telemetryServiceProvider` is not constant for the
  /// life of a session. The consent store publishes `unset` synchronously and
  /// reads the persisted value back asynchronously, so at the moment this
  /// notifier builds — a cold start — the gate has not seen the user's stored
  /// answer yet and resolves the no-op. Caching that froze the first frame's
  /// verdict for the whole session.
  void _emit(String name, [Map<String, Object?>? properties]) {
    if (!ref.mounted) return;
    ref
        .read(telemetryServiceProvider)
        .record(TelemetryEvent(name, properties: properties));
  }

  /// `tab.opened` with the post-mutation shape of the workspace.
  ///
  /// The counts answer "how many projects do people keep open at once", which
  /// is what sizes the tab strip. Nothing about *which* projects — the tab's
  /// payload is a config path, and a path is a file name, which telemetry
  /// never carries.
  void _emitTabOpened() {
    final ws = state.value;
    if (ws == null) return;
    _emit('tab.opened', {'tabs': ws.tabs.length, 'panes': ws.panes.length});
  }

  @override
  Future<Workspace<SimcruxTabPayload>> build() async {
    (service as _LateBoundService).real = ref.read(
      simcruxWorkspaceServiceProvider,
    );
    final loaded = await super.build();
    if (!_emittedRestored) {
      _emittedRestored = true;
      _emit(
        'workspace.restored',
        {'tabs': loaded.tabs.length, 'panes': loaded.panes.length},
      );
    }
    return loaded;
  }

  // ── Telemetry-bearing overrides of package methods ─────────────────────────
  //
  // The package owns the mutations; SimCrux owns the counters. Each override
  // below delegates first and records second, and each records only when the
  // mutation actually happened — `closePane` on the sole pane and
  // `splitPaneRight` on an already-split workspace are both no-ops in the
  // package, and a counter that ticked on them would be counting clicks
  // rather than splits.

  @override
  Future<TabId> openTab({
    required String displayName,
    required SimcruxTabPayload payload,
    PaneId? paneId,
    bool dedupe = true,
  }) async {
    final before = state.value?.tabs.length ?? 0;
    final id = await super.openTab(
      displayName: displayName,
      payload: payload,
      paneId: paneId,
      dedupe: dedupe,
    );
    // `dedupe` turns "open the project that is already open" into an
    // activation. That is not a tab opening, and counting it would inflate the
    // number against which the tab-strip sizing question is answered.
    if ((state.value?.tabs.length ?? 0) > before) _emitTabOpened();
    return id;
  }

  @override
  Future<PaneId> splitPaneRight() async {
    final before = state.value?.panes.length ?? 0;
    final id = await super.splitPaneRight();
    if ((state.value?.panes.length ?? 0) > before) _emit('pane.split');
    return id;
  }

  @override
  Future<void> closePane(PaneId paneId) async {
    final before = await future;
    final willClose =
        before.panes.length >= 2 && before.panes.any((p) => p.id == paneId);
    await super.closePane(paneId);
    if (willClose) _emit('pane.closed');
  }

  // `resetWorkspace` carries no counter here, and `saveAs` carries none at
  // all. SimCrux's only reset path is `bootstrap`'s `--reset` flag, which
  // clears the document through the *service* before this notifier exists —
  // so `workspace.reset` is recorded there, from the container, rather than
  // from an override nothing calls. And SimCrux has no "Save Workspace As" or
  // "New Workspace" action at all, so `workspace.named.saved` and
  // `workspace.created` are absent from `kSimcruxEventCatalog` rather than
  // instrumented into a method with no caller: a counter wired to an
  // unreachable path reads, on a dashboard, exactly like a feature nobody
  // uses.

  @override
  Future<Workspace<SimcruxTabPayload>> loadFrom(String path) async {
    final loaded = await super.loadFrom(path);
    _emit(
      'workspace.named.opened',
      {'tabs': loaded.tabs.length, 'panes': loaded.panes.length},
    );
    return loaded;
  }

  /// Honours the user's `restoreTabsOnLaunch` preference.
  ///
  /// The base class awaits this before reading `workspace.json`, so a `false`
  /// here means the document is never loaded rather than loaded and then
  /// closed tab by tab. The document is left on disk untouched, so turning
  /// the preference back on brings the session back.
  ///
  /// Reads through [settingsServiceProvider] rather than awaiting
  /// [appSettingsProvider]`.future`: awaiting another async *provider* here
  /// hands the launch path to Riverpod's failure retry, so a settings load
  /// that throws (no platform channel under `flutter test`, a plugin that has
  /// not registered yet) leaves this future pending across every retry and
  /// the workspace never resolves at all. The service is a plain future that
  /// either completes or throws once.
  @override
  Future<bool> shouldRestoreOnLaunch() async {
    final injected = restoreGate;
    if (injected != null) return injected();
    try {
      final settings = await ref.read(settingsServiceProvider).load();
      return settings.restoreTabsOnLaunch;
    } on Object {
      // Settings unreadable — corrupt store, missing plugin. Restoring is the
      // safe answer: discarding the user's session because a *preference* was
      // unreadable turns a small failure into a large one.
      return true;
    }
  }
}

/// Bridges the package's "service-at-construction" lifecycle with
/// Riverpod's "deps-resolved-in-build" lifecycle.
///
/// `WorkspaceNotifier` takes its [WorkspaceService] in the super
/// constructor and stores it in a `final` field; Riverpod can't resolve
/// the real service until [build] runs. This shim delegates every call
/// to a service supplied via [bind] once `build` is running. Mirrors
/// WaveCrux's identically-named shim from its Session 6 workspace
/// adoption.
class _LateBoundService extends WorkspaceService<SimcruxTabPayload> {
  _LateBoundService() : super(codec: const SimcruxWorkspaceCodec());

  WorkspaceService<SimcruxTabPayload>? _real;

  // The shim is one-way: the late-bound `real` reference is consumed
  // internally by `_r()` and never read by external callers; only the
  // setter is part of the contract.
  // ignore: avoid_setters_without_getters
  set real(WorkspaceService<SimcruxTabPayload> service) => _real = service;

  WorkspaceService<SimcruxTabPayload> _r() {
    final r = _real;
    if (r == null) {
      throw StateError(
        '_LateBoundService used before real= was set in '
        'SimcruxWorkspaceNotifier.build',
      );
    }
    return r;
  }

  @override
  Future<Workspace<SimcruxTabPayload>> load() => _r().load();

  @override
  Future<void> save(Workspace<SimcruxTabPayload> workspace) =>
      _r().save(workspace);

  @override
  Future<void> saveToPath(
    String path,
    Workspace<SimcruxTabPayload> workspace,
  ) => _r().saveToPath(path, workspace);

  @override
  Future<Workspace<SimcruxTabPayload>> loadFromPath(String path) =>
      _r().loadFromPath(path);

  @override
  Future<void> clear() => _r().clear();

  @override
  Future<String?> sidecarPathFor(
    String tabId, {
    String extension = '.json',
  }) => _r().sidecarPathFor(tabId, extension: extension);

  @override
  Future<void> deleteSidecar(
    String tabId, {
    String extension = '.json',
  }) => _r().deleteSidecar(tabId, extension: extension);
}

/// SimCrux's workspace AsyncNotifierProvider.
///
/// Manually declared (not `@Riverpod`-generated) because the notifier
/// extends the package's `WorkspaceNotifier<P>` base — Dart's single-
/// inheritance constraint means the riverpod_generator base
/// (`_$SimcruxWorkspaceNotifier extends $AsyncNotifier<Workspace<P>>`)
/// is not available. Manual declaration matches WaveCrux's identical
/// design choice from its Session 6 workspace adoption.
final AsyncNotifierProvider<
  SimcruxWorkspaceNotifier,
  Workspace<SimcruxTabPayload>
>
workspaceProvider =
    AsyncNotifierProvider<
      SimcruxWorkspaceNotifier,
      Workspace<SimcruxTabPayload>
    >(SimcruxWorkspaceNotifier.new);
