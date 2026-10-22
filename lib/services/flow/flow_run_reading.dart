// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crux_flow/crux_flow.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/models/flow_config.dart';
import 'package:simcrux/services/flow/flow_metric_keys.dart';

/// Why a reader is not verified for a run, as `flow.reader.unsupported`
/// reports it.
enum FlowReaderUnsupported {
  /// The run states no tool version the reader knows.
  versionUnknown('version_unknown'),

  /// The directory is not laid out as a run of the kind it was read as.
  layoutUnknown('layout_unknown'),

  /// A record in the run is not the shape its schema says.
  schemaUnknown('schema_unknown');

  const FlowReaderUnsupported(this.wireName);

  /// The telemetry token and the [FlowMetricKeys.readerUnsupported] value.
  final String wireName;
}

/// One flow run read from its directory or report: the crux_flow [FlowRun]
/// plus what SimCrux shows and records about how it was read.
@immutable
class FlowReading {
  /// Creates a reading.
  const FlowReading({
    required this.run,
    required this.reader,
    this.problem,
    this.stoppedStep,
    this.unsupported,
    this.target = 'other',
    this.nextpnrReport,
    this.wnsNs,
    this.fmaxMhz,
    this.wnsDerivation,
    this.aggregatedKeys = const <String>{},
  });

  /// The keys of [FlowRun.metrics] SimCrux computed by aggregation rather
  /// than read from the run.
  final Set<String> aggregatedKeys;

  /// The run: its reference, verdict, steps, metrics and timing paths.
  final FlowRun run;

  /// The reader id ([FlowReaderIds]).
  final String reader;

  /// What could not be read, when the verdict is not one the run stated.
  final String? problem;

  /// The step a stopped run stopped at.
  final String? stoppedStep;

  /// Why the reader is not verified for this run, when it is not.
  final FlowReaderUnsupported? unsupported;

  /// The closed telemetry target token.
  final String target;

  /// The parsed nextpnr report, for SARIF and the worst-paths view.
  final NextpnrReport? nextpnrReport;

  /// Worst setup slack in nanoseconds, when the run has one.
  final double? wnsNs;

  /// Lowest achieved clock frequency in MHz (nextpnr).
  final double? fmaxMhz;

  /// How [wnsNs] was derived, when SimCrux derived it.
  final String? wnsDerivation;

  /// The verdict.
  FlowVerdict get verdict => run.verdict;

  /// [wnsNs] in integer picoseconds.
  int? get wnsPs => wnsNs == null ? null : (wnsNs! * 1000).round();

  /// The `TestResult.metrics` this reading contributes ([FlowMetricKeys]).
  Map<String, String> toMetrics({int? exitCode}) => <String, String>{
    FlowMetricKeys.kind: run.ref.kind.wireName,
    FlowMetricKeys.verdict: run.verdict.wireName,
    FlowMetricKeys.runDir: run.ref.root,
    FlowMetricKeys.reader: reader,
    FlowMetricKeys.readerVerified: '${run.ref.verified}',
    FlowMetricKeys.tag: run.ref.tag,
    FlowMetricKeys.target: target,
    FlowMetricKeys.steps: '${run.steps.length}',
    if (wnsPs != null) FlowMetricKeys.wnsPs: '$wnsPs',
    if (fmaxMhz != null) FlowMetricKeys.fmaxMhz: fmaxMhz!.toStringAsFixed(2),
    FlowMetricKeys.wnsDerivation: ?wnsDerivation,
    FlowMetricKeys.stoppedStep: ?stoppedStep,
    if (problem != null) FlowMetricKeys.readerProblem: _bounded(problem!),
    if (unsupported != null)
      FlowMetricKeys.readerUnsupported: unsupported!.wireName,
    if (exitCode != null) FlowMetricKeys.processExitCode: '$exitCode',
  };

  static String _bounded(String text) =>
      text.length <= 400 ? text : '${text.substring(0, 400)}...';
}

/// The verdict-driving LibreLane metrics: a value past its limit makes a
/// completed run `violated`.
///
/// A provisional set from the plan's metric list (setup and hold slack and
/// their violation counts, DRC, LVS, antenna, XOR difference). The versioned
/// LibreLane readers confirm it against LibreLane's own checkers; until then
/// a LibreLane verdict is read best-effort and never verified.
const Map<String, double> kLibreLaneVerdictLimits = <String, double>{
  // Slack: a negative worst slack is a violation.
  'timing__setup__ws': 0,
  'timing__hold__ws': 0,
};

