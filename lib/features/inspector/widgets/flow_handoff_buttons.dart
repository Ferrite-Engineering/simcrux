// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:crux_flow/crux_flow.dart';
import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/domain/models/flow_tool_settings.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/flow/flow_handoff_launcher.dart';
import 'package:simcrux/services/flow/flow_handoff_provider.dart';
import 'package:simcrux/services/flow/flow_metric_keys.dart';

/// The inspector's hand-off buttons for a flow result: Open in KLayout and
/// Open in OpenROAD for a LibreLane run, Open in nextpnr for a nextpnr run.
/// Empty for every other result.
///
/// The viewer starts detached and never blocks; a missing viewer or a run
/// with nothing to open says so in a toast, never an error dialog.
List<Widget> flowHandoffButtons(
  BuildContext context,
  WidgetRef ref,
  SelectedTest selection,
) {
  final metrics = selection.result.metrics;
  final runDir = metrics[FlowMetricKeys.runDir];
  final kind = metrics[FlowMetricKeys.kind];
  if (runDir == null || runDir.isEmpty || kind == null) return const [];
  final l10n = L10N.of(context);
  Widget button(FlowViewer viewer, String label, IconData icon) =>
      OutlinedButton.icon(
        key: ValueKey('flowHandoff.${viewer.token}'),
        onPressed: () => unawaited(
          _open(context, ref, selection, viewer, FlowKind.fromWireName(kind)),
        ),
        icon: Icon(icon),
        label: Text(label),
      );
  if (kind == FlowKind.librelane.wireName) {
    return <Widget>[
      button(
        FlowViewer.klayout,
        l10n.inspectorActionOpenInKlayout,
        Icons.layers_outlined,
      ),
      button(
        FlowViewer.openroadGui,
        l10n.inspectorActionOpenInOpenroad,
        Icons.grid_on_outlined,
      ),
    ];
  }
  if (kind == FlowKind.nextpnr.wireName) {
    return <Widget>[
      button(
        FlowViewer.nextpnrGui,
        l10n.inspectorActionOpenInNextpnr,
        Icons.memory_outlined,
      ),
    ];
  }
  return const [];
}

Future<void> _open(
  BuildContext context,
  WidgetRef ref,
  SelectedTest selection,
  FlowViewer viewer,
  FlowKind kind,
) async {
  final l10n = L10N.of(context);
  final settings = ref.read(appSettingsProvider).value;
  final result = await ref
      .read(flowHandoffLauncherProvider)
      .open(
        viewer,
        kind: kind,
        runRoot: selection.result.metrics[FlowMetricKeys.runDir]!,
        entry: selection.spec?.flow,
        settings: settings?.flowTools ?? const FlowToolSettings(),
        nextpnrPath: settings?.simulatorBinaryOverrides['nextpnr'],
      );
  if (!context.mounted || result.ok) return;
  final name = switch (viewer) {
    FlowViewer.klayout => 'KLayout',
    FlowViewer.openroadGui => 'OpenROAD',
    FlowViewer.nextpnrGui => 'nextpnr',
  };
  showCruxInfoSnack(
    context,
    result.missingTool != null
        ? l10n.inspectorFlowViewerMissing(name)
        : l10n.inspectorFlowViewerNothingToOpen,
  );
}
