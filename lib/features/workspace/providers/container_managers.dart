// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_workspace/crux_workspace.dart' as crux;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Holder for the per-tab and per-pane `ProviderContainer` managers.
///
/// Constructed once at app startup in `app.dart` (via
/// `crux.TabContainerManager(rootContainer: ..., overridesFactory: ...)`)
/// and supplied to `PaneHost` so it can spin up per-tab and per-pane
/// containers as the workspace mutates. The managers themselves are
/// not Riverpod providers — they outlive every Riverpod scope and are
/// what the per-tab / per-pane `UncontrolledProviderScope` reads from.
///
/// Tests construct their own `WorkspaceContainerManagers` against a
/// disposable root container; production wires it once from
/// `bootstrap` and never disposes it (the manager is dropped when the
/// app exits).
class WorkspaceContainerManagers {
  /// Creates a holder pairing a tab + pane manager.
  WorkspaceContainerManagers({required this.tabs, required this.panes});

  /// Per-tab `ProviderContainer` manager. Disposes each tab's
  /// container when the tab is closed.
  final crux.TabContainerManager tabs;

  /// Per-pane `ProviderContainer` manager. Disposes each pane's
  /// container when the pane closes.
  final crux.PaneContainerManager panes;

  /// Tears down every tab and pane container. Production calls this on
  /// app shutdown; tests should call it from `tearDown` to release the
  /// per-tab Riverpod state.
  void dispose() {
    tabs.dispose();
    panes.dispose();
  }
}

/// Provider exposing the active [WorkspaceContainerManagers].
///
/// Bound at app startup in `bootstrap()` via
/// `workspaceContainerManagersProvider.overrideWithValue(...)` so the
/// PaneHost (and any other consumer that needs to spin up per-tab
/// containers) can read the singleton. Throws when read without an
/// override — the open-core entry point and every test must supply
/// their own managers (parented to whichever root container the test
/// has built).
final Provider<WorkspaceContainerManagers> workspaceContainerManagersProvider =
    Provider<WorkspaceContainerManagers>(
      (ref) => throw UnsupportedError(
        'workspaceContainerManagersProvider must be overridden in bootstrap(); '
        'tests should override it with managers parented to the test root '
        'ProviderContainer.',
      ),
    );
