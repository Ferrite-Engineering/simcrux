// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:crux_cxp/crux_cxp.dart';
import 'package:crux_cxp_ui/crux_cxp_ui.dart';
import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/domain/models/dashboard_row.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/remote/services/cross_probe_selection.dart';

/// The "Cross-probe to" item of a results row's context menu.
///
/// One item, free on every tier. Choosing it closes the row menu and opens
/// the list of running peer products at [position], where the row menu
/// opened; choosing one sends the row's test (and its waveform, when it
/// captured one) to that product. With no peer running the item is greyed and
/// its tooltip says what to start.
///
/// [row] is the right-clicked row. Must be called from the row's own widget
/// scope: the active project, which names the design the peer resolves, is
/// per tab.
List<PopupMenuEntry<void>> buildCrossProbeRowMenuEntries(
  BuildContext context,
  WidgetRef ref,
  DashboardRow row,
  Offset position,
) {
  final designId = _designIdOf(ref);
  final entry =
      crossProbeMenuEntry(
            context,
            ref,
            selection: () => crossProbeSelectionForRow(row, designId: designId),
          )
          as CruxSubmenu;
  final label = Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(entry.icon, size: 18),
      const SizedBox(width: 12),
      Flexible(child: Text(entry.label)),
    ],
  );
  final tooltip = entry.tooltip;
  return <PopupMenuEntry<void>>[
    PopupMenuItem<void>(
      key: const ValueKey('crossProbeRowMenuItem'),
      enabled: entry.enabled,
      // Runs after the row menu has closed, so the second menu is the only
      // one on screen.
      onTap: () => unawaited(
        showCruxContextMenu(
          context,
          globalPosition: position,
          entries: entry.entries,
        ),
      ),
      child: tooltip == null ? label : Tooltip(message: tooltip, child: label),
    ),
  ];
}

String? _designIdOf(WidgetRef ref) {
  final config = ref.read(activeConfigProvider);
  return config == null ? null : cxpDesignIdForPath(config.projectFilePath);
}
