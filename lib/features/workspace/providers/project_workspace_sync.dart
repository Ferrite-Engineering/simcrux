// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_projects/crux_projects.dart';
import 'package:crux_workspace/crux_workspace.dart' as crux;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';

/// Two-way glue between the crux_workspace tab surface (what the user
/// actually sees) and the [ProjectRegistry] (recents / pins / project
/// switcher / cross-project search).
///
/// Before this service existed the two systems were fully
/// disconnected: opening a config via File → Open added a workspace
/// tab but the registry never learned about it (so the switcher /
/// recents / pins operated on a registry that reflected nothing), and
/// registry-driven actions (switcher selection, recents Reopen,
/// `reopenRecentProject`) mutated the registry without changing the
/// displayed content — the switcher was effectively hollow.
///
/// **Convergence model.** Both listeners only *kick* a single
/// serialized convergence loop — handler bodies never run
/// concurrently, which rules out the interleaving livelock a
/// per-event handler design allows (two in-flight handlers alternating
/// activation between an old and a new snapshot forever). Each pass
/// reads the *current* state of both sides (never stale event
/// payloads) and applies:
///
/// 1. **Registry-originated closures** (delta vs the previous *settled*
///    registry snapshot — NOT plain absence, which is ambiguous at boot
///    where the registry's first emission can arrive before the
///    recorder has registered restored tabs): close the matching
///    workspace tab.
/// 2. **Registry-originated activation** (active project changed since
///    the previous settled snapshot and disagrees with the active tab):
///    activate the matching tab, opening it when none exists —
///    switcher selection, recents Reopen, `reopenRecentProject`.
/// 3. **Recorder** (workspace tabs are otherwise the authority):
///    record unrecorded config tabs as open projects, close registry
///    projects whose tab is gone (→ recents), align the registry's
///    active project to the active tab.
///
/// "Previous settled snapshot" in steps 1–2 is deliberate: [_lastRegistryWs]
/// is only committed *after* this pass's own registry mutations (3a/3b/3c)
/// have run, from the post-mutation `registry.current` — never from the
/// pre-mutation read taken at the top of the pass. Comparing against a
/// pre-mutation snapshot would make steps 1–2 misread this sync's own prior
/// recorder action as an external change on the very next pass (see the
/// long comment in [_convergeOnce]).
///
/// A pass that performs no action means the two sides agree; the loop
/// re-runs while kicks arrived mid-pass and is hard-capped as a
/// belt-and-braces guarantee against livelock.
///
/// **Open-core semantics.** Under [NoopProjectRegistry] — a strict
/// replace-on-open, single-project registry — the recorder degrades to
/// single-project bookkeeping (only the active tab is ever recorded) once
/// [_singleProjectRegistry] auto-detects that mode, and steps 1–2 are
/// naturally no-ops in steady state.
///
/// **Registry contract this loop relies on.** The recorder `await`s
/// `registry.openProject` / `closeProject` / `setActiveProject` inline, so
/// the [ProjectRegistry] returned by `projectRegistryProvider` MUST resolve
/// those futures in bounded time and MUST honor any call made against the
/// instance this loop reads. A registry override that hands out a
/// short-lived buffering proxy at boot and then swaps in a *different*
/// instance once it finishes hydrating (stranding the boot pass's buffered
/// `openProject` on the discarded proxy) will hang this loop's `await`
/// forever — `_running` stays true and no later kick can converge. The
/// open-core [NoopProjectRegistry] is synchronous and stable, so it is
/// immune; the Pro deferred-registry override must attach its hydrated
/// delegate to the *same* proxy this loop already called (the Pro
/// overlay's registry override does).
///
/// Realized for the app's lifetime from `lib/app.dart`'s provider
/// anchor (alongside the CXP emitters).
class ProjectWorkspaceSync {
  /// Creates the sync and installs both listeners.
  ///
  /// fireImmediately so restored state on both sides (the crux
  /// workspace file and the Pro registry's workspace.json) converges
  /// at boot instead of waiting for the first user mutation.
  ProjectWorkspaceSync.start(this._ref) {
    _ref
      ..listen(
        workspaceProvider,
        (_, _) => _kick(),
        fireImmediately: true,
      )
      ..listen(
        projectWorkspaceProvider,
        (_, _) => _kick(),
        fireImmediately: true,
      );
  }

  final Ref _ref;

  /// Previous registry snapshot; used to detect registry-originated
  /// closures / activation as deltas.
  ProjectWorkspace? _lastRegistryWs;

  /// Detected replace-on-open (single-project) registry semantics —
  /// the open-core [NoopProjectRegistry]. Recording every tab into
  /// such a registry would alternate forever (each open replaces the
  /// previous), so once detected the recorder mirrors only the
  /// *active* tab, which is exactly the single-project contract.
  bool _singleProjectRegistry = false;

  bool _running = false;
  bool _dirty = false;

  /// Hard cap on convergence passes per kick burst. The equality
  /// guards make each pass idempotent once the sides agree, so this
  /// should never be reached — it exists purely to bound the damage
  /// of a future bug to "sync gives up" instead of "app livelocks".
  static const int _maxPasses = 8;

  void _kick() {
    if (_running) {
      _dirty = true;
      return;
    }
    _running = true;
    // Fire-and-forget: the loop owns its own error handling.
    // ignore: discarded_futures
    _runLoop();
  }

  Future<void> _runLoop() async {
    try {
      var passes = 0;
      bool acted;
      do {
        _dirty = false;
        acted = await _convergeOnce();
        passes++;
      } while ((acted || _dirty) && passes < _maxPasses);
    } on Object {
      // Best-effort glue — a convergence failure must never take the
      // app down. The next mutation kicks a fresh loop.
    } finally {
      _running = false;
      if (_dirty) _kick();
    }
  }

