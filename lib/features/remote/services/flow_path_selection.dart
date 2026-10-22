// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_cxp/crux_cxp.dart';
import 'package:crux_cxp_ui/crux_cxp_ui.dart';
import 'package:crux_flow/crux_flow.dart';
import 'package:meta/meta.dart';
import 'package:simcrux/services/flow/flow_worst_paths.dart';

/// One worst-path row of one flow run, with what a cross-probe of it needs
/// to name its registers.
@immutable
class FlowPathTarget {
  /// Creates a target.
  const FlowPathTarget({
    required this.run,
    required this.row,
    this.design,
    this.top,
    this.designId,
  });

  /// The run the path belongs to.
  final FlowRunRef run;

  /// The flow entry (design) the run belongs to, when known.
  final String? design;

  /// The path and where its ends land in the RTL.
  final FlowPathRow row;

  /// The design's top module, when the flow entry names it: the root every
  /// register name is written under (`top.u_div.cnt_q`). Without it the names
  /// are relative to the top (`u_div.cnt_q`), which a receiver places in the
  /// scope it shows.
  final String? top;

  /// The project's `crux.design_id`.
  final String? designId;

  /// The opaque `timing_path` id: the run's tag and the path's rank
  /// (CXP §8.2 `<run id>/<rank>`).
  String get timingPathId => '${run.tag}/${row.path.rank}';

  String? _register(RtlMapping mapping) {
    final name = mapping.register;
    if (name == null || name.isEmpty) return null;
    final root = top;
    return root == null || root.isEmpty ? name : '$root.$name';
  }

  /// The mapped start register's signal path, or null.
  String? get startRegister => _register(row.startpoint);

  /// The mapped end register's signal path, or null.
  String? get endRegister => _register(row.endpoint);

  /// The statement spans behind the path, endpoint first, at most
  /// [kMaxFlowPathStatements], each `<file>:<line>` as synthesis recorded the
  /// file.
  List<SrcSpan> get statements {
    final out = <SrcSpan>[];
    void add(Iterable<SrcSpan> spans) {
      for (final span in spans) {
        if (out.length >= kMaxFlowPathStatements) return;
        if (!out.any((s) => sameSourceRange(s, span))) out.add(span);
      }
    }

    add(row.endpoint.spans);
    add(row.startpoint.spans);
    for (final segment in row.segments) {
      if (segment.fidelity == MappingFidelity.statement) add(segment.spans);
    }
    return out;
  }
}

/// The most statement spans a path's selection names.
const int kMaxFlowPathStatements = 8;

ElementId _statement(SrcSpan span) =>
    ElementId(kind: ElementKind.source, path: '${span.file}:${span.startLine}');

/// What a directed cross-probe of [target] offers each peer: the mapped
/// endpoint register first, then the start register, the statements, and
/// the opaque `timing_path` last (CXP §8.2: a peer that can act only on the
/// elements beside a path is sent a signal, never the path). The shared
/// element-kind table picks per target: WaveCrux and NetCrux get the
/// endpoint register, LintCrux a statement.
CrossProbeSelection flowPathCrossProbeSelection(FlowPathTarget target) {
  final end = target.endRegister;
  final start = target.startRegister;
  return CrossProbeSelection(
    candidates: <ElementId>[
      if (end != null) ElementId(kind: ElementKind.signal, path: end),
      if (start != null && start != end)
        ElementId(kind: ElementKind.signal, path: start),
      for (final span in target.statements) _statement(span),
      ElementId(kind: ElementKind.timingPath, path: target.timingPathId),
    ],
    displayName: _displayName(target),
    metadata: _metadata(target),
  );
}

/// The whole path as one `notify_selection` (CXP §8.2, Flow §9.1): the
/// `timing_path`, the `signal` elements for its mapped start and end
/// registers in path order, and the `source` elements for its statements,
/// with `crux.mapping` saying how the registers were mapped. A peer that does
/// not know `timing_path` still highlights the registers.
NotifySelection flowPathNotifySelection(FlowPathTarget target) {
  final start = target.startRegister;
  final end = target.endRegister;
  return NotifySelection(
    elements: <ElementId>[
      ElementId(kind: ElementKind.timingPath, path: target.timingPathId),
      if (start != null) ElementId(kind: ElementKind.signal, path: start),
      if (end != null && end != start)
        ElementId(kind: ElementKind.signal, path: end),
      for (final span in target.statements) _statement(span),
    ],
    displayName: _displayName(target),
    metadata: _metadata(target),
  );
}

String _displayName(FlowPathTarget target) =>
    target.endRegister ?? target.row.path.endpoint;

Map<String, Object?> _metadata(FlowPathTarget target) => <String, Object?>{
  cxpMappingMetadataKey: target.row.fidelity.wireName,
  cxpDesignIdMetadataKey: ?target.designId,
};

/// Whether the path [row] starts or ends at the register a peer named,
/// [signal] (rooted or not; see [FlowPathTarget.top]).
bool flowPathThroughRegister(FlowPathRow row, String signal, {String? top}) {
  bool matches(RtlMapping mapping) {
    final name = mapping.register;
    if (name == null || name.isEmpty) return false;
    final local = _withoutRange(name);
    final wanted = _withoutRange(signal);
    final rooted = top == null || top.isEmpty ? local : '$top.$local';
    return wanted == local ||
        wanted == rooted ||
        wanted.endsWith('.$local') ||
        local.endsWith('.$wanted');
  }

  return matches(row.startpoint) || matches(row.endpoint);
}

String _withoutRange(String path) {
  final bracket = path.indexOf('[');
  return (bracket > 0 ? path.substring(0, bracket) : path).trim();
}
