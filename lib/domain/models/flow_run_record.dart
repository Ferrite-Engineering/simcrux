// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';

/// One flow run's steps and metrics as the trend store keeps them
/// (`flow_steps`, `flow_metrics`), keyed by the run and test the result row
/// has.
@immutable
class FlowRunRecord {
  /// Creates the record.
  FlowRunRecord({
    required this.runId,
    required this.testId,
    List<FlowStepRow> steps = const <FlowStepRow>[],
    List<FlowMetricRow> metrics = const <FlowMetricRow>[],
  }) : steps = List<FlowStepRow>.unmodifiable(steps),
       metrics = List<FlowMetricRow>.unmodifiable(metrics);

  /// `runs.id`.
  final String runId;

  /// `test_results.test_name`.
  final String testId;

  /// The run's steps, in order.
  final List<FlowStepRow> steps;

  /// Every metric the run recorded, and every aggregate computed from them.
  final List<FlowMetricRow> metrics;
}

/// One `flow_steps` row.
@immutable
class FlowStepRow {
  /// Creates the row.
  const FlowStepRow({
    required this.ordinal,
    required this.id,
    required this.status,
    this.tool,
    this.runtimeMs,
  });

  /// The step's number in the run.
  final int ordinal;

  /// The step id (`openroad-stapostpnr`).
  final String id;

  /// The tool (`openroad`).
  final String? tool;

  /// `completed`, `failed`, `skipped`, `running` or `notStarted`.
  final String status;

  /// Wall time, when known.
  final int? runtimeMs;
}

/// One `flow_metrics` row.
@immutable
class FlowMetricRow {
  /// Creates the row.
  const FlowMetricRow({
    required this.key,
    required this.base,
    required this.modifiers,
    this.valueReal,
    this.valueText,
    this.aggregated = false,
  });

  /// The full METRICS2.1 key.
  final String key;

  /// The key without its modifiers.
  final String base;

  /// The modifiers, in key order.
  final Map<String, String> modifiers;

  /// A numeric value.
  final double? valueReal;

  /// A non-numeric value, as text.
  final String? valueText;

  /// Whether SimCrux computed this value by aggregation rather than reading
  /// it from the run.
  final bool aggregated;
}