/// The LibreLane count metrics where any value above zero is a violation.
const List<String> kLibreLaneViolationCounts = <String>[
  'timing__setup_vio__count',
  'timing__hold_vio__count',
  'route__drc_errors',
  'magic__drc_error__count',
  'design__lvs_error__count',
  'route__antenna_violation__count',
  'antenna__violating__nets',
  'design__xor_difference__count',
];

/// The nextpnr metrics SimCrux derives from the clocks rather than reads.
const Set<String> _derivedNextpnrKeys = <String>{
  'timing__setup__wns',
  'fmax__achieved__mhz',
};

/// The names a LibreLane step directory may have: `NN-<tool>-<step>`.
final RegExp kLibreLaneStepDirectory = RegExp(r'^(\d+)-([A-Za-z0-9_.-]+)$');

/// Reads nextpnr runs: a `--report` JSON, with the log as the fallback when
/// no report was written.
class NextpnrRunReader {
  /// Creates the reader.
  const NextpnrRunReader({this.limits = FlowInputLimits.defaults});

  /// Byte and depth caps for every file read.
  final FlowInputLimits limits;

  /// Reads the run in [runDir]: `report.json`, then (only when
  /// [logFallback]) the nextpnr log when the report is absent.
  ///
  /// [runDir] must already be contained; every file read from it is checked
  /// to resolve inside it.
  Future<FlowReading> readRunDir(
    String runDir, {
    String? tag,
    NextpnrFamily? family,
    bool logFallback = false,
    List<String> logNames = const <String>['pnr.log', 'next.log'],
  }) async {
    final containment = FlowContainment(<String>[runDir]);
    final reportPath = p.join(runDir, 'report.json');
    if (File(reportPath).existsSync() || !logFallback) {
      return await readReport(
        reportPath,
        root: runDir,
        tag: tag,
        family: family,
        containment: containment,
      );
    }
    for (final name in logNames) {
      final logPath = p.join(runDir, name);
      if (!File(logPath).existsSync()) continue;
      return await readLog(
        logPath,
        root: runDir,
        tag: tag,
        family: family,
        containment: containment,
      );
    }
    return _notRun(
      root: runDir,
      tag: tag ?? p.basename(runDir),
      reader: FlowReaderIds.nextpnrLog,
      problem: 'no report.json and no nextpnr log in the run directory',
      target: family?.wireName ?? 'other',
    );
  }

  /// Reads the report at [reportPath]. [root] is the run directory the
  /// result names; it defaults to the report's directory.
  Future<FlowReading> readReport(
    String reportPath, {
    String? root,
    String? tag,
    NextpnrFamily? family,
    FlowContainment? containment,
  }) async {
    final runRoot = root ?? p.dirname(reportPath);
    final runTag = tag ?? p.basename(runRoot);
    final String path;
    try {
      path = (containment ?? FlowContainment(<String>[runRoot])).require(
        reportPath,
      );
    } on FlowContainmentException catch (e) {
      return _notRun(
        root: runRoot,
        tag: runTag,
        reader: FlowReaderIds.nextpnrReport,
        problem: 'report.json: ${e.reason}',
        target: family?.wireName ?? 'other',
      );
    }
    final reading = await NextpnrReportReader(limits: limits).readFile(path);
    final report = reading.result;
    final target = family?.wireName ?? _targetFromReport(report);
    final metrics = <String, Object?>{};
    double? wns;
    double? fmax;
    if (report != null) {
      for (final clock in report.clocks) {
        final slack = 1000 / clock.constraintMhz - 1000 / clock.achievedMhz;
        if (slack.isFinite) wns = wns == null ? slack : math.min(wns, slack);
        fmax = fmax == null
            ? clock.achievedMhz
            : math.min(fmax, clock.achievedMhz);
      }
      if (wns != null) metrics['timing__setup__wns'] = wns;
      if (fmax != null) metrics['fmax__achieved__mhz'] = fmax;
      for (final MapEntry(:key, :value) in report.utilization.entries) {
        final used = MetricKey.tryParse('utilization__used__bel:$key');
        final available = MetricKey.tryParse(
          'utilization__available__bel:$key',
        );
        if (used == null || available == null) continue;
        metrics[used.format()] = value.used;
        metrics[available.format()] = value.available;
      }
    }
    return FlowReading(
      run: FlowRun(
        ref: FlowRunRef(
          kind: FlowKind.nextpnr,
          root: runRoot,
          tag: runTag,
          readerVersion: 'nextpnr-report',
          verified: true,
        ),
        verdict: reading.verdict,
        metrics: metrics,
        timing: report?.criticalPaths ?? const <TimingPath>[],
        artifacts: <String, String>{'report': path},
      ),
      reader: FlowReaderIds.nextpnrReport,
      problem: reading.problem,
      target: target,
      nextpnrReport: report,
      wnsNs: wns,
      fmaxMhz: fmax,
      wnsDerivation: wns == null ? null : kNextpnrWnsDerivation,
      aggregatedKeys: _derivedNextpnrKeys,
    );
  }

