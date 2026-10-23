// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// No `package:crux_telemetry` import: these helpers sit beside services the
// headless CLI reaches. The callers construct the events, with the names
// spelled as literals, so the catalog's source scan sees them.

import 'package:crux_telemetry/crux_telemetry.dart' show TelemetryEvent;
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/services/flow/flow_metric_keys.dart';
import 'package:simcrux/services/flow/flow_process_driver.dart';
import 'package:simcrux/services/flow/gate_level/gls_outcome.dart';
import 'package:simcrux/services/flow/gate_level/gls_result.dart';
import 'package:simcrux/services/telemetry/telemetry_event_catalog.dart';

/// The `flow.run.completed` properties of one flow result's [metrics]
/// ([FlowMetricKeys]), or null when they are not a flow result's.
///
/// Six properties, the Worker's cap: `kind`, `source`, `outcome`, `target`,
/// `reader`, and the clamped `steps` count. Every value is a closed token:
/// never a metric value, a design or cell name, a path, a tag or a step
/// name.
Map<String, Object?>? flowRunCompletedProperties(
  Map<String, String> metrics, {
  required String source,
}) {
  final kind = metrics[FlowMetricKeys.kind];
  final outcome = metrics[FlowMetricKeys.verdict];
  if (kind == null || !kFlowKindTokens.contains(kind)) return null;
  if (outcome == null || !kFlowOutcomeTokens.contains(outcome)) return null;
  final target = metrics[FlowMetricKeys.target];
  final steps = int.tryParse(metrics[FlowMetricKeys.steps] ?? '');
  return <String, Object?>{
    'kind': kind,
    'source': kFlowSourceTokens.contains(source) ? source : 'run',
    'outcome': outcome,
    'target': kFlowTargetTokens.contains(target) ? target : 'other',
    'reader': metrics[FlowMetricKeys.readerVerified] == 'true'
        ? 'verified'
        : 'unverified',
    'steps': ?(steps == null ? null : telemetryCount(steps)),
  };
}

/// The `flow.run.completed` events one regression records: one per flow
/// result among [results]. Flow runs are few and each is the unit the
/// question counts.
List<Map<String, Object?>> flowRunsCompletedProperties(
  Iterable<TestResult> results,
) => <Map<String, Object?>>[
  for (final result in results)
    ?flowRunCompletedProperties(result.metrics, source: 'run'),
];

/// The `flow.reader.unsupported` events one regression records: one per
/// distinct (kind, reason) among [results].
List<Map<String, Object?>> flowReaderUnsupportedProperties(
  Iterable<TestResult> results,
) {
  final seen = <String>{};
  final out = <Map<String, Object?>>[];
  for (final result in results) {
    final kind = result.metrics[FlowMetricKeys.kind];
    final reason = result.metrics[FlowMetricKeys.readerUnsupported];
    if (kind == null || !kFlowKindTokens.contains(kind)) continue;
    if (reason == null || !kFlowReaderUnsupportedTokens.contains(reason)) {
      continue;
    }
    if (!seen.add('$kind|$reason')) continue;
    out.add(<String, Object?>{'kind': kind, 'reason': reason});
  }
  return out;
}

/// The distinct `flow.tool.missing.tool` tokens among [results], for one
/// event per run per tool: a flow tool that could not start, and the PDK cell
/// models a gate-level test could not find (`pdk_models`).
Set<String> flowToolMissingTokens(Iterable<TestResult> results) => <String>{
  for (final result in results)
    if (result.metrics[FlowDriverMetricKeys.toolMissing] case final tool?)
      if (kFlowToolTokens.contains(tool)) tool,
  if (results.any(
    (r) =>
        r.metrics[GlsMetricKeys.reason] ==
        GlsNotRunReason.modelsMissing.wireName,
  ))
    'pdk_models',
};

/// The `flow.gls.completed` event one gate-level run records, or null when
/// [results] hold no gate-level result. [clamp] is `telemetryCount`.
Map<String, Object?>? flowGlsCompletedProperties(
  Iterable<TestResult> results, {
  required int Function(int count) clamp,
}) => glsRunCompletedProperties(results, clamp: clamp);

/// The `flow.gls.completed` event of one gate-level run, functional or
/// annotated with the run's delays (`delays` says which), or null when
/// [results] hold no gate-level result. The one place the event is built, so
/// an edition that runs its own gate-level simulation records it through here.
TelemetryEvent? flowGlsCompletedEvent(Iterable<TestResult> results) {
  final properties = flowGlsCompletedProperties(
    results,
    clamp: telemetryCount,
  );
  return properties == null
      ? null
      : TelemetryEvent('flow.gls.completed', properties: properties);
}
