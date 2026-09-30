// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/features/workspace/providers/container_managers.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';

/// Resolves the ACTIVE tab's per-tab `ProviderContainer` from
/// root-scoped code that has no `BuildContext`.
///
/// The per-tab providers (`selectedTestIdProvider`,
/// `dashboardFilterProvider`, `activeConfigProvider`, …) materialize
/// inside each tab's child container; a root-scoped service that
/// `ref.read`s them directly hits the dormant root instances instead
/// of the state the user is looking at. Root-hosted consumers that
/// must act on the active tab — canonically the CXP inbound request
/// handler and the notify_selection emitter — resolve the active tab's
/// container through this helper first and fall back to their own
/// (root) scope only when no workspace is mounted (headless tests,
/// pre-hydration startup).
///
/// Returns `null` when the workspace has not hydrated, no tab is
/// active, or [workspaceContainerManagersProvider] is not bound (it
/// throws unless `bootstrap()` — or a test — overrides it).
ProviderContainer? activeTabContainerOf(Ref ref) {
  final ws = ref.read(workspaceProvider).value;
  final activeTabId = ws?.activeTabId;
  if (activeTabId == null) return null;
  final WorkspaceContainerManagers managers;
  try {
    managers = ref.read(workspaceContainerManagersProvider);
  } on Object {
    // Not bound — no PaneHost / container managers in this process
    // (unit tests, headless CLI). Callers fall back to root scope.
    return null;
  }
  return managers.tabs.containerFor(activeTabId);
}
