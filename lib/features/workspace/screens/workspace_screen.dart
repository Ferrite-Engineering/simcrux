// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:crux_workspace/crux_workspace.dart' as crux;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/features/dashboard/widgets/simcrux_toolbar.dart';
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';
import 'package:simcrux/features/workspace/providers/container_managers.dart';
import 'package:simcrux/features/workspace/providers/empty_canvas_content_provider.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';
import 'package:simcrux/features/workspace/widgets/empty_canvas_content.dart';
import 'package:simcrux/features/workspace/widgets/regression_status_bar.dart';
import 'package:simcrux/features/workspace/widgets/regression_tab_content.dart';
import 'package:simcrux/features/workspace/widgets/simcrux_viewer_tab_bar_strings.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/shared/platform/reveal_tab_file.dart';

/// Root screen for the SimCrux workspace.
///
/// Replaces the legacy Welcome screen + per-project route as the `/`
/// landing surface. Hosts crux_workspace's [`crux.PaneHost`] with:
///
/// * [EmptyCanvasContent] rendered when the workspace has zero tabs
///   (recent configs, recent sessions, Open Config / Session /
///   Workspace buttons).
/// * [RegressionTabContent] rendered per-tab inside the per-tab
///   `UncontrolledProviderScope` for each open `simcrux.yaml`.
/// * SimCrux-localized [SimcruxViewerTabBarStrings] for the tab bar's
///   chips and context-menu items.
///
/// Wraps the whole subtree in a [`crux.WorkspaceLifecycleObserver`] so
/// the auto-managed `workspace.json` flushes its debounced save when
/// the OS pauses or detaches the app.
class WorkspaceScreen extends ConsumerWidget {
  /// Creates the workspace root screen.
  const WorkspaceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final managers = ref.watch(workspaceContainerManagersProvider);
    final l10n = L10N.of(context);
    // Empty-canvas seam: the Pro overlay replaces the built-in
    // EmptyCanvasContent with EmptyWorkspaceState (EmptyCanvasContent
    // as the welcome side + the registry recents panel beside it).
    final emptyCanvasBuilder = ref.watch(emptyCanvasContentBuilderProvider);
    return crux.WorkspaceLifecycleObserver<SimcruxTabPayload>(
      provider: workspaceProvider,
      child: Scaffold(
        // Keyboard regions (F6 / Shift+F6) and lost-focus recovery. The
        // screen is mounted inside the app-level `ShortcutManagerWidget`'s
        // Actions, so focus this scope puts back (after a native file dialog,
        // say) stays within reach of every screen shortcut, and a screen
        // reader has something named to read.
        body: CruxFocusRegionScope(
          child: Column(
            children: [
              // The toolbar is app-level chrome, mounted once above the
              // PaneHost — matching the other three products. It used to live
              // inside `RegressionTabContent`, which meant a split pane
              // rendered one strip per pane and an unpopulated tab rendered
              // none at all.
              const CruxFocusRegion(child: SimcruxToolbar()),
              Expanded(
                child: crux.PaneHost<SimcruxTabPayload>(
                  provider: workspaceProvider,
                  tabs: managers.tabs,
                  panes: managers.panes,
                  strings: SimcruxViewerTabBarStrings(l10n),
                  // Tab chips are filename + close(X) only — no leading
                  // drag-handle icon (suite-canonical, matching WaveCrux). The
                  // tabs still reorder by dragging the chip itself.
                  useDragHandle: false,
                  // Only show the tab-strip scroll chevrons when the strip
                  // actually overflows; otherwise they render as permanent
                  // dead buttons that no-op on click (the strip is already
                  // fully visible).
                  autoHideScrollChevrons: true,
                  // Full-path hover tooltip + monospace context-menu header +
                  // "Reveal in Finder/Explorer/Files" (suite tab-bar canon).
                  tabFilePath: (tab) => tab.payload.configPath.isEmpty
                      ? null
                      : tab.payload.configPath,
                  onRevealTab: revealTabFile,
                  // The start screen is where lost focus goes back to. With a
                  // tab open, the tab's IDE layout supplies the regions itself.
                  emptyCanvasContent: CruxFocusRegion(
                    primary: true,
                    child: emptyCanvasBuilder != null
                        ? Builder(builder: emptyCanvasBuilder)
                        : const EmptyCanvasContent(),
                  ),
                  tabContentBuilder: (ctx, tab) =>
                      RegressionTabContent(tab: tab),
                ),
              ),
              // With tabs open, `RegressionTabContent` mounts the real
              // `RegressionStatusBar` at the bottom of each tab. With none,
              // that bar has nowhere to live and the window lost its bottom
              // edge — while WaveCrux and LintCrux kept theirs on the same
              // empty canvas. This idle bar reads no per-tab provider, so it
              // needs no tab scope.
              if (ref.watch(
                workspaceProvider.select(
                  (ws) => ws.value?.tabs.isEmpty ?? true,
                ),
              ))
                CruxFocusRegion(child: RegressionStatusBar.idle(context)),
            ],
          ),
        ),
      ),
    );
  }
}
