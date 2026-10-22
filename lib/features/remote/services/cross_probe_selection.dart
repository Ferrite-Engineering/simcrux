// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_cxp/crux_cxp.dart';
import 'package:crux_cxp_ui/crux_cxp_ui.dart';
import 'package:simcrux/domain/models/dashboard_row.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/flow/providers/flow_providers.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/features/remote/services/flow_path_selection.dart';
import 'package:simcrux/services/remote/cxp/formal_stream_coordinate.dart';

/// What SimCrux sends a cross-probe about for the test [row]: the test, named
/// in every kind it can be expressed in, most precise first.
///
/// * `test`, the test id, for a peer that can show a test.
/// * `source`, the waveform the test captured (when it did), for WaveCrux:
///   what "Debug in WaveCrux" sends, so the trace opens.
/// * `scope`, the test id again, for NetCrux and LintCrux, which look the
///   module up by name.
///
/// The shared element-kind table then picks, per target, the first kind the
/// target accepts: a test row goes to WaveCrux as its waveform and to NetCrux
/// and LintCrux as a scope.
///
/// [designId] is the active project's `crux.design_id`, which lets a peer
/// with nothing open resolve the design through the shared workspace.
///
/// A formal row's waveform is its counterexample (or cover witness). It
/// travels as the `source` element with the `formal.trace_step` coordinate
/// the row can state (CXP §9.9.3; absent when it cannot) and the registered
/// `formal.` keys: the property's role and label, or an EQY run's gold and
/// gate scopes. The candidates never carry a `signal`: WaveCrux prefers a
/// signal to a source, and the trace is what it must open.
CrossProbeSelection crossProbeSelectionForRow(
  DashboardRow row, {
  String? designId,
}) {
  final waveform = row.result.waveformPath;
  return CrossProbeSelection(
    candidates: <ElementId>[
      ElementId(kind: ElementKind.test, path: row.testId),
      if (waveform != null && waveform.isNotEmpty)
        ElementId(kind: ElementKind.source, path: waveform),
      ElementId(kind: ElementKind.scope, path: row.testId),
    ],
    displayName: row.testName,
    coordinate: waveform == null || waveform.isEmpty
        ? null
        : formalStreamCoordinateFor(row.result),
    metadata: <String, Object?>{
      ...formalHandoffMetadata(row.result),
      cxpDesignIdMetadataKey: ?designId,
    },
  );
}

/// The selection "Show in NetCrux" sends for the formal row [result]: the
/// signal the failing property reads first, as a `signal` with the property's
/// `formal.property_kind` and `formal.property_label`, so NetCrux selects it
/// and draws its fan-in; then the property itself (`<file>:<line>`), which
/// NetCrux Pro widens to the union cone and the target's kind table offers
/// only when no signal is known. Null when the row has no fired property.
CrossProbeSelection? formalShowInNetCruxSelection(
  TestResult result, {
  String? designId,
}) {
  final property = formalHandoffProperty(result);
  if (property == null) return null;
  final signal = property.reads.isEmpty ? null : property.reads.first;
  final element = property.elementPath;
  if (signal == null && element == null) return null;
  return CrossProbeSelection(
    candidates: <ElementId>[
      if (signal != null) ElementId(kind: ElementKind.signal, path: signal),
      if (element != null) ElementId(kind: ElementKind.property, path: element),
    ],
    displayName: property.label ?? property.location,
    metadata: <String, Object?>{
      // NetCrux draws the fan-in only for a signal that carries one of the
      // two property keys; the role is always known.
      cxpFormalPropertyKindMetadataKey: property.registeredKind ?? 'assert',
      cxpFormalPropertyLabelMetadataKey: ?property.label,
      cxpDesignIdMetadataKey: ?designId,
    },
  );
}

/// What the tab [read] reads from would cross-probe now: the worst path the
/// user is on in a shown Flow Runs panel ([flowFocusedPathProvider]), else
/// the selected test ([selectedTestCrossProbeSelection]). [read] must be the
/// tab's, as for the selected test.
CrossProbeSelection? tabCrossProbeSelection(CruxCxpReader read) {
  final path = read(flowRunsVisibleProvider)
      ? read(flowFocusedPathProvider)
      : null;
  if (path != null) return flowPathCrossProbeSelection(path);
  return selectedTestCrossProbeSelection(read);
}

/// The selection of the selected test in the tab [read] reads from, or null
/// when none is selected. [read] must be the tab's: a widget's `ref.read`
/// inside the tab's provider scope, or the tab container's own `read`. The
/// selected test and the active config are per tab.
CrossProbeSelection? selectedTestCrossProbeSelection(CruxCxpReader read) {
  final testId = read(selectedTestIdProvider);
  if (testId == null || testId.isEmpty) return null;
  final config = read(activeConfigProvider);
  final designId = config == null
      ? null
      : cxpDesignIdForPath(config.projectFilePath);
  final selected = read(selectedTestProvider);
  if (selected != null) {
    return crossProbeSelectionForRow(selected.row, designId: designId);
  }
  // Selected but not yet reported by a run: the id alone is still a test and a
  // scope a peer can look up.
  return CrossProbeSelection(
    candidates: <ElementId>[
      ElementId(kind: ElementKind.test, path: testId),
      ElementId(kind: ElementKind.scope, path: testId),
    ],
    displayName: testId,
    metadata: <String, Object?>{cxpDesignIdMetadataKey: ?designId},
  );
}