  /// Reads the nextpnr log at [logPath] (`Max frequency for clock` lines).
  Future<FlowReading> readLog(
    String logPath, {
    String? root,
    String? tag,
    NextpnrFamily? family,
    FlowContainment? containment,
  }) async {
    final runRoot = root ?? p.dirname(logPath);
    final runTag = tag ?? p.basename(runRoot);
    final String path;
    try {
      path = (containment ?? FlowContainment(<String>[runRoot])).require(
        logPath,
      );
    } on FlowContainmentException catch (e) {
      return _notRun(
        root: runRoot,
        tag: runTag,
        reader: FlowReaderIds.nextpnrLog,
        problem: 'nextpnr log: ${e.reason}',
        target: family?.wireName ?? 'other',
      );
    }
    final reading = await NextpnrLogReader(limits: limits).readFile(path);
    final log = reading.result;
    double? wns;
    double? fmax;
    for (final clock in log?.clocks ?? const <NextpnrClockFrequency>[]) {
      final slack = 1000 / clock.constraintMhz - 1000 / clock.achievedMhz;
      if (slack.isFinite) wns = wns == null ? slack : math.min(wns, slack);
      fmax = fmax == null
          ? clock.achievedMhz
          : math.min(fmax, clock.achievedMhz);
    }
    return FlowReading(
      run: FlowRun(
        ref: FlowRunRef(
          kind: FlowKind.nextpnr,
          root: runRoot,
          tag: runTag,
          readerVersion: 'nextpnr-log',
          verified: true,
        ),
        verdict: reading.verdict,
        metrics: <String, Object?>{
          'timing__setup__wns': ?wns,
          'fmax__achieved__mhz': ?fmax,
        },
        artifacts: <String, String>{'log': path},
      ),
      reader: FlowReaderIds.nextpnrLog,
      problem: reading.problem ?? log?.errorLine,
      target: family?.wireName ?? 'other',
      wnsNs: wns,
      fmaxMhz: fmax,
      wnsDerivation: wns == null ? null : kNextpnrWnsDerivation,
      aggregatedKeys: _derivedNextpnrKeys,
    );
  }

  static String _targetFromReport(NextpnrReport? report) {
    final bels = report?.utilization.keys ?? const <String>[];
    if (bels.any((b) => b.startsWith('ICESTORM'))) return 'ice40';
    if (bels.any((b) => b.startsWith('TRELLIS'))) return 'ecp5';
    return 'other';
  }
}

/// Reads a LibreLane run directory against the contract the plan documents
/// (`runs/<tag>/` with numbered step directories, `resolved.json`, and
/// `final/metrics.json`), best-effort and **never verified**.
///
/// This is the stand-in until the versioned LibreLane readers exist: it
/// detects the version, lists the steps by `state_out.json`, aggregates the
/// final metrics with crux_flow's upstream table, and decides the verdict:
///
/// - no `final/metrics.json`: `stopped`, at the newest step without
///   `state_out.json` (or the newest step);
/// - final metrics with a verdict metric past its limit: `violated`;
/// - final metrics with every verdict metric present inside its limit:
///   `met`;
/// - final metrics carrying none of the verdict metrics: `unrecognised`.
///
/// It reads and never writes, and every path it opens resolves inside the
/// run root.
class LibreLaneContractReader {
  /// Creates the reader.
  const LibreLaneContractReader({this.limits = FlowInputLimits.defaults});

  /// Byte and depth caps for every file read.
  final FlowInputLimits limits;