  /// One state-based convergence pass. Returns true when it performed
  /// at least one mutation (the loop then re-checks for agreement).
  Future<bool> _convergeOnce() async {
    final ws = _ref.read(workspaceProvider).value;
    if (ws == null) return false;
    final registry = _ref.read(projectRegistryProvider);
    final regNow = registry.current;
    final regPrev = _lastRegistryWs;
    final notifier = _ref.read(workspaceProvider.notifier);

    // [_lastRegistryWs] is only committed in the `finally` block below,
    // from `registry.current` AFTER this pass's own registry mutations
    // (3a/3b/3c) have run — never from the pre-mutation `regNow` above.
    //
    // Committing the pre-mutation snapshot here (the original design)
    // created a self-inflicted-change bug: say this pass's 3a recorder
    // records tab B, replacing tab A in a replace-on-open registry (see
    // [_singleProjectRegistry]). The *next* pass would then compare its
    // `regNow` (= {B}) against a stale `regPrev` (= {A}, captured before
    // B was recorded) and misread its own prior action as an external
    // change — step 1 sees A "disappear" and closes A's live workspace
    // tab out from under the user; step 2 sees the active project
    // "change" from A to B and forces the *workspace's* active tab back
    // to A, undoing the very activation that made B active in the first
    // place. Committing the post-mutation snapshot means the next pass's
    // `regPrev` already reflects this pass's own work, so only a
    // genuinely external registry change (switcher click, recents
    // Reopen, direct `ProjectRegistry` API use) produces a delta.
    try {
      var acted = false;

      // Tab inventory (empty-canvas tabs carry an empty configPath and
      // are not projects).
      final tabByPath = <String, crux.TabId>{};
      String? activeTabPath;
      for (final tab in ws.tabs) {
        final path = tab.payload.configPath;
        if (path.isEmpty) continue;
        tabByPath[path] = tab.id;
        if (tab.id == ws.activeTabId) activeTabPath = path;
      }

      final openByPath = <String, String>{
        for (final d in regNow.openProjects) d.projectPath: d.id,
      };

      // 1. Registry-originated closures (delta vs previous *settled*
      //    snapshot).
      if (regPrev != null) {
        for (final d in regPrev.openProjects) {
          if (openByPath.containsKey(d.projectPath)) continue;
          final tabId = tabByPath[d.projectPath];
          if (tabId != null) {
            await notifier.closeTab(tabId);
            acted = true;
          }
        }
        if (acted) return true; // Re-read fresh state next pass.
      }

      // 2. Registry-originated activation (active project changed since
      //    the previous settled snapshot and the tabs don't reflect it
      //    yet).
      final active = regNow.activeProject;
      final registryActivationChanged =
          regPrev != null && regNow.activeProjectId != regPrev.activeProjectId;
      if (registryActivationChanged &&
          active != null &&
          activeTabPath != active.projectPath) {
        final tabId = tabByPath[active.projectPath];
        if (tabId != null) {
          await notifier.setActiveTab(tabId);
        } else {
          await notifier.openTab(
            displayName: p.basename(active.projectPath),
            payload: SimcruxTabPayload(configPath: active.projectPath),
          );
        }
        return true;
      }

      // 3a. Recorder: unrecorded config tabs → open projects. In
      //     single-project mode (see [_singleProjectRegistry]) only the
      //     active tab is mirrored.
      final toRecord = _singleProjectRegistry
          ? <String>[
              if (activeTabPath != null &&
                  !openByPath.containsKey(activeTabPath))
                activeTabPath,
            ]
          : <String>[
              for (final path in tabByPath.keys)
                if (!openByPath.containsKey(path)) path,
            ];
      // Detect replace-on-open (single-project) registries incrementally,
      // one `openProject` call at a time: recording a path must never
      // shrink the registry's open set below "everything already known
      // to be open, plus everything recorded so far in this loop". A
      // NoopProjectRegistry keeps only the most recently opened path, so
      // its open-project count stalls at 1 as soon as a second distinct
      // path is recorded — that stall is the single-project signal.
      // Checking after every call (rather than once after the whole
      // loop) catches the common one-tab-at-a-time real-usage pattern,
      // where each tab open lands in its own convergence pass and
      // `toRecord` never has more than one entry.
      var recordedSoFar = 0;
      for (final path in toRecord) {
        await registry.openProject(path);
        acted = true;
        recordedSoFar++;
        if (!_singleProjectRegistry) {
          final expectedMinOpen = openByPath.length + recordedSoFar;
          if (registry.current.openProjects.length < expectedMinOpen) {
            _singleProjectRegistry = true;
          }
        }
      }
      if (acted) return true;

      // 3b. Recorder: registry projects whose tab is gone → close
      //     (moves into the registry's recents so Reopen surfaces work).
      for (final entry in openByPath.entries) {
        if (!tabByPath.containsKey(entry.key)) {
          await registry.closeProject(entry.value);
          acted = true;
        }
      }
      if (acted) return true;

      // 3c. Recorder: align the registry's active project to the active
      //     tab (equality-guarded).
      if (activeTabPath != null) {
        final wantedId = openByPath[activeTabPath];
        if (wantedId != null && wantedId != regNow.activeProjectId) {
          await registry.setActiveProject(wantedId);
          return true;
        }
      }

      return false;
    } finally {
      _lastRegistryWs = registry.current;
    }
  }
}

/// App-lifetime provider realizing the sync. Anchored from
/// `lib/app.dart` alongside the CXP emitters so both listeners are
/// installed at boot.
final Provider<ProjectWorkspaceSync> projectWorkspaceSyncProvider =
    Provider<ProjectWorkspaceSync>(ProjectWorkspaceSync.start);
