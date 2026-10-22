// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_flow/crux_flow.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/regression_trigger.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/trend_store.dart';
import 'package:simcrux/domain/models/flow_run_record.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/services/flow/flow_archive_extractor.dart';
import 'package:simcrux/services/flow/flow_metric_keys.dart';
import 'package:simcrux/services/flow/flow_run_importer.dart';
import 'package:simcrux/services/flow/flow_run_reading.dart';
import 'package:simcrux/services/flow/librelane_flow_driver.dart';

/// Why an ingest path produced no run.
enum FlowIngestFailure {
  /// Nothing exists at the path.
  missing,

  /// The path resolves outside every directory ingest may read from.
  outside,

  /// A zipped CI artifact that was refused: unreadable, over a size or
  /// entry limit, or holding an entry that would escape its extraction
  /// (an absolute path, a `..` segment or a symbolic link).
  archive,

  /// Neither a nextpnr report nor a LibreLane run, nor a directory of runs.
  unrecognised,
}

/// One run an ingest path named, or why it named none.
@immutable
class FlowIngestItem {
  /// Creates the item.
  const FlowIngestItem({
    required this.path,
    this.reading,
    this.failure,
    this.message,
  });

  /// The path as given, or the run directory found under it.
  final String path;

  /// The run, when one was read.
  final FlowReading? reading;

  /// Why there is no run, when there is none.
  final FlowIngestFailure? failure;

  /// The reason in words, for the user.
  final String? message;
}

/// Indexes flow runs SimCrux did not launch: a LibreLane `runs/<tag>/`, a
/// nextpnr `report.json` or the directory holding it, or a directory of
/// runs (`runs/`).
///
/// **Read-only.** Ingest never writes inside a run directory and never
/// deletes anything; every path it opens resolves inside the directories it
/// was allowed (the project root and the paths the user chose), symlinks
/// resolved.
///
/// A zipped CI artifact (a `.zip`) is extracted into SimCrux's own scratch
/// by [FlowArchiveExtractor], contained and bounded, never into the project,
/// and the runs inside are read from there.
///
/// A result is a `TestResult` with `didExecute` false, and the trend store
/// records it with the run trigger `ingest`.
class FlowRunIngestor {
  /// Creates the ingestor.
  const FlowRunIngestor({
    this.nextpnr = const NextpnrRunReader(),
    this.librelane,
    this.maxRuns = 500,
    this.archives = const FlowArchiveExtractor(),
  });

  /// Extracts zipped artifacts.
  final FlowArchiveExtractor archives;

  /// Reads nextpnr reports and logs.
  final NextpnrRunReader nextpnr;

  /// Reads LibreLane run directories; crux_flow's versioned readers
  /// ([LibreLaneVersionedReader]) when null.
  final LibreLaneRunReading? librelane;

  /// The most runs one directory of runs yields.
  final int maxRuns;

  LibreLaneRunReading get _readLibreLane =>
      librelane ?? const LibreLaneVersionedReader().read;

  /// Reads every run [paths] names. [allowedRoots] are the directories a
  /// path may resolve inside; a path outside all of them is refused.
  Future<List<FlowIngestItem>> ingest(
    List<String> paths, {
    required List<String> allowedRoots,
  }) async {
    final containment = FlowContainment(allowedRoots);
    final out = <FlowIngestItem>[];
    for (final raw in paths) {
      final path = p.normalize(p.absolute(raw));
      final type = FileSystemEntity.typeSync(path);
      if (type == FileSystemEntityType.notFound) {
        out.add(
          FlowIngestItem(
            path: raw,
            failure: FlowIngestFailure.missing,
            message: 'nothing exists at this path',
          ),
        );
        continue;
      }
      final String resolved;
      try {
        resolved = containment.require(path);
      } on FlowContainmentException catch (e) {
        out.add(
          FlowIngestItem(
            path: raw,
            failure: FlowIngestFailure.outside,
            message: e.reason,
          ),
        );
        continue;
      }
      if (type == FileSystemEntityType.file) {
        out.addAll(
          p.extension(resolved).toLowerCase() == '.zip'
              ? await _readArchive(raw, resolved)
              : await _readFile(raw, resolved),
        );
      } else {
        out.addAll(await _readDirectory(raw, resolved, containment));
      }
    }
    return out;
  }

