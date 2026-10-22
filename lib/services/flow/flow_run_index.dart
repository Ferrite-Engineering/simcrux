// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_flow/crux_flow.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/models/flow_config.dart';
import 'package:simcrux/services/flow/flow_archive_extractor.dart';
import 'package:simcrux/services/flow/flow_run_importer.dart';
import 'package:simcrux/services/flow/flow_run_ingestor.dart';
import 'package:simcrux/services/flow/flow_run_reading.dart';

/// Where a run in the Flow Runs panel came from.
enum FlowRunOrigin {
  /// A run of one of the project's own `flow:` entries, found under the
  /// project's run directories.
  project,

  /// A run the project's `ingest:` list or the user named.
  ingested,
}

/// One run the Flow Runs panel lists.
@immutable
class FlowRunIndexEntry {
  /// Creates the entry.
  const FlowRunIndexEntry({
    required this.reading,
    required this.origin,
    this.modified,
  });

  /// The run as read.
  final FlowReading reading;

  /// Where it came from.
  final FlowRunOrigin origin;

  /// When the run directory last changed, for ordering.
  final DateTime? modified;

  /// The run directory.
  String get root => reading.run.ref.root;

  /// The test id the run is filed under (`flow/<design>`).
  String get testId => FlowRunIngestor.testIdFor(reading);

  /// The design the run belongs to: the entry name, or the directory above
  /// `runs/`.
  String get design {
    final id = testId;
    const prefix = '${FlowRunImporter.kFlowSuiteName}/';
    return id.startsWith(prefix) ? id.substring(prefix.length) : id;
  }
}

/// Every run the Flow Runs panel lists for one project, newest first, and
/// what could not be read.
@immutable
class FlowRunIndex {
  /// Creates the index.
  FlowRunIndex({
    List<FlowRunIndexEntry> runs = const <FlowRunIndexEntry>[],
    List<String> problems = const <String>[],
  }) : runs = List<FlowRunIndexEntry>.unmodifiable(runs),
       problems = List<String>.unmodifiable(problems);

  /// The empty index.
  static final FlowRunIndex empty = FlowRunIndex();

  /// The runs, newest first.
  final List<FlowRunIndexEntry> runs;

  /// One line per ingest path that named no run, for the panel to show.
  final List<String> problems;

  /// The run whose directory is [root], or null.
  FlowRunIndexEntry? byRoot(String? root) {
    if (root == null) return null;
    for (final run in runs) {
      if (run.root == root) return run;
    }
    return null;
  }

  /// The run of the same design just before [entry], or null: what the
  /// last-run delta compares against.
  FlowRunIndexEntry? previousOf(FlowRunIndexEntry entry) {
    final at = runs.indexOf(entry);
    if (at < 0) return null;
    for (var i = at + 1; i < runs.length; i++) {
      if (runs[i].testId == entry.testId) return runs[i];
    }
    return null;
  }
}

/// What one index is built from: the project, its entries, its `ingest:`
/// paths and the paths the user ingested this session.
@immutable
class FlowRunIndexRequest {
  /// Creates the request.
  FlowRunIndexRequest({
    required this.projectRoot,
    List<FlowEntry> entries = const <FlowEntry>[],
    List<String> configIngest = const <String>[],
    List<String> userIngest = const <String>[],
    this.archiveScratch,
  }) : entries = List<FlowEntry>.unmodifiable(entries),
       configIngest = List<String>.unmodifiable(configIngest),
       userIngest = List<String>.unmodifiable(userIngest);

  /// The project directory; every project run and every `ingest:` path
  /// resolves inside it.
  final String projectRoot;

  /// The project's `flow:` entries.
  final List<FlowEntry> entries;

  /// The project's `ingest:` paths, as written.
  final List<String> configIngest;

  /// The paths the user chose to ingest; each may be read within itself.
  final List<String> userIngest;

  /// Where zipped artifacts are extracted; SimCrux's default when null.
  final String? archiveScratch;

  /// The run directories the project's own entries write into.
  List<String> get entryRunDirs => <String>[
    for (final entry in entries) ?_runsDirOf(entry),
  ];

  String? _runsDirOf(FlowEntry entry) {
    switch (entry.kind) {
      case FlowKind.nextpnr:
        return p.join(projectRoot, 'runs', entry.name);
      case FlowKind.librelane:
        final config = entry.config;
        if (config == null) return null;
        final absolute = p.isAbsolute(config)
            ? config
            : p.join(projectRoot, config);
        return p.join(p.dirname(p.normalize(absolute)), 'runs');
    }
  }

  @override
  bool operator ==(Object other) =>
      other is FlowRunIndexRequest &&
      other.projectRoot == projectRoot &&
      _listEq(other.entries, entries) &&
      _listEq(other.configIngest, configIngest) &&
      _listEq(other.userIngest, userIngest) &&
      other.archiveScratch == archiveScratch;

