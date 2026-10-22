// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_flow/crux_flow.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/core/shortcuts/simcrux_action.dart';
import 'package:simcrux/features/flow/providers/flow_providers.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/flow/flow_metric_keys.dart';
import 'package:simcrux/services/flow/flow_run_importer.dart';

/// The inspector's hand-off buttons for a flow result: Open in KLayout and
/// Open in OpenROAD for a LibreLane run, Open in nextpnr for a nextpnr run.
/// Empty for every other result.
///
/// Each makes the result's run the selected flow run and dispatches the
/// same `SimcruxAction` as Tools > Open in KLayout… (and the others), so
/// the menu, the palette, the Flow Runs panel and these buttons share one
/// handler: the viewer starts detached, and a missing viewer or a run with
/// nothing to open says so in a toast.
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
  final FlowKind flowKind;
  try {
    flowKind = FlowKind.fromWireName(kind);
  } on FormatException {
    return const [];
  }
  const prefix = '${FlowRunImporter.kFlowSuiteName}/';
  final id = selection.result.testId;
  final target = FlowRunSelection(
    root: runDir,
    kind: flowKind,
    design: id.startsWith(prefix) ? id.substring(prefix.length) : null,
  );
  Widget button(SimcruxAction action, String label, IconData icon) =>
      OutlinedButton.icon(
        key: ValueKey('flowHandoff.${action.name}'),
        onPressed: () {
          ref.read(flowSelectedRunProvider.notifier).select(target);
          Actions.maybeInvoke<SimcruxActionIntent>(
            context,
            SimcruxActionIntent(action),
          );
        },
        icon: Icon(icon),
        label: Text(label),
      );
  return switch (flowKind) {
    FlowKind.librelane => <Widget>[
      button(
        SimcruxAction.openInKlayout,
        l10n.inspectorActionOpenInKlayout,
        Icons.layers_outlined,
      ),
      button(
        SimcruxAction.openInOpenroad,
        l10n.inspectorActionOpenInOpenroad,
        Icons.grid_on_outlined,
      ),
    ],
    FlowKind.nextpnr => <Widget>[
      button(
        SimcruxAction.openInNextpnrGui,
        l10n.inspectorActionOpenInNextpnr,
        Icons.memory_outlined,
      ),
    ],
  };
}
