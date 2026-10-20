// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_cxp/crux_cxp.dart';
import 'package:crux_cxp_ui/crux_cxp_ui.dart';
import 'package:simcrux/domain/models/dashboard_row.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';

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
    metadata: <String, Object?>{cxpDesignIdMetadataKey: ?designId},
  );
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