  Future<List<FlowIngestItem>> _readFile(String raw, String path) async {
    final ext = p.extension(path).toLowerCase();
    if (ext == '.json') {
      return <FlowIngestItem>[
        FlowIngestItem(path: raw, reading: await nextpnr.readReport(path)),
      ];
    }
    if (ext == '.log') {
      return <FlowIngestItem>[
        FlowIngestItem(path: raw, reading: await nextpnr.readLog(path)),
      ];
    }
    return <FlowIngestItem>[
      FlowIngestItem(
        path: raw,
        failure: FlowIngestFailure.unrecognised,
        message: 'not a nextpnr report, a nextpnr log or a run directory',
      ),
    ];
  }

  /// Extracts the zip at [path] into SimCrux's scratch and reads the runs
  /// inside, contained to the extraction.
  Future<List<FlowIngestItem>> _readArchive(String raw, String path) async {
    final extraction = await archives.extract(path);
    final dir = extraction.directory;
    if (dir == null) {
      return <FlowIngestItem>[
        FlowIngestItem(
          path: raw,
          failure: FlowIngestFailure.archive,
          message: 'the zipped artifact was not opened: ${extraction.message}',
        ),
      ];
    }
    final items = await _readDirectory(
      raw,
      dir,
      FlowContainment(<String>[dir]),
      depth: 4,
    );
    return <FlowIngestItem>[
      for (final item in items)
        if (item.reading == null)
          FlowIngestItem(
            path: raw,
            failure: item.failure,
            message:
                'no nextpnr report and no LibreLane run in the zipped '
                'artifact',
          )
        else
          item,
    ];
  }

  /// The runs in [dir]: [dir] itself, or a directory of runs, `runs/<tag>/`
  /// (LibreLane) or `runs/<entry>/<tag>/` (SimCrux's nextpnr runs), [depth]
  /// levels at most. A zipped artifact is searched deeper, because it
  /// usually wraps the `runs/` directory in one or two of its own.
  Future<List<FlowIngestItem>> _readDirectory(
    String raw,
    String dir,
    FlowContainment containment, {
    int depth = 2,
  }) async {
    final single = await _readRun(dir);
    if (single != null) return <FlowIngestItem>[single];
    final found = <FlowIngestItem>[];
    Future<void> walk(String at, int left) async {
      for (final child in _subdirectories(at, containment)) {
        if (found.length >= maxRuns) return;
        final run = await _readRun(child);
        if (run != null) {
          found.add(run);
        } else if (left > 1) {
          await walk(child, left - 1);
        }
      }
    }

    await walk(dir, depth);
    if (found.isNotEmpty) return found;
    return <FlowIngestItem>[
      FlowIngestItem(
        path: raw,
        failure: FlowIngestFailure.unrecognised,
        message: 'no nextpnr report and no LibreLane run under this directory',
      ),
    ];
  }

  Future<FlowIngestItem?> _readRun(String dir) async {
    if (File(p.join(dir, 'report.json')).existsSync() ||
        File(p.join(dir, 'pnr.log')).existsSync()) {
      return FlowIngestItem(
        path: dir,
        reading: await nextpnr.readRunDir(dir, logFallback: true),
      );
    }
    if (LibreLaneVersionedReader.looksLikeRun(dir)) {
      return FlowIngestItem(path: dir, reading: await _readLibreLane(dir));
    }
    return null;
  }

  static List<String> _subdirectories(
    String dir,
    FlowContainment containment,
  ) {
    try {
      final dirs = <String>[
        for (final e in Directory(dir).listSync(followLinks: false))
          if (e is Directory && containment.allows(e.path)) e.path,
      ]..sort();
      return dirs;
    } on FileSystemException {
      return const <String>[];
    }
  }

  /// The test id an ingested [reading] is filed under: `flow/<design>`,
  /// the directory above `runs/` when the run sits in one, so an ingested
  /// SimCrux nextpnr run (`runs/<entry>/<tag>/`) joins its entry's history.
  static String testIdFor(FlowReading reading) {
    final root = reading.run.ref.root;
    final parent = p.dirname(root);
    final String design;
    if (p.basename(parent) == 'runs') {
      design = p.basename(p.dirname(parent));
    } else if (p.basename(p.dirname(parent)) == 'runs') {
      design = p.basename(parent);
    } else {
      design = p.basename(root);
    }
    return FlowRunImporter.specIdFor(design.isEmpty ? 'run' : design);
  }

