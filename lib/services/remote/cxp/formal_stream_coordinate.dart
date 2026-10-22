// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_cxp/crux_cxp.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/formal_property_status.dart';
import 'package:simcrux/domain/models/formal_result_summary.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/services/remote/cxp/riscv_stream_coordinate.dart';
import 'package:simcrux/services/simulator/riscv_result_kind.dart';

/// One formal property of a result row, read back from its
/// `formal.property.<n>.*` metrics.
@immutable
class FormalPropertyRef {
  /// Creates a reference.
  const FormalPropertyRef({
    required this.kind,
    required this.location,
    required this.status,
    this.label,
    this.step,
    this.trace,
    this.reads = const <String>[],
    this.id,
    this.pretraceDepth,
  });

  /// Its identity across runs (`formal.property.<n>.id`): the label, else
  /// the `crux-fnv1a64/1` signature; null when neither was recorded.
  final String? id;

  /// The `$past` depth its result reaches back before the trace began, when
  /// it does (`formal.property.<n>.pretrace`).
  final int? pretraceDepth;

  /// `assert`, `assume` or `cover`, lower-cased; whatever else the solver
  /// wrote, lower-cased.
  final String kind;

  /// Where it is (`handshake.sv:45.15-45.38`), project-relative when the
  /// run knew the project root.
  final String location;

  /// What it ended as.
  final FormalPropertyStatus status;

  /// The user's label, when the frontend kept one.
  final String? label;

  /// The step the solver reported it failing or being reached at.
  final int? step;

  /// Its trace, relative to the task directory.
  final String? trace;

  /// The signals it reads, nearest first.
  final List<String> reads;

  /// Whether it failed or was reached with a trace.
  bool get fired =>
      status == FormalPropertyStatus.counterexample ||
      status == FormalPropertyStatus.reached;

  /// The CXP `property` element path: `<file>:<line>` (CXP §8.2), or null
  /// when the location names no line.
  String? get elementPath {
    final match = RegExp(r'^(.*?):(\d+)').firstMatch(location);
    if (match == null) return null;
    return '${match.group(1)}:${match.group(2)}';
  }

  /// The registered role (`formal.property_kind`), or null for a kind CXP
  /// does not register.
  String? get registeredKind =>
      const <String>{'assert', 'assume', 'cover'}.contains(kind) ? kind : null;
}

/// The properties of a formal row (never an EQY partition), in run order.
List<FormalPropertyRef> formalPropertiesOf(Map<String, String> metrics) {
  final out = <FormalPropertyRef>[];
  for (var n = 0; ; n++) {
    final prefix = 'formal.property.$n.';
    final kind = metrics['${prefix}kind'];
    if (kind == null) break;
    if (kind == 'partition') continue;
    final reads = metrics['${prefix}reads'];
    out.add(
      FormalPropertyRef(
        kind: kind.toLowerCase(),
        location: metrics['${prefix}location'] ?? '',
        // A status this build cannot read never reads as fired.
        status:
            FormalPropertyStatus.fromWireName(metrics['${prefix}status']) ??
            FormalPropertyStatus.didNotRun,
        label: metrics['${prefix}label'],
        step: int.tryParse(metrics['${prefix}step'] ?? ''),
        trace: metrics['${prefix}trace'],
        reads: reads == null || reads.isEmpty
            ? const <String>[]
            : List<String>.unmodifiable(reads.split(',')),
        id: metrics['${prefix}id'],
        pretraceDepth: int.tryParse(metrics['${prefix}pretrace'] ?? ''),
      ),
    );
  }
  return out;
}

