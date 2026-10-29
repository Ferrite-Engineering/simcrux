// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';
import 'dart:math' as math;

import 'package:crux_flow/crux_flow.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/models/flow_config.dart';
import 'package:simcrux/services/flow/flow_metric_keys.dart';

// Why a reader is not verified for a run (`FlowReaderUnsupported`), the
// LibreLane step-directory pattern and the LibreLane check set come from
// crux_flow; re-exported so importers of this file keep their names.
export 'package:crux_flow/crux_flow.dart'
    show FlowReaderUnsupported, kLibreLane30Checks, kLibreLaneStepDirectory;

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
    this.librelane,
  });

  /// The keys of [FlowRun.metrics] SimCrux computed by aggregation rather
  /// than read from the run.
  final Set<String> aggregatedKeys;

  /// What crux_flow's LibreLane reader read, for a LibreLane run: the
  /// release, the checks the run fails, the steps turned off, the error
  /// records and the timing corner. Null for a nextpnr run.
  final LibreLaneReading? librelane;

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

/// The nextpnr metrics SimCrux derives from the clocks rather than reads.
const Set<String> _derivedNextpnrKeys = <String>{
  'timing__setup__wns',
  'fmax__achieved__mhz',
};

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

/// Reads a LibreLane run directory with crux_flow's versioned readers
/// ([LibreLaneReaders]) and turns the reading into a [FlowReading].
///
/// The release comes from `resolved.json`; the reader of its minor line
/// reads the run and is verified only for the releases its range names
/// (3.0.15 to 3.0.17 for the 3.0 line). Any other release is read by the
/// nearest older line's reader, best-effort, with
/// [FlowReading.unsupported] saying why: what the run shows has not been
/// checked against the release that wrote it.
///
/// The verdict comes from the run's records and LibreLane's own checks
/// ([kLibreLane30Checks]), never from the exit status; the worst setup paths
/// come from the post-PnR STA listing of the corner the setup checker
/// checks. It reads and never writes, and every path it opens resolves
/// inside the run root.
class LibreLaneVersionedReader {
  /// Creates the reader.
  const LibreLaneVersionedReader({
    this.limits = FlowInputLimits.defaults,
    this.timingPaths = 100,
  });

  /// Byte and depth caps for every file read.
  final FlowInputLimits limits;

  /// The most setup paths read into [FlowRun.timing].
  final int timingPaths;

  /// Whether [dir] looks like a LibreLane run directory.
  static bool looksLikeRun(String dir) => LibreLaneReaders.looksLikeRun(dir);

  /// Reads the run at [runRoot], which must already be contained. [live]
  /// says the LibreLane process is still running.
  Future<FlowReading> read(
    String runRoot, {
    String? tag,
    bool live = false,
  }) async {
    final reading = await LibreLaneReaders.standard(
      limits: limits,
    ).read(runRoot, tag: tag, live: live, timingPaths: timingPaths);
    return fromReading(reading);
  }

  /// [reading] as SimCrux records and shows it.
  static FlowReading fromReading(LibreLaneReading reading) {
    final run = reading.run;
    final wns = run.metrics['timing__setup__wns'];
    return FlowReading(
      run: run,
      reader: FlowReaderIds.librelane,
      problem: reading.problem,
      stoppedStep: reading.stoppedStep,
      unsupported: reading.unsupported,
      target: reading.pdk == null
          ? 'other'
          : librelaneTargetToken(reading.pdk!),
      wnsNs: wns is num && wns.isFinite ? wns.toDouble() : null,
      aggregatedKeys: reading.metrics?.aggregatedKeys ?? const <String>{},
      librelane: reading,
    );
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