  @override
  int get hashCode => Object.hash(
    projectRoot,
    Object.hashAll(entries),
    Object.hashAll(configIngest),
    Object.hashAll(userIngest),
    archiveScratch,
  );
}

/// Builds the index [request] describes. Read-only: it lists and reads run
/// directories and writes nothing in any of them (a zipped artifact is
/// extracted into SimCrux's own scratch).
///
/// Reads whole report and metrics files, so the app calls it off the UI
/// isolate.
Future<FlowRunIndex> buildFlowRunIndex(
  FlowRunIndexRequest request, {
  FlowRunIngestor? ingestor,
}) async {
  final reader =
      ingestor ??
      FlowRunIngestor(
        archives: FlowArchiveExtractor(scratch: request.archiveScratch),
      );
  final byRoot = <String, FlowRunIndexEntry>{};
  final problems = <String>[];

  Future<void> add(
    List<String> paths,
    List<String> allowed,
    FlowRunOrigin origin, {
    bool reportMissing = true,
  }) async {
    if (paths.isEmpty) return;
    final items = await reader.ingest(paths, allowedRoots: allowed);
    for (final item in items) {
      final reading = item.reading;
      if (reading == null) {
        if (reportMissing || item.failure != FlowIngestFailure.missing) {
          problems.add('${item.path}: ${item.message}');
        }
        continue;
      }
      final root = reading.run.ref.root;
      byRoot.putIfAbsent(
        root,
        () => FlowRunIndexEntry(
          reading: reading,
          origin: origin,
          modified: _modified(root),
        ),
      );
    }
  }

  // The project's own runs: directories that do not exist yet are no news.
  final runDirs = <String>[
    for (final dir in request.entryRunDirs)
      if (Directory(dir).existsSync()) dir,
  ];
  await add(
    runDirs,
    <String>[
      request.projectRoot,
    ],
    FlowRunOrigin.project,
    reportMissing: false,
  );
  await add(
    <String>[
      for (final path in request.configIngest)
        if (p.isAbsolute(path)) path else p.join(request.projectRoot, path),
    ],
    <String>[request.projectRoot],
    FlowRunOrigin.ingested,
  );
  for (final path in request.userIngest) {
    final type = FileSystemEntity.typeSync(path);
    final root = type == FileSystemEntityType.directory
        ? path
        : p.dirname(path);
    await add(<String>[path], <String>[root], FlowRunOrigin.ingested);
  }

  final runs = byRoot.values.toList()
    ..sort((a, b) {
      final am = a.modified;
      final bm = b.modified;
      if (am != null && bm != null) {
        final byTime = bm.compareTo(am);
        if (byTime != 0) return byTime;
      }
      return b.reading.run.ref.tag.compareTo(a.reading.run.ref.tag);
    });
  return FlowRunIndex(runs: runs, problems: problems);
}

/// When the run at [root] last wrote its result: its report or final
/// metrics, else the directory itself.
DateTime? _modified(String root) {
  for (final name in const <String>['report.json', 'final/metrics.json']) {
    final stat = FileStat.statSync(p.join(root, name));
    if (stat.type == FileSystemEntityType.file) return stat.modified;
  }
  final stat = FileStat.statSync(root);
  return stat.type == FileSystemEntityType.notFound ? null : stat.modified;
}

/// The metric the last-run delta chip compares, and how the two runs differ
/// on it.
@immutable
class FlowRunDelta {
  /// Creates the delta.
  const FlowRunDelta({
    required this.kind,
    required this.current,
    required this.previous,
  });

  /// Which number is compared.
  final FlowDeltaKind kind;

  /// This run's value.
  final double current;

  /// The previous run's value.
  final double previous;

  /// [current] less [previous].
  double get change => current - previous;

  /// Whether this run is better on [kind]; null when the two are equal.
  bool? get improved {
    if (change == 0) return null;
    return change > 0;
  }
}

/// What the last-run delta compares: worst setup slack where both runs have
/// one, else the achieved clock (nextpnr). Higher is better for both.
enum FlowDeltaKind {
  /// Worst setup slack, in nanoseconds.
  worstSlack,

  /// The lowest achieved clock frequency, in MHz.
  fmax,
}

/// The delta between [current] and [previous] (the same design's run before
/// it), or null when they share no number to compare.
FlowRunDelta? flowRunDelta(FlowReading current, FlowReading? previous) {
  if (previous == null) return null;
  final wns = current.wnsNs;
  final wnsBefore = previous.wnsNs;
  if (wns != null && wnsBefore != null) {
    return FlowRunDelta(
      kind: FlowDeltaKind.worstSlack,
      current: wns,
      previous: wnsBefore,
    );
  }
  final fmax = current.fmaxMhz;
  final fmaxBefore = previous.fmaxMhz;
  if (fmax != null && fmaxBefore != null) {
    return FlowRunDelta(
      kind: FlowDeltaKind.fmax,
      current: fmax,
      previous: fmaxBefore,
    );
  }
  return null;
}

bool _listEq<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
