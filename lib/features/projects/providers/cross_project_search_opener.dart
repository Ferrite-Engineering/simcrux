// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Opener callback for the Pro cross-project search dialog.
///
/// Receives a [BuildContext] anchored at the action-dispatch site so
/// the override can decide whether to push a route, open a modal
/// dialog, or attach the dialog to the active pane. Production wires
/// `showDialog`.
typedef CrossProjectSearchOpener = void Function(BuildContext context);

/// Extension-point seam the Pro overlay uses to mount the
/// cross-project search dialog.
///
/// **Open-core default.** Returns `null` — open-core does not own a
/// dialog widget. The `SimcruxAction.searchAcrossProjects` action
/// stays discoverable in the command palette / menu inventory in an
/// open-core build (so users see the capability) but firing it is a
/// no-op until the Pro overlay registers an opener.
///
/// **Pro override.** The Pro overlay's `proOverrides` replaces this
/// provider with a callback that tier-gates before navigating: it
/// checks `betaPeriodProvider` + `licenseTierProvider` and, only when
/// the Pro tier is unlocked, calls `CrossProjectSearchDialog.show(context)`.
/// Post-beta openCore users hit the closed gate and the opener does not
/// mount the dialog. The gate lives in the opener (the navigation
/// owner), not inside the dialog widget.
final Provider<CrossProjectSearchOpener?> crossProjectSearchOpenerProvider =
    Provider<CrossProjectSearchOpener?>((_) => null);
