// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Extension-point seam for the workspace's empty-canvas surface —
/// what renders when the workspace has zero open tabs.
///
/// **Open-core default.** Returns `null`; `WorkspaceScreen` falls
/// back to the built-in `EmptyCanvasContent` (recent configs +
/// Open Config / Open Session / Open Workspace / New Config actions).
///
/// **Pro override.** The Pro overlay replaces this with a builder
/// returning `EmptyWorkspaceState`, which hosts the same
/// `EmptyCanvasContent` as its welcome side and adds the
/// `RecentProjectsPanel` (registry recents with one-click Reopen /
/// Forget) beside it. A `WidgetBuilder` (not a bare `Widget`) so the
/// override can resolve `Actions` / localizations from the mounting
/// context.
final Provider<WidgetBuilder?> emptyCanvasContentBuilderProvider =
    Provider<WidgetBuilder?>((ref) => null);