  /// Whether [dir] looks like a LibreLane run directory.
  static bool looksLikeRun(String dir) {
    if (File(p.join(dir, 'resolved.json')).existsSync()) return true;
    if (Directory(p.join(dir, 'final')).existsSync()) return true;
    try {
      return Directory(dir)
          .listSync(followLinks: false)
          .any(
            (e) =>
                e is Directory &&
                kLibreLaneStepDirectory.hasMatch(p.basename(e.path)),
          );
    } on FileSystemException {
      return false;
    }
  }

  /// Reads the run at [runRoot], which must already be contained.
  Future<FlowReading> read(String runRoot, {String? tag}) async {
    final containment = FlowContainment(<String>[runRoot]);
    final runTag = tag ?? p.basename(runRoot);
    if (!Directory(runRoot).existsSync()) {
      return _notRun(
        root: runRoot,
        tag: runTag,
        reader: FlowReaderIds.librelaneContract,
        problem: 'the run directory does not exist',
        target: 'other',
        kind: FlowKind.librelane,
        unsupported: FlowReaderUnsupported.layoutUnknown,
      );
    }

    String? version;
    var target = 'other';
    FlowReaderUnsupported? unsupported;
    final resolvedPath = p.join(runRoot, 'resolved.json');
    if (File(resolvedPath).existsSync()) {
      try {
        final json = await _readJsonObject(containment.require(resolvedPath));
        final meta = json['meta'];
        if (meta is Map<String, Object?>) {
          final v = meta['librelane_version'] ?? meta['openlane_version'];
          if (v is String && v.isNotEmpty && v.length <= 64) version = v;
        }
        final pdk = json['PDK'];
        if (pdk is String) target = librelaneTargetToken(pdk);
      } on FlowContainmentException {
        unsupported = FlowReaderUnsupported.layoutUnknown;
      } on FormatException {
        unsupported = FlowReaderUnsupported.schemaUnknown;
      } on FileSystemException {
        unsupported = FlowReaderUnsupported.layoutUnknown;
      }
    }
    unsupported ??= version == null
        ? FlowReaderUnsupported.versionUnknown
        : null;

    final steps = _steps(runRoot, containment);
    final metricsPath = p.join(runRoot, 'final', 'metrics.json');
    Map<String, Object?>? aggregated;
    var aggregatedKeys = const <String>{};
    String? problem;
    if (File(metricsPath).existsSync()) {
      try {
        final document = await MetricsDocument.readFile(
          containment.require(metricsPath),
          limits: limits,
        );
        final folded = aggregateMetrics(
          document.values,
          table: librelaneMetricsV1,
        );
        aggregated = folded;
        aggregatedKeys = <String>{
          for (final MapEntry(:key, :value) in folded.entries)
            if (!document.values.containsKey(key) ||
                document.values[key] != value)
              key,
        };
      } on FlowContainmentException catch (e) {
        problem = 'final/metrics.json: ${e.reason}';
      } on FlowReadException catch (e) {
        problem = 'final/metrics.json: ${e.message}';
        unsupported = FlowReaderUnsupported.schemaUnknown;
      } on FileSystemException catch (e) {
        problem = 'final/metrics.json: ${e.message}';
      }
    }

    final FlowVerdict verdict;
    String? stoppedStep;
    var finalSteps = steps;
    if (aggregated == null) {
      verdict = problem == null
          ? FlowVerdict.stopped
          : FlowVerdict.unrecognised;
      // The newest step without `state_out.json` is where it stopped; when
      // every step completed, the run stopped after the last one.
      final incomplete = steps.lastIndexWhere(
        (s) => s.status != FlowStepStatus.completed,
      );
      if (incomplete >= 0) {
        final s = steps[incomplete];
        stoppedStep = s.id;
        finalSteps = List<FlowStep>.of(steps)
          ..[incomplete] = FlowStep(
            ordinal: s.ordinal,
            id: s.id,
            tool: s.tool,
            dir: s.dir,
            status: FlowStepStatus.failed,
          );
      } else if (steps.isNotEmpty) {
        stoppedStep = steps.last.id;
      }
      problem ??= stoppedStep == null
          ? 'the run has no final/metrics.json and no step directories'
          : 'the run has no final/metrics.json';
    } else {
      verdict = librelaneVerdict(aggregated);
    }

    final wns = aggregated?['timing__setup__wns'];
    return FlowReading(
      run: FlowRun(
        ref: FlowRunRef(
          kind: FlowKind.librelane,
          root: runRoot,
          tag: runTag,
          readerVersion: version ?? 'unknown',
          verified: false,
        ),
        verdict: verdict,
        steps: finalSteps,
        metrics: aggregated ?? const <String, Object?>{},
        toolVersions: <String, String>{'librelane': ?version},
      ),
      reader: FlowReaderIds.librelaneContract,
      problem: problem,
      stoppedStep: stoppedStep,
      unsupported: unsupported,
      target: target,
      wnsNs: wns is num && wns.isFinite ? wns.toDouble() : null,
      aggregatedKeys: aggregatedKeys,
    );
  }

