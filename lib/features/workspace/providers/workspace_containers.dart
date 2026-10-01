// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_workspace/crux_workspace.dart' as crux;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:simcrux/features/workspace/providers/container_managers.dart';
import 'package:simcrux/features/workspace/providers/simcrux_pane_overrides.dart';
import 'package:simcrux/features/workspace/providers/simcrux_tab_overrides.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';

/// The production container topology built by [createWorkspaceContainers].
///
/// [root] hosts every non-overridden provider (Riverpod materializes a
/// provider in the ROOT-most container unless an override scopes it);
/// [scoped] is the child container handed to `runApp`'s
/// `UncontrolledProviderScope`; [managers] owns the per-tab / per-pane
/// child containers.
typedef WorkspaceContainers = ({
  ProviderContainer root,
  ProviderContainer scoped,
  WorkspaceContainerManagers managers,
});

/// Builds the two-phase root + scoped `ProviderContainer` pair and the
/// per-tab / per-pane container managers exactly as production
/// `bootstrap()` wires them (extracted from `app.dart` so tests can
/// exercise the REAL topology instead of a single flat test container).
///
/// [rootOverrides] is the bootstrap override list (CLI args, theme
/// bridge, Pro `extraOverrides`, …); [scopedOverrides] is spread into
/// the scoped child container after the managers binding (production
/// passes `simcruxIssueReporterScopedOverrides`).
///
/// The caller owns all three results: dispose [WorkspaceContainers.scoped],
/// then [WorkspaceContainers.managers], then [WorkspaceContainers.root]
/// (production never disposes — the topology lives for the process).
WorkspaceContainers createWorkspaceContainers({
  List<Override> rootOverrides = const <Override>[],
  List<Override> scopedOverrides = const <Override>[],
}) {
  // Managers are created AFTER the root container (they parent their
  // per-tab / per-pane child containers under it), yet they must be
  // resolvable FROM the root container: Riverpod materializes every
  // non-overridden provider in the ROOT-most container, so the
  // root-scope providers that reach into the active tab's container —
  // `activeTabActionFlagsProvider` (behind `simcruxActionContextProvider`,
  // which gates every menu / toolbar / palette action), the CXP inbound
  // request handler, and the notify_selection emitter via
  // `activeTabContainerOf` — all resolve `workspaceContainerManagersProvider`
  // in the ROOT container. Binding the managers only in the scoped child
  // container leaves the root's throwing default in place; those
  // providers' "unbound in tests"
  // fallbacks swallow it, silently disabling every per-tab-gated action
  // for the whole session (the "Run Regression permanently disabled"
  // regression). The `late` binding is safe: the provider body runs on
  // first read, and nothing can read it before the assignment below —
  // `simcruxTabOverridesFactoryProvider` is the only provider resolved
  // in between and does not touch it (a violation would throw a loud
  // LateInitializationError, not silently disable actions).
  late final WorkspaceContainerManagers managers;
  final root = ProviderContainer(
    overrides: <Override>[
      ...rootOverrides,
      workspaceContainerManagersProvider.overrideWith((_) => managers),
    ],
  );
  // Resolve the per-tab overrides factory once at boot. Open-core
  // returns [simcruxTabOverrides]; the Pro overlay overrides the seam
  // to share per-project state across tabs. See
  // [simcruxTabOverridesFactoryProvider].
  final tabOverridesFactory = root.read(simcruxTabOverridesFactoryProvider);
  managers = WorkspaceContainerManagers(
    tabs: crux.TabContainerManager(
      rootContainer: root,
      overridesFactory: tabOverridesFactory,
    ),
    panes: crux.PaneContainerManager(
      rootContainer: root,
      overridesFactory: simcruxPaneOverrides,
    ),
  );
  // Make the managers visible to the workspace screen + any other
  // consumer. Production hands this container to runApp.
  final scoped = ProviderContainer(
    parent: root,
    overrides: <Override>[
      workspaceContainerManagersProvider.overrideWithValue(managers),
      ...scopedOverrides,
    ],
  );
  // Register the container managers as workspace scope reconcilers
  // BEFORE hydration, so the first emitted snapshot (from the notifier's
  // own `build`) already prunes them. Without this, closing a tab never
  // disposes its ProviderContainer — leaking every provider, stream
  // subscription and timer it holds for the process lifetime — and a
  // workspace reload that revives a persisted TabId hands the "new" tab
  // the dead tab's container, bleeding state across tabs.
  scoped.read(workspaceProvider.notifier)
    ..addScopeReconciler(managers.tabs)
    ..addScopeReconciler(managers.panes);
  return (root: root, scoped: scoped, managers: managers);
}

/// Mounts [root] and, beneath it, [scoped] — the pair
/// [createWorkspaceContainers] builds — above the app.
///
/// Both are mounted although the tree only ever reads [scoped], because
/// Riverpod gives every container its own scheduler, and a scheduler
/// refreshes providers in step with the frame only while an
/// `UncontrolledProviderScope` for its container is in the tree. Every
/// provider nothing overrides lives in [root], so with [scoped] mounted
/// alone their refreshes ran on a zero-length timer instead. A frame that
/// landed before the timer rebuilt their watchers while they were still
/// dirty: the first watcher to read one flushed it mid-build and notified
/// its siblings, and the framework asserted `markNeedsBuild() called during
/// build`. Mounted, [root]'s scope builds first, above every watcher, and
/// refreshes them before any of them builds.
class WorkspaceContainersScope extends StatelessWidget {
  /// Creates a scope mounting [root] above [scoped].
  const WorkspaceContainersScope({
    required this.root,
    required this.scoped,
    required this.child,
    super.key,
  });

  /// The root container, parent of [scoped].
  final ProviderContainer root;

  /// The container the widget tree reads from.
  final ProviderContainer scoped;

  /// The app.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return UncontrolledProviderScope(
      container: root,
      child: UncontrolledProviderScope(container: scoped, child: child),
    );
  }
}
