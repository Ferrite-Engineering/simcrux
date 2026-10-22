// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:crux_flow/crux_flow.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/services/flow/flow_run_reading.dart';

/// One worst timing path with where its ends and segments land in the RTL.
@immutable
class FlowPathRow {
  /// Creates the row.
  const FlowPathRow({
    required this.path,
    this.startpoint = RtlMapping.unmapped,
    this.endpoint = RtlMapping.unmapped,
    this.segments = const <RtlMapping>[],
  });

  /// The path as the tool reported it.
  final TimingPath path;

  /// Where the path's start lands.
  final RtlMapping startpoint;

  /// Where the path's end lands.
  final RtlMapping endpoint;

  /// One mapping per segment, in path order; empty when nothing was mapped.
  final List<RtlMapping> segments;

  /// The path's fidelity: the less precise of its two ends, so a path is
  /// never labelled better than its weaker end.
  MappingFidelity get fidelity =>
      startpoint.fidelity.index >= endpoint.fidelity.index
      ? startpoint.fidelity
      : endpoint.fidelity;

  /// The mapping of segment [index], unmapped when there is none.
  RtlMapping segmentMapping(int index) =>
      index < segments.length ? segments[index] : RtlMapping.unmapped;
}

/// Why a run lists no worst paths, when it lists none.
enum FlowWorstPathsGap {
  /// The run's report lists no critical paths.
  none,

  /// A LibreLane run: its path reports are not read yet; the slack and
  /// violation counts are in its metrics.
  librelaneNotRead,

  /// The run's report could not be read.
  unreadable,
}

/// The worst paths of one run.
@immutable
class FlowWorstPaths {
  /// Creates the result.
  FlowWorstPaths({
    List<FlowPathRow> rows = const <FlowPathRow>[],
    this.mapped = false,
    this.gap,
  }) : rows = List<FlowPathRow>.unmodifiable(rows);

  /// The paths, worst first.
  final List<FlowPathRow> rows;

  /// Whether a synthesised netlist was found to map the paths against.
  final bool mapped;

  /// Why [rows] is empty, when it is.
  final FlowWorstPathsGap? gap;
}

/// Reads the worst paths of the run [ref] names and maps each to the RTL.
///
/// nextpnr: the paths are the report's `critical_paths`; the registers come
/// from the run's synthesised netlist (`synth.json`) and the spans from the
/// placed one (`post.json`, else `synth.json`) when the run holds them. An
/// ingested report with neither lists its paths unmapped. Every file read
/// resolves inside the run directory and is size-capped.
///
/// Reads whole files, so the app calls it off the UI isolate.
Future<FlowWorstPaths> readFlowWorstPaths(
  FlowRunRef ref, {
  FlowInputLimits limits = FlowInputLimits.defaults,
}) async {
  if (ref.kind == FlowKind.librelane) {
    return FlowWorstPaths(gap: FlowWorstPathsGap.librelaneNotRead);
  }
  final root = ref.root;
  final reading = await NextpnrRunReader(limits: limits).readRunDir(root);
  final paths = reading.run.timing;
  if (paths.isEmpty) {
    return FlowWorstPaths(
      gap: reading.nextpnrReport == null
          ? FlowWorstPathsGap.unreadable
          : FlowWorstPathsGap.none,
    );
  }
  final resolver = await _resolverFor(root, limits);
  if (resolver == null) {
    return FlowWorstPaths(
      rows: <FlowPathRow>[for (final path in paths) FlowPathRow(path: path)],
    );
  }
  return FlowWorstPaths(
    mapped: true,
    rows: <FlowPathRow>[
      for (final path in paths)
        if (_map(resolver, path) case final mapping)
          FlowPathRow(
            path: path,
            startpoint: mapping.startpoint,
            endpoint: mapping.endpoint,
            segments: mapping.segments,
          ),
    ],
  );
}