  /// The verdict of a completed run's aggregated [metrics].
  @visibleForTesting
  static FlowVerdict librelaneVerdict(Map<String, Object?> metrics) {
    var seen = false;
    for (final MapEntry(:key, :value) in kLibreLaneVerdictLimits.entries) {
      final v = metrics[key];
      if (v is! num) continue;
      seen = true;
      if (v < value) return FlowVerdict.violated;
    }
    for (final key in kLibreLaneViolationCounts) {
      final v = metrics[key];
      if (v is! num) continue;
      seen = true;
      if (v > 0) return FlowVerdict.violated;
    }
    return seen ? FlowVerdict.met : FlowVerdict.unrecognised;
  }

  List<FlowStep> _steps(String runRoot, FlowContainment containment) {
    final steps = <FlowStep>[];
    final List<FileSystemEntity> entries;
    try {
      entries = Directory(runRoot).listSync(followLinks: false);
    } on FileSystemException {
      return steps;
    }
    for (final entity in entries) {
      if (entity is! Directory) continue;
      final name = p.basename(entity.path);
      final match = kLibreLaneStepDirectory.firstMatch(name);
      if (match == null) continue;
      if (!containment.allows(entity.path)) continue;
      final slug = match.group(2)!;
      final dash = slug.indexOf('-');
      steps.add(
        FlowStep(
          ordinal: int.tryParse(match.group(1)!) ?? 0,
          id: slug,
          tool: dash < 0 ? slug : slug.substring(0, dash),
          dir: entity.path,
          status: File(p.join(entity.path, 'state_out.json')).existsSync()
              ? FlowStepStatus.completed
              : FlowStepStatus.notStarted,
        ),
      );
    }
    steps.sort((a, b) => a.ordinal.compareTo(b.ordinal));
    return steps;
  }

  Future<Map<String, Object?>> _readJsonObject(String path) async {
    final file = File(path);
    final length = await file.length();
    if (length > limits.maxBytes) {
      throw FormatException('${p.basename(path)} is over the size cap');
    }
    final text = utf8.decode(await file.readAsBytes());
    _checkDepth(text, limits.maxJsonDepth);
    final json = jsonDecode(text);
    if (json is! Map<String, Object?>) {
      throw FormatException('${p.basename(path)} is not a JSON object');
    }
    return json;
  }
}

/// The telemetry target token for a LibreLane PDK name.
String librelaneTargetToken(String pdk) {
  final lower = pdk.toLowerCase();
  if (lower.startsWith('sky130')) return 'sky130';
  if (lower.startsWith('gf180mcu')) return 'gf180mcu';
  if (lower.startsWith('ihp-sg13g2') || lower.startsWith('ihp_sg13g2')) {
    return 'ihp_sg13g2';
  }
  return 'other';
}

void _checkDepth(String text, int maxDepth) {
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (var i = 0; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (c == 0x5C) {
        escaped = true;
      } else if (c == 0x22) {
        inString = false;
      }
      continue;
    }
    if (c == 0x22) {
      inString = true;
    } else if (c == 0x5B || c == 0x7B) {
      if (++depth > maxDepth) {
        throw const FormatException('JSON nests too deep');
      }
    } else if (c == 0x5D || c == 0x7D) {
      depth--;
    }
  }
}

FlowReading _notRun({
  required String root,
  required String tag,
  required String reader,
  required String problem,
  required String target,
  FlowKind kind = FlowKind.nextpnr,
  FlowReaderUnsupported? unsupported,
}) => FlowReading(
  run: FlowRun(
    ref: FlowRunRef(
      kind: kind,
      root: root,
      tag: tag,
      readerVersion: 'none',
      verified: false,
    ),
    verdict: FlowVerdict.notRun,
  ),
  reader: reader,
  problem: problem,
  target: target,
  unsupported: unsupported,
);