/// Whether [traceRelative] (relative to its task directory, `/`-separated)
/// names the file [absolute].
bool _sameTrace(String absolute, String traceRelative) {
  final a = p.normalize(absolute).replaceAll(r'\', '/');
  final r = p.posix.normalize(traceRelative.replaceAll(r'\', '/'));
  return a == r || a.endsWith('/$r');
}

/// The property [result]'s hand-off trace belongs to: the fired property
/// whose trace is the row's waveform, else the first property that fired.
/// Null for a row with no fired property.
FormalPropertyRef? formalHandoffProperty(TestResult result) {
  final properties = formalPropertiesOf(result.metrics);
  final waveform = result.waveformPath;
  if (waveform != null && waveform.isNotEmpty) {
    for (final property in properties) {
      final trace = property.trace;
      if (property.fired && trace != null && _sameTrace(waveform, trace)) {
        return property;
      }
    }
  }
  for (final property in properties) {
    if (property.status == FormalPropertyStatus.counterexample) {
      return property;
    }
  }
  for (final property in properties) {
    if (property.fired) return property;
  }
  return null;
}

/// The partitions of an EQY row that ended with a counterexample trace,
/// in run order.
List<FormalPartitionRow> failingEqyPartitions(Map<String, String> metrics) =>
    <FormalPartitionRow>[
      for (final partition in FormalResultSummary.partitionsOf(metrics))
        if (partition.status == FormalPropertyStatus.counterexample &&
            partition.trace != null)
          partition,
    ];

/// The absolute trace of [partition] of the EQY row [result].
///
/// The row's waveform is the first failing partition's trace inside the run's
/// work directory; the work directory is the waveform with that partition's
/// relative trace taken off its end, and every other trace sits under it.
/// Null when the row has no waveform or it does not end with a partition's
/// trace.
String? eqyPartitionTracePath(TestResult result, FormalPartitionRow partition) {
  final waveform = result.waveformPath;
  final relative = partition.trace;
  if (waveform == null || waveform.isEmpty || relative == null) return null;
  for (final first in failingEqyPartitions(result.metrics)) {
    final firstTrace = first.trace!;
    if (!_sameTrace(waveform, firstTrace)) continue;
    final normalized = p.normalize(waveform);
    final suffix = p.normalize(firstTrace);
    if (!normalized.endsWith(suffix)) return null;
    final base = normalized.substring(0, normalized.length - suffix.length);
    return p.normalize(p.join(base, relative));
  }
  return null;
}

/// The CXP semantic stream coordinate (CXP §9.9) the formal row [result]
/// can state for its hand-off trace, or null when it cannot state one.
///
/// * A RISC-V check row: [riscvStreamCoordinateFor], unchanged.
/// * An `sby` row: `formal.trace_step` (§9.9.3) at the step the solver
///   reported for the property whose trace is handed off, counting the
///   trace's initial state as step 0. Absent when no fired property names
///   the row's trace with a step, and for a `multiclock on` task, whose
///   witness steps are not one sample of one clock (not measured).
/// * An EQY row: the same stream for [partition] (else the first failing
///   partition), with `sub_id` the partition's name, at the step its
///   SymbiYosys summary stated. Absent when it stated none.
///
/// Never a computed step (CXP §9.9 rule 3): a missing step is no coordinate,
/// not step 0.
CxpStreamCoordinate? formalStreamCoordinateFor(
  TestResult result, {
  FormalPartitionRow? partition,
}) {
  if (RiscvResultKind.isFormalPropertyRow(result)) {
    return riscvStreamCoordinateFor(result);
  }
  final metrics = result.metrics;
  final summary = FormalResultSummary.fromMetrics(metrics);
  if (summary == null) return null;
  if (metrics['formal.multiclock'] == '1') return null;
  final attributes = <String, String>{
    CxpStreamCoordinate.formalVerdictAttribute: summary.verdictToken,
    if (summary.depthConfigured != null)
      CxpStreamCoordinate.formalDepthConfiguredAttribute:
          '${summary.depthConfigured}',
    if (metrics['formal.run_mode'] == 'demo')
      CxpStreamCoordinate.formalModeAttribute: 'demo',
  };
  if (summary.tool == FormalResultSummary.kToolEqy) {
    final failing = failingEqyPartitions(metrics);
    final chosen = partition ?? (failing.isEmpty ? null : failing.first);
    final step = chosen?.step;
    if (chosen == null || step == null || step < 0) return null;
    return CxpStreamCoordinate(
      streamId: CxpStreamCoordinate.formalTraceStepStreamId,
      sequenceIndex: step,
      subId: chosen.name,
      attributes: attributes,
    );
  }
  final waveform = result.waveformPath;
  if (waveform == null || waveform.isEmpty) return null;
  final property = formalHandoffProperty(result);
  final trace = property?.trace;
  final step = property?.step;
  if (property == null ||
      !property.fired ||
      trace == null ||
      step == null ||
      step < 0 ||
      !_sameTrace(waveform, trace)) {
    return null;
  }
  final kind = property.registeredKind;
  return CxpStreamCoordinate(
    streamId: CxpStreamCoordinate.formalTraceStepStreamId,
    sequenceIndex: step,
    attributes: <String, String>{
      ...attributes,
      CxpStreamCoordinate.formalPropertyKindAttribute: ?kind,
    },
  );
}

/// The registered `formal.` metadata (CXP §9.3.1) a counterexample hand-off
/// of [result] carries: the property's role and label for an `sby` row, the
/// gold and gate scopes for an EQY row. Empty for every other row.
///
/// EQY writes each partition's witness as one miter with the two designs in
/// sibling scopes named `gold` and `gate`.
Map<String, Object?> formalHandoffMetadata(TestResult result) {
  if (RiscvResultKind.isFormalPropertyRow(result)) {
    return const <String, Object?>{};
  }
  final summary = FormalResultSummary.fromMetrics(result.metrics);
  if (summary == null) return const <String, Object?>{};
  if (summary.tool == FormalResultSummary.kToolEqy) {
    return const <String, Object?>{
      cxpFormalEqyGoldScopeMetadataKey: 'gold',
      cxpFormalEqyGateScopeMetadataKey: 'gate',
    };
  }
  final property = formalHandoffProperty(result);
  if (property == null) return const <String, Object?>{};
  return <String, Object?>{
    cxpFormalPropertyKindMetadataKey: ?property.registeredKind,
    cxpFormalPropertyLabelMetadataKey: ?property.label,
  };
}

/// [path] without a trailing bit select (`top.q[3:0]` is `top.q`).
String signalWithoutRange(String path) {
  final bracket = path.indexOf('[');
  return (bracket > 0 ? path.substring(0, bracket) : path).trim();
}

/// Whether the signal a peer named, [inbound], is the signal [local] names.
///
/// Either may be rooted at the design top (`fifo.full`) or not (`full`, or a
/// name relative to the top, `u_div.cnt_q`): they match when they are equal,
/// or when one is the other with more of its hierarchy in front, so a bare
/// leaf matches that leaf in any scope.
bool sameSignal(String inbound, String local) {
  final a = signalWithoutRange(inbound);
  final b = signalWithoutRange(local);
  if (a.isEmpty || b.isEmpty) return false;
  return a == b || a.endsWith('.$b') || b.endsWith('.$a');
}

/// Whether the formal row [metrics] has a property that reads [signal].
bool formalRowReads(Map<String, String> metrics, String signal) {
  for (final property in formalPropertiesOf(metrics)) {
    for (final read in property.reads) {
      if (sameSignal(signal, read)) return true;
    }
  }
  return false;
}