TimingPathMapping _map(RtlRegisterResolver resolver, TimingPath path) {
  try {
    return resolver.resolvePath(path);
  } on FlowReadException {
    return TimingPathMapping(
      startpoint: RtlMapping.unmapped,
      endpoint: RtlMapping.unmapped,
      segments: <RtlMapping>[
        for (final _ in path.segments) RtlMapping.unmapped,
      ],
    );
  }
}

Future<RtlRegisterResolver?> _resolverFor(
  String root,
  FlowInputLimits limits,
) async {
  final containment = FlowContainment(<String>[root]);
  String? contained(String name) {
    final path = p.join(root, name);
    if (!File(path).existsSync()) return null;
    try {
      return containment.require(path);
    } on FlowContainmentException {
      return null;
    }
  }

  final synth = contained('synth.json');
  if (synth == null) return null;
  try {
    final registers = await RtlRegisterSet.read(synth, limits: limits);
    final placed = contained('post.json') ?? synth;
    final index = await NetlistSrcIndex.read(placed, limits: limits);
    return RtlRegisterResolver(registers, index: index);
  } on FlowReadException {
    return null;
  } on FileSystemException {
    return null;
  }
}

/// The tail of one log: at most a few hundred lines from its end.
@immutable
class FlowLogTail {
  /// Creates the tail.
  FlowLogTail({
    required this.path,
    List<String> lines = const <String>[],
    this.truncated = false,
  }) : lines = List<String>.unmodifiable(lines);

  /// The log file.
  final String path;

  /// The last lines, oldest first.
  final List<String> lines;

  /// Whether the log holds more than [lines].
  final bool truncated;
}

/// The log a step of [run] wrote: its own `logPath`, else the largest
/// `*.log` in its directory; for a run with no steps, the run's own
/// `pnr.log`. Null when there is none inside the run directory.
String? flowStepLogPath(FlowRun run, FlowStep? step) {
  final containment = FlowContainment(<String>[run.ref.root]);
  String? inside(String path) {
    try {
      return containment.require(path);
    } on FlowContainmentException {
      return null;
    }
  }

  if (step == null) {
    for (final name in const <String>['pnr.log', 'next.log', 'flow.log']) {
      final path = p.join(run.ref.root, name);
      if (File(path).existsSync()) return inside(path);
    }
    return null;
  }
  final own = step.logPath;
  if (own != null) {
    final path = p.isAbsolute(own) ? own : p.join(run.ref.root, own);
    if (File(path).existsSync()) return inside(path);
  }
  File? largest;
  var size = -1;
  try {
    for (final entity in Directory(step.dir).listSync(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.log')) continue;
      final length = entity.lengthSync();
      if (length > size) {
        size = length;
        largest = entity;
      }
    }
  } on FileSystemException {
    return null;
  }
  return largest == null ? null : inside(largest.path);
}

/// Reads the last [maxBytes] of the log at [path], at most [maxLines] lines.
///
/// Bounded: only the tail is read, never the whole file.
Future<FlowLogTail> readFlowLogTail(
  String path, {
  int maxBytes = 64 * 1024,
  int maxLines = 200,
}) async {
  final file = File(path);
  final RandomAccessFile raf;
  try {
    raf = await file.open();
  } on FileSystemException {
    return FlowLogTail(path: path);
  }
  try {
    final length = await raf.length();
    final start = length > maxBytes ? length - maxBytes : 0;
    await raf.setPosition(start);
    final bytes = await raf.read(length - start);
    final text = utf8.decode(bytes, allowMalformed: true);
    var lines = text.split('\n');
    // A tail that starts mid-file starts mid-line; drop the fragment.
    if (start > 0 && lines.isNotEmpty) lines = lines.sublist(1);
    if (lines.isNotEmpty && lines.last.isEmpty) {
      lines = lines.sublist(0, lines.length - 1);
    }
    final cut = lines.length > maxLines;
    if (cut) lines = lines.sublist(lines.length - maxLines);
    return FlowLogTail(
      path: path,
      lines: <String>[for (final l in lines) l.replaceAll('\r', '')],
      truncated: cut || start > 0,
    );
  } on FileSystemException {
    return FlowLogTail(path: path);
  } finally {
    await raf.close();
  }
}
