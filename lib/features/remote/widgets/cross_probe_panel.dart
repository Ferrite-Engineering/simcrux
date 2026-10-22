// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_cxp_ui/crux_cxp_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/features/remote/providers/cross_probe_visibility_provider.dart';
import 'package:simcrux/features/remote/services/cross_probe_selection.dart';

/// SimCrux's docked cross-probe panel.
///
/// The shared, runtime-bound `CruxCrossProbePanel` (peers, unreachable peers,
/// the event log and every send are the suite's), given the one thing that is
/// SimCrux's own: the active tab's selected test, or the worst path the user
/// is on in Flow Runs ([tabCrossProbeSelection]). Mounted by
/// `SimcruxRightDock` inside the tab's provider scope, so the selection it
/// reads is the tab the user is looking at. The dock tab already carries the
/// icon, the label and the close button, so the panel draws no header of its
/// own.
class SimCruxCrossProbePanel extends ConsumerWidget {
  /// Creates the docked cross-probe panel.
  const SimCruxCrossProbePanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return CruxCrossProbePanel(
      selection: () => tabCrossProbeSelection(ref.read),
      onClose: () =>
          ref.read(crossProbeVisibleProvider.notifier).set(visible: false),
    );
  }
}
