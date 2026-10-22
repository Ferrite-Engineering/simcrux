// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:crux_cxp_ui/crux_cxp_ui.dart';
import 'package:crux_workspace/crux_workspace.dart' as crux;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/features/remote/services/cxp_workspace_link.dart';
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';

/// The name this window announces as its active document (CXP §8.1): the
/// active tab's name, which peers show beside this window in their
/// "Cross-probe to" menus. Null with no tab open.
String? simcruxActiveDocumentOf(crux.Workspace<SimcruxTabPayload>? workspace) {
  final id = workspace?.activeTabId;
  if (workspace == null || id == null) return null;
  for (final tab in workspace.tabs) {
    if (tab.id == id) return tab.displayName;
  }
  return null;
}

/// "Anchor" provider that keeps what SimCrux announces about itself in step
/// with its workspace:
///
/// * the active tab's name as this window's active document
///   ([CruxCxpRuntime.setActiveDocument]), so two SimCrux windows, or a
///   SimCrux beside two of another product, are told apart by what each has
///   open;
/// * every open project as its design's `project` artifact in the shared
///   workspace ([publishProjectWorkspaceArtifact]), once per project while
///   the server runs.
///
/// Watched from the app root, beside the runtime. Display and courtesy
/// only: a failure changes nothing a peer relies on.
final Provider<void> simcruxCxpPresenceProvider = Provider<void>((ref) {
  final published = <String>{};
  void sync() {
    final workspace = ref.read(workspaceProvider).value;
    final runtime = ref.read(cruxCxpRuntimeProvider).value;
    if (runtime != null) {
      unawaited(runtime.setActiveDocument(simcruxActiveDocumentOf(workspace)));
    }
    if (!ref.read(cruxCxpServerStatusProvider).running) return;
    for (final tab
        in workspace?.tabs ?? const <crux.WorkspaceTab<SimcruxTabPayload>>[]) {
      final config = tab.payload.configPath;
      if (config.isEmpty || !published.add(config)) continue;
      unawaited(publishProjectWorkspaceArtifact(ref, config));
    }
  }

  ref
    ..listen<AsyncValue<crux.Workspace<SimcruxTabPayload>>>(
      workspaceProvider,
      (_, _) => sync(),
    )
    ..listen<AsyncValue<CruxCxpRuntime?>>(
      cruxCxpRuntimeProvider,
      (_, _) => sync(),
    );
  sync();
});
