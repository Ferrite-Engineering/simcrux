// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Opener callback for a Pro multi-project list operation.
///
/// Receives a [BuildContext] anchored inside the active navigator so the
/// override can confirm, navigate, or mount the Pro upgrade dialog on the
/// deny path.
typedef ProjectListOpener = void Function(BuildContext context);

/// Extension-point seam for `SimcruxAction.closeAllProjects`.
///
/// **Open-core default.** Returns `null`. Closing every open *project*
/// while pinned projects survive is a contract only the Pro multi-project
/// registry can honor — `NoopProjectRegistry` holds one project and pins
/// nothing, so an open-core implementation would be the tab-closing
/// capability wearing this action's name. That capability ships honestly
/// and unconditionally as `SimcruxAction.closeAllTabs`.
///
/// **Pro override.** Gates on `betaPeriodProvider` + `licenseTierProvider`
/// (upgrade dialog on the deny path), confirms, then closes every
/// non-pinned project through the Pro registry and reconciles the
/// workspace tabs that backed them.
final Provider<ProjectListOpener?> closeAllProjectsOpenerProvider =
    Provider<ProjectListOpener?>((_) => null);

/// Extension-point seam for `SimcruxAction.reopenRecentProject`.
///
/// **Open-core default.** Returns `null`. `NoopProjectRegistry` clears
/// recents by construction, so there is nothing for an open-core
/// implementation to reopen; the dispatcher surfaces the Pro-gated
/// message instead of an empty-recents no-op that would contradict the
/// PRO badge the palette and menu bar render.
///
/// **Pro override.** Gates, then reopens the most-recently-closed project
/// from the persisted recents list.
final Provider<ProjectListOpener?> reopenRecentProjectOpenerProvider =
    Provider<ProjectListOpener?>((_) => null);

/// Extension-point seam for `SimcruxAction.pinActiveProject`.
///
/// **Open-core default.** Returns `null`. `NoopProjectRegistry` records the
/// active tab as a project but pins nothing, so toggling the pin there would
/// change no state and give no feedback; the dispatcher surfaces the
/// Pro-gated message instead, matching the PRO badge on the entry.
///
/// **Pro override.** Gates, then toggles the active project's pin in the
/// persistent registry, so it survives Close All Projects.
final Provider<ProjectListOpener?> pinActiveProjectOpenerProvider =
    Provider<ProjectListOpener?>((_) => null);
