// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_table/crux_table.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

/// The Flow Runs list's columns.
enum FlowRunColumn {
  /// The verdict.
  verdict,

  /// The design (the `flow:` entry).
  design,

  /// The run tag.
  tag,

  /// LibreLane or nextpnr.
  kind,
}

/// The steps table's columns.
enum FlowStepColumn {
  /// The step's number.
  ordinal,

  /// The step id.
  step,

  /// The tool.
  tool,

  /// Its status.
  status,

  /// Its wall time.
  runtime,
}

/// The worst-paths table's columns.
enum FlowPathColumn {
  /// The report's rank.
  rank,

  /// The capturing clock.
  clock,

  /// Where the path starts.
  from,

  /// Where it ends.
  to,

  /// Its delay.
  delay,

  /// How it maps to the RTL.
  mapping,
}

/// The path detail's segment columns.
enum FlowSegmentColumn {
  /// The segment type (`logic`, `routing`, …).
  type,

  /// The cell it starts at.
  from,

  /// The cell it ends at.
  to,

  /// Its delay.
  delay,

  /// Where it lands in the RTL.
  source,
}

/// The metrics table's columns: the metric, then up to twelve value
/// columns (the design-wide value first, then one per corner).
enum FlowMetricColumn {
  /// The metric's label.
  metric,

  /// Value slots, filled left to right.
  v0,

  /// See [v0].
  v1,

  /// See [v0].
  v2,

  /// See [v0].
  v3,

  /// See [v0].
  v4,

  /// See [v0].
  v5,

  /// See [v0].
  v6,

  /// See [v0].
  v7,

  /// See [v0].
  v8,

  /// See [v0].
  v9,

  /// See [v0].
  v10,

  /// See [v0].
  v11,
}

/// The value slots of [FlowMetricColumn], in order.
const List<FlowMetricColumn> kFlowMetricValueColumns = <FlowMetricColumn>[
  FlowMetricColumn.v0,
  FlowMetricColumn.v1,
  FlowMetricColumn.v2,
  FlowMetricColumn.v3,
  FlowMetricColumn.v4,
  FlowMetricColumn.v5,
  FlowMetricColumn.v6,
  FlowMetricColumn.v7,
  FlowMetricColumn.v8,
  FlowMetricColumn.v9,
  FlowMetricColumn.v10,
  FlowMetricColumn.v11,
];

/// The run list's widths, remembered app-wide.
final CruxColumnLayoutProviders<FlowRunColumn> flowRunColumnLayout =
    CruxColumnLayoutProviders<FlowRunColumn>(
      columns: const CruxTableColumns<FlowRunColumn>(
        columns: FlowRunColumn.values,
        defaultWeights: <FlowRunColumn, double>{
          FlowRunColumn.verdict: 1.4,
          FlowRunColumn.design: 1.6,
          FlowRunColumn.tag: 2,
          FlowRunColumn.kind: 1,
        },
      ),
      prefsKey: 'simcrux.flowRunColumnWeights',
      name: 'flowRunColumnLayout',
    );

/// The steps table's widths, remembered app-wide.
final CruxColumnLayoutProviders<FlowStepColumn> flowStepColumnLayout =
    CruxColumnLayoutProviders<FlowStepColumn>(
      columns: const CruxTableColumns<FlowStepColumn>(
        columns: FlowStepColumn.values,
        defaultWeights: <FlowStepColumn, double>{
          FlowStepColumn.ordinal: 0.6,
          FlowStepColumn.step: 3,
          FlowStepColumn.tool: 1.2,
          FlowStepColumn.status: 1.2,
          FlowStepColumn.runtime: 1,
        },
      ),
      prefsKey: 'simcrux.flowStepColumnWeights',
      name: 'flowStepColumnLayout',
    );

/// The worst-paths table's widths, remembered app-wide.
final CruxColumnLayoutProviders<FlowPathColumn> flowPathColumnLayout =
    CruxColumnLayoutProviders<FlowPathColumn>(
      columns: const CruxTableColumns<FlowPathColumn>(
        columns: FlowPathColumn.values,
        defaultWeights: <FlowPathColumn, double>{
          FlowPathColumn.rank: 0.6,
          FlowPathColumn.clock: 1,
          FlowPathColumn.from: 2,
          FlowPathColumn.to: 2,
          FlowPathColumn.delay: 1,
          FlowPathColumn.mapping: 1.4,
        },
      ),
      prefsKey: 'simcrux.flowPathColumnWeights',
      name: 'flowPathColumnLayout',
    );

/// The path detail's widths, remembered app-wide.
final CruxColumnLayoutProviders<FlowSegmentColumn> flowSegmentColumnLayout =
    CruxColumnLayoutProviders<FlowSegmentColumn>(
      columns: const CruxTableColumns<FlowSegmentColumn>(
        columns: FlowSegmentColumn.values,
        defaultWeights: <FlowSegmentColumn, double>{
          FlowSegmentColumn.type: 1,
          FlowSegmentColumn.from: 2,
          FlowSegmentColumn.to: 2,
          FlowSegmentColumn.delay: 1,
          FlowSegmentColumn.source: 2.4,
        },
      ),
      prefsKey: 'simcrux.flowSegmentColumnWeights',
      name: 'flowSegmentColumnLayout',
    );

/// Loads the four Flow tables' saved widths before the first frame, as the
/// results table's are, and returns the overrides that hand them over.
/// The metrics table's columns are the run's own corners, so its widths are
/// not remembered.
Future<List<Override>> loadFlowTableLayoutOverrides() async {
  final runs = await flowRunColumnLayout.load();
  final steps = await flowStepColumnLayout.load();
  final paths = await flowPathColumnLayout.load();
  final segments = await flowSegmentColumnLayout.load();
  return <Override>[
    flowRunColumnLayout.launchOverride(runs),
    flowStepColumnLayout.launchOverride(steps),
    flowPathColumnLayout.launchOverride(paths),
    flowSegmentColumnLayout.launchOverride(segments),
  ];
}
