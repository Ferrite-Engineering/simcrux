// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// No `package:crux_telemetry` import: the CI runner, which is in the headless
// CLI's import closure, calls these. The callers construct the events, with
// the names spelled as literals, so the catalog's source scan sees them.

import 'package:simcrux/domain/models/formal_result_summary.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/services/telemetry/telemetry_event_catalog.dart';

/// The properties of the `formal.run.completed` events one regression
/// records: **one event per distinct (tool, mode, engine)**, with the
/// property counts summed, never one per test.
///
/// A riscv-formal import is hundreds of tasks, and one event per task would
/// crowd every other counter out of a bounded queue; the question the event
/// answers ("who runs formal, with what, and how often it decides") is
/// answered per run.
///
/// Six properties, the Worker's current cap: `tool`, `mode`, `engine`,
/// `properties`, `failed`, `undecided`. `frontend` and `solver` join when
/// the Worker accepts eight. Never a name, a path, a depth or a step.
List<Map<String, Object?>> formalRunCompletedProperties(
  Iterable<TestResult> results,
) {
  final groups = <String, _FormalRunGroup>{};
  for (final result in results) {
    final summary = FormalResultSummary.fromMetrics(result.metrics);
    if (summary == null) continue;
    final mode = kFormalRunModeTokens.contains(summary.mode)
        ? summary.mode
        : null;
    final engine = summary.engine == null
        ? null
        : (kFormalRunEngineTokens.contains(summary.engine)
              ? summary.engine
              : 'other');
    final key = '${summary.tool}|$mode|$engine';
    groups
        .putIfAbsent(
          key,
          () => _FormalRunGroup(tool: summary.tool, mode: mode, engine: engine),
        )
        .add(summary);
  }
  return <Map<String, Object?>>[
    for (final group in groups.values)
      <String, Object?>{
        'tool': group.tool,
        'mode': ?group.mode,
        'engine': ?group.engine,
        if (group.counted) ...<String, Object?>{
          'properties': telemetryCount(group.properties),
          'failed': telemetryCount(group.failed),
          'undecided': telemetryCount(group.undecided),
        },
      },
  ];
}

/// The distinct `formal.assertions.disabled.how` tokens among [results],
/// for one event per run per token.
Set<String> formalAssertionsDisabledTokens(Iterable<TestResult> results) => {
  for (final result in results)
    if (FormalResultSummary.fromMetrics(result.metrics)?.assertionsDisabled
        case final String how
        when kFormalAssertionsDisabledTokens.contains(how))
      how,
};

/// The properties of the `formal.sva.unsupported` events one run records:
/// one per distinct (construct class, frontend) among [results].
List<Map<String, Object?>> formalSvaUnsupportedProperties(
  Iterable<TestResult> results,
) {
  final seen = <String>{};
  final out = <Map<String, Object?>>[];
  for (final result in results) {
    final summary = FormalResultSummary.fromMetrics(result.metrics);
    final refusal = summary?.svaRefusal;
    if (refusal == null) continue;
    final construct = refusal.constructClass.wireName;
    final frontend = refusal.frontend.wireName;
    if (!kFormalSvaConstructTokens.contains(construct) ||
        !kFormalSvaFrontendTokens.contains(frontend)) {
      continue;
    }
    if (!seen.add('$construct|$frontend')) continue;
    out.add(<String, Object?>{'construct': construct, 'frontend': frontend});
  }
  return out;
}

/// The distinct `formal.pretrace.flagged.kind` tokens among [results], for
/// one event per run per kind.
Set<String> formalPretraceFlaggedKinds(Iterable<TestResult> results) => {
  for (final result in results)
    if (FormalResultSummary.fromMetrics(result.metrics)?.pretrace?.kind
        case final String kind when kFormalPretraceKindTokens.contains(kind))
      kind,
};

/// `debug_in_wavecrux.used.origin` for the row handed off: `eqy` for an
/// equivalence row, `formal` for any other formal row, `test` otherwise
/// (including a hand-off with no row).
String debugInWaveCruxOrigin(TestResult? result) {
  final summary = result == null
      ? null
      : FormalResultSummary.fromMetrics(result.metrics);
  if (summary == null) return 'test';
  return summary.tool == FormalResultSummary.kToolEqy ? 'eqy' : 'formal';
}

class _FormalRunGroup {
  _FormalRunGroup({required this.tool, this.mode, this.engine});

  final String tool;
  final String? mode;
  final String? engine;
  bool counted = false;
  int properties = 0;
  int failed = 0;
  int undecided = 0;

  void add(FormalResultSummary summary) {
    final n = summary.properties;
    if (n == null) return;
    counted = true;
    properties += n;
    failed += summary.propertiesFailed ?? 0;
    undecided += summary.propertiesUndecided ?? 0;
  }
}
