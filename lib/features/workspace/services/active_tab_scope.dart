// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_workspace/crux_workspace.dart' as crux;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/features/workspace/providers/container_managers.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';

/// Where a dialog that reads a tab's providers is shown.
///
/// A dialog on the root navigator is outside every tab's
/// `UncontrolledProviderScope`, so one that reads `activeConfigProvider`,
/// `selectedTestIdProvider`, `fullInspectorLogProvider`, ... from there sees
/// the root container, where no config is loaded. SimCrux used to fix that by
/// wrapping the dialog in a second scope over the tab's container, which let
/// Riverpod flush that container's rebuilds from two scopes in one frame and
/// mark the tab's own widgets dirty in the middle of a build.
///
/// Each tab's content is instead built on its own nested navigator
/// (`PaneHost.tabNavigators`, owned by [WorkspaceContainerManagers]), and a
/// dialog that needs the tab is pushed on it:
///
/// ```dart
/// showCruxDialog<void>(
///   context: context,
///   navigator: ActiveTab.navigatorFor(context),
///   builder: (_) => const MyDialog(),
/// );
/// ```
///
/// The dialog is then built under the tab's one scope. It covers the tab's
/// area, not the window, and belongs to the tab: switching tabs hides it with
/// its tab, and closing the tab closes it (its future completes with null).
/// A dialog that reads no per-tab provider stays on the root navigator.
abstract final class ActiveTab {
  /// The navigator of the tab [callerContext] is inside, else the active
  /// tab's navigator, else null.
  ///
  /// Null when no tab is active (the empty workspace), the workspace is not
  /// bound above [callerContext], or the active tab's content has not been
  /// built; `showCruxDialog` then uses the root navigator, as before, and the
  /// dialog sees the root container.
  ///
  /// [callerContext] may be inside a tab (a panel, or a dialog already on the
  /// tab's navigator, so a dialog opened from a dialog lands on the same tab)
  /// or outside every tab (the menu bar, the palette, the routerDelegate's
  /// navigator context).
  static NavigatorState? navigatorFor(BuildContext callerContext) =>
      _resolve(callerContext)?.navigator;

  /// [surface]'s `ModalGuard` key for the tab [navigatorFor] resolves, or
  /// [surface] itself when there is none.
  ///
  /// A dialog that belongs to a tab stays open, hidden, while another tab is
  /// active. One process-wide key would then swallow the same command in the
  /// other tab with nothing on screen to explain it, so each tab guards its
  /// own copy.
  static String guardKey(BuildContext callerContext, String surface) {
    final tab = _resolve(callerContext)?.tab;
    return tab == null ? surface : '$surface@${tab.value}';
  }

  static ({crux.TabId tab, NavigatorState navigator})? _resolve(
    BuildContext callerContext,
  ) {
    try {
      final container = ProviderScope.containerOf(callerContext, listen: false);
      final inTab = crux.cruxTabNavigatorOf(callerContext);
      if (inTab != null) {
        return (tab: container.read(crux.tabIdProvider), navigator: inTab);
      }
      final active = container.read(workspaceProvider).value?.activeTabId;
      if (active == null) return null;
      final navigator = container
          .read(workspaceContainerManagersProvider)
          .tabNavigators
          .navigatorFor(active);
      if (navigator == null) return null;
      return (tab: active, navigator: navigator);
    } on Object {
      // No provider scope or managers unbound (a widget test host, the web
      // viewer): no tab, so the root navigator.
      return null;
    }
  }
}
