// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Opener callback for the Pro project-switcher dialog.
///
/// Receives a [BuildContext] anchored at the action-dispatch site so
/// the override can decide whether to push a route, open a modal
/// dialog, or attach the dialog to the active pane. Production wires
/// `showDialog`.
typedef ProjectSwitcherOpener = void Function(BuildContext context);

/// Extension-point seam the Pro overlay uses to mount the project
/// switcher.
///
/// **Open-core default.** Returns `null` — open-core does not own a
/// switcher widget, and with one project and no recents under
/// `NoopProjectRegistry` there is nothing to switch between. The
/// `SimcruxAction.switchProject` action stays discoverable in the
/// command palette / menu inventory in an open-core build (carrying its
/// PRO badge), and firing it surfaces the Pro-gated message.
///
/// **Pro override.** The Pro overlay's `proOverrides` replaces this
/// provider with a callback that tier-gates before navigating: it
/// checks `betaPeriodProvider` + `licenseTierProvider` and, only when
/// the Pro tier is unlocked, calls `ProjectSwitcherDialog.show(context)`.
/// Post-beta openCore users hit the closed gate and the opener does not
/// mount the dialog. The gate lives in the opener (the navigation
/// owner), not inside the dialog widget.
final Provider<ProjectSwitcherOpener?> projectSwitcherOpenerProvider =
    Provider<ProjectSwitcherOpener?>((_) => null);
