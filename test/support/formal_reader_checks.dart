// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:simcrux/domain/enums/formal_bucket.dart';
import 'package:simcrux/domain/enums/formal_property_status.dart';
import 'package:simcrux/services/formal/formal_reconciliation.dart';
import 'package:simcrux/services/simulator/sby_driver.dart';

import 'formal_fixture_checks.dart';

/// One property as the product reported it, from either a
/// [FormalReconciliation] or the `formal.property.<n>.*` metrics a driver
/// recorded.
class ReportedProperty {
  ReportedProperty({
    required this.kind,
    required this.line,
    required this.status,
    this.label,
    this.step,
    this.trace,
  });

  final String kind;
  final int? line;
  final FormalPropertyStatus status;
  final String? label;
  final int? step;
  final String? trace;
}

/// The properties of [reconciliation].
List<ReportedProperty> reportedFromReconciliation(
  FormalReconciliation reconciliation,
) => [
  for (final r in reconciliation.properties)
    ReportedProperty(
      kind: r.kind,
      line: r.line,
      status: r.status,
      label: r.label,
      step: r.step,
      trace: r.trace,
    ),
];

/// The properties a driver recorded in [metrics].
List<ReportedProperty> reportedFromMetrics(Map<String, String> metrics) {
  final out = <ReportedProperty>[];
  for (var n = 0; ; n++) {
    String? field(String name) =>
        metrics['${SbyDriver.kPropertyPrefix}$n.$name'];
    final status = field('status');
    if (status == null) break;
    final location = field('location') ?? '';
    final line = RegExp(r':(\d+)').firstMatch(location)?.group(1);
    out.add(
      ReportedProperty(
        kind: field('kind') ?? '',
        line: line == null ? null : int.parse(line),
        status: FormalPropertyStatus.fromWireName(status)!,
        label: field('label'),
        step: int.tryParse(field('step') ?? ''),
        trace: field('trace'),
      ),
    );
  }
  return out;
}

/// Problems with what SimCrux reported for one sby task ([verdict] and
/// [properties]), against that task's hand-written expectation (an entry of
/// `tasks` in a `*.expected.json`). [taskDirectory] holds its traces.
///
/// The product-side twin of `checkSbyCase`: that one checks the tool's raw
/// output against the expectation, this one checks the readers and the
/// agreement rule against the same expectation.
List<String> checkReportedTask({
  required String task,
  required Map<String, Object?> spec,
  required String verdict,
  required List<ReportedProperty> properties,
  required String taskDirectory,
}) {
  final problems = <String>[];
  if (verdict != spec['verdict']) {
    problems.add('$task: verdict $verdict, expected ${spec['verdict']}');
  }
  final expected = objectList(spec['properties']);
  if (expected.isEmpty && properties.isNotEmpty) {
    problems.add(
      '$task: expected no checked property, found ${properties.length}',
    );
  }
  for (final prop in expected) {
    final line = prop['line']! as int;
    final kind = prop['kind']! as String;
    final label = prop['label'] as String?;
    final matches = properties
        .where((r) => r.line == line && r.kind == kind)
        .toList();
    final where = '$task line $line';
    final result = prop['result'];
    if (matches.isEmpty) {
      // An undecided property with no record anywhere may be absent from a
      // stream-only read; that still satisfies "did not fail".
      if (result != 'not_failed') problems.add('$where: no property found');
      continue;
    }
    final found = matches.single;
    if (label != null && found.label != label) {
      problems.add('$where: label ${found.label}, expected $label');
    }
    if (label == null && found.label != null) {
      problems.add('$where: label ${found.label}, expected none (mangled)');
    }
    switch (result) {
      case 'proved':
        if (found.status != FormalPropertyStatus.proved) {
          problems.add('$where: ${found.status.wireName}, expected proved');
        }
      case 'not_failed':
        if (found.status.bucket == FormalBucket.counterexample) {
          problems.add('$where: ${found.status.wireName}, must not fail');
        }
      case 'counterexample':
        if (found.status != FormalPropertyStatus.counterexample) {
          problems.add(
            '$where: ${found.status.wireName}, expected counterexample',
          );
          continue;
        }
        if (prop['step'] case final int step when found.step != step) {
          problems.add('$where: step ${found.step}, expected $step');
        }
        if (prop['step_at_least'] case final int min
            when (found.step ?? -1) < min) {
          problems.add('$where: step ${found.step}, expected at least $min');
        }
        problems.addAll(_traceProblems(where, prop, found, taskDirectory));
      case 'reached':
        if (found.status != FormalPropertyStatus.reached) {
          problems.add('$where: ${found.status.wireName}, expected reached');
          continue;
        }
        if (prop['step'] case final int step when found.step != step) {
          problems.add('$where: reached at ${found.step}, expected $step');
        }
        problems.addAll(_traceProblems(where, prop, found, taskDirectory));
      default:
        problems.add('$where: unknown expected result $result');
    }
  }
  return problems;
}

List<String> _traceProblems(
  String where,
  Map<String, Object?> prop,
  ReportedProperty found,
  String taskDirectory,
) {
  final check = prop['trace_check'] as Map<String, Object?>?;
  if (check == null) return const [];
  final trace = found.trace;
  if (trace == null) return ['$where: no trace recorded'];
  final resolved = SbyDriver().resolveTrace(trace, taskDirectory);
  if (resolved == null) return ['$where: trace $trace does not resolve'];
  return checkTrace(
    check,
    File(resolved).readAsStringSync(),
  ).map((m) => '$where: $m').toList();
}