  /// The run id an ingested [reading] is filed under. Stable for one run
  /// directory, so ingesting it twice records it once.
  static String runIdFor(FlowReading reading) {
    final tag = reading.run.ref.tag.replaceAll(RegExp('[^A-Za-z0-9._-]'), '_');
    return 'ingest-${reading.run.ref.kind.wireName}-$tag-'
        '${_fnv32(reading.run.ref.root)}';
  }

  static String _fnv32(String text) {
    var hash = 0x811c9dc5;
    for (final unit in text.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  /// The result row for an ingested [reading]: `didExecute` false, the
  /// verdict deciding pass or fail, the flow metrics attached.
  static TestResult resultFor(FlowReading reading, {required DateTime now}) =>
      TestResult(
        testId: testIdFor(reading),
        runId: runIdFor(reading),
        status: reading.verdict == FlowVerdict.met
            ? TestStatus.pass
            : TestStatus.fail,
        startedAt: reading.run.startedAt ?? now,
        finishedAt: reading.run.finishedAt ?? reading.run.startedAt ?? now,
        metrics: reading.toMetrics(),
        didExecute: false,
      );

  /// [reading] as the trend store's flow rows for [runId] and [testId].
  static FlowRunRecord recordFor(
    FlowReading reading, {
    required String runId,
    required String testId,
  }) => FlowRunRecord(
    runId: runId,
    testId: testId,
    steps: <FlowStepRow>[
      for (final step in reading.run.steps)
        FlowStepRow(
          ordinal: step.ordinal,
          id: step.id,
          tool: step.tool,
          status: step.status.wireName,
          runtimeMs: step.runtime?.inMilliseconds,
        ),
    ],
    metrics: <FlowMetricRow>[
      for (final MapEntry(:key, :value) in reading.run.metrics.entries)
        if (MetricKey.tryParse(key) case final parsed?)
          FlowMetricRow(
            key: key,
            base: parsed.base,
            modifiers: <String, String>{
              for (final m in parsed.modifiers) m.name: m.value,
            },
            valueReal: value is num ? value.toDouble() : null,
            valueText: value is num || value == null ? null : '$value',
            aggregated: reading.aggregatedKeys.contains(key),
          ),
    ],
  );

  /// Records every read run in [items] in [store]: one result row with the
  /// trigger `ingest`, and its flow rows. A run already recorded is skipped.
  /// Returns how many were recorded.
  static Future<int> persist(
    TrendStore store,
    List<FlowIngestItem> items, {
    DateTime? now,
  }) async {
    final stamp = (now ?? DateTime.now()).toUtc();
    var recorded = 0;
    for (final item in items) {
      final reading = item.reading;
      if (reading == null) continue;
      final result = resultFor(reading, now: stamp);
      if ((await store.pointsForRun(result.runId)).isNotEmpty) continue;
      await store.recordTrendPoints(<TrendPoint>[
        TrendPoint(
          runId: result.runId,
          testId: result.testId,
          status: result.status,
          runtime: result.runtime,
          startedAt: result.startedAt,
          suiteName: FlowRunImporter.kFlowSuiteName,
          trigger: RegressionTrigger.ingest,
        ),
      ]);
      await store.recordFlowRun(
        recordFor(reading, runId: result.runId, testId: result.testId),
      );
      recorded++;
    }
    return recorded;
  }

  /// Re-reads the run a launched flow result names
  /// ([FlowMetricKeys.runDir]), for its full metric set. Null when the
  /// result is not a flow result or its run cannot be read. [librelane]
  /// reads a LibreLane run ([LibreLaneVersionedReader] when null).
  static Future<FlowReading?> readForResult(
    Map<String, String> metrics, {
    LibreLaneRunReading? librelane,
  }) async {
    final root = metrics[FlowMetricKeys.runDir];
    final kind = metrics[FlowMetricKeys.kind];
    if (root == null || root.isEmpty || kind == null) return null;
    if (!Directory(root).existsSync()) return null;
    final tag = metrics[FlowMetricKeys.tag];
    if (kind == FlowKind.librelane.wireName) {
      final read = librelane ?? const LibreLaneVersionedReader().read;
      return await read(root, tag: tag);
    }
    if (kind == FlowKind.nextpnr.wireName) {
      return await const NextpnrRunReader().readRunDir(
        root,
        tag: tag,
        logFallback: true,
      );
    }
    return null;
  }
}
