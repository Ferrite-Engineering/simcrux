// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/formal_bucket.dart';
import 'package:simcrux/domain/enums/formal_property_status.dart';
import 'package:simcrux/domain/enums/formal_verdict.dart';
import 'package:simcrux/domain/models/eqy_outcome.dart';
import 'package:simcrux/domain/models/sby_outcome.dart';
import 'package:simcrux/services/formal/formal_containment.dart';

/// One partition of an EQY run, as its work directory and log left it.
@immutable
class EqyPartitionResult {
  /// Creates a result.
  const EqyPartitionResult({
    required this.name,
    required this.status,
    required this.token,
    this.module,
    this.outputs,
    this.strategy,
    this.trace,
    this.step,
    this.disagreement = false,
    this.note,
  });

  /// The partition's name (`alu.z`), as EQY wrote it in `partition.list`.
  final String name;

  /// The module the partition belongs to (`alu`).
  final String? module;

  /// The outputs after the `:` in `partition.list` (`z[0]`), verbatim.
  final String? outputs;

  /// The strategy whose status file EQY's summary read, when it named one.
  final String? strategy;

  /// What the partition ended as, the more conservative of the status file
  /// and the log.
  final FormalPropertyStatus status;

  /// The verdict token for [status]: `PASS`, `FAIL`, `UNKNOWN`, `TIMEOUT`,
  /// `ERROR` or `NO_OUTCOME`.
  final FormalVerdict token;

  /// The counterexample trace, absolute and inside the work directory, for
  /// a partition that ended [FormalPropertyStatus.counterexample].
  final String? trace;

  /// The solver step at which [trace]'s assertion failed, as the
  /// partition's SymbiYosys summary stated it (`failed assertion … step 1`).
  /// Null when the summary states none (a `sat` strategy, or a summary line
  /// without a step): never inferred from the trace.
  final int? step;

  /// Whether the status file and the log disagreed about this partition.
  final bool disagreement;

  /// Why the partition could not be read, when it could not.
  final String? note;
}

/// Everything [EqyWorkdirReader.read] found in one EQY work directory.
@immutable
class EqyWorkdirSnapshot {
  /// Creates a snapshot.
  const EqyWorkdirSnapshot({
    required this.partitionListRead,
    this.partitions = const <EqyPartitionResult>[],
    this.truncated = false,
    this.notes = const <String>[],
  });

  /// Whether `partition.list` existed and was read. EQY writes it before it
  /// runs any strategy, so a run without one never reached a partition.
  final bool partitionListRead;

  /// Every partition, in `partition.list` order.
  final List<EqyPartitionResult> partitions;

  /// Whether `partition.list` held more than SimCrux reads.
  final bool truncated;

  /// What could not be read, for the run log.
  final List<String> notes;
}

/// Reads an EQY work directory after `eqy` exits.
///
/// The layout is the one measured identical on OSS CAD Suite builds
/// 20261021, 20260921 and 20260821 (simcrux guide §26.4):
///
/// - `partition.list`: one line per partition,
///   `<module> <partition> [attributes] : <outputs>`;
/// - `summary_targets.list`: one `strategies/<partition>/<strategy>/status`
///   per partition, the file EQY's own summary reads;
/// - per strategy, `strategies/<partition>/<strategy>/status` holding
///   `PASS`, `FAIL`, `UNKNOWN`, `TIMEOUT` or `ERROR` (and `PASS (cached)` or
///   `FAIL (cached)` when an earlier strategy decided);
/// - for an `sby` (or `imctk`) strategy, a whole SymbiYosys job under
///   `strategies/<partition>/<strategy>/<partition>/`, whose `logfile.txt`
///   names the counterexample; for `sat`, `trace.vcd` beside `status`.
///
/// **Contained and bounded.** Partition and strategy names come from the
/// user's design and file: each must be one safe path segment before it is
/// joined, and every file is opened only when it resolves inside the work
/// directory with symlinks resolved. Every read is capped. Pure `dart:io`,
/// so the driver runs it off the UI isolate.
class EqyWorkdirReader {
  /// Creates a reader.
  const EqyWorkdirReader();

  /// The most partitions read from `partition.list`.
  static const int kMaxPartitions = 4096;

  /// The most bytes read from `partition.list` or `summary_targets.list`.
  static const int kMaxListBytes = 4 * 1024 * 1024;

  /// The most bytes read from one strategy `status` file.
  static const int kMaxStatusBytes = 4096;

  /// The most bytes read from one partition's SymbiYosys log.
  static const int kMaxLogBytes = 2 * 1024 * 1024;

  /// Reads [workDir]. [log] is what the run's own log said per partition;
  /// [strategyOrder] is the `.eqy` file's strategy names in order, used to
  /// find the strategy that decided a partition whose final status was
  /// carried over (`FAIL (cached)`).
  EqyWorkdirSnapshot read(
    String workDir, {
    Map<String, EqyLogPartitionStatus> log =
        const <String, EqyLogPartitionStatus>{},
    List<String> strategyOrder = const <String>[],
  }) {
    final notes = <String>[];
    final listPath = FormalContainment.containedPath(workDir, 'partition.list');
    final list = listPath == null
        ? null
        : _readBounded(listPath, kMaxListBytes);
    if (list == null) {
      return const EqyWorkdirSnapshot(partitionListRead: false);
    }
    final targets = _summaryTargets(workDir, notes);
    final partitions = <EqyPartitionResult>[];
    var truncated = list.truncated;
    for (final raw in const LineSplitter().convert(list.text)) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (partitions.length >= kMaxPartitions) {
        truncated = true;
        break;
      }
      final colon = line.indexOf(' : ');
      final head = (colon < 0 ? line : line.substring(0, colon)).split(
        RegExp(r'\s+'),
      );
      if (head.length < 2) continue;
      final module = head[0];
      final name = head[1];
      final outputs = colon < 0 ? null : line.substring(colon + 3).trim();
      partitions.add(
        _partition(
          workDir: workDir,
          module: module,
          name: name,
          outputs: outputs,
          strategy: targets[name],
          logStatus: log[name],
          strategyOrder: strategyOrder,
        ),
      );
    }
    if (truncated) {
      notes.add(
        'partition.list holds more than $kMaxPartitions partitions or '
        '${kMaxListBytes ~/ (1024 * 1024)} MiB; the rest were not read.',
      );
    }
    for (final partition in partitions) {
      if (partition.note case final String note) notes.add(note);
    }
    return EqyWorkdirSnapshot(
      partitionListRead: true,
      partitions: List<EqyPartitionResult>.unmodifiable(partitions),
      truncated: truncated,
      notes: List<String>.unmodifiable(notes),
    );
  }

  /// `summary_targets.list`: partition name to the strategy whose status
  /// EQY's summary reads. A line that is not exactly
  /// `strategies/<safe>/<safe>/status` is skipped.
  Map<String, String> _summaryTargets(String workDir, List<String> notes) {
    final path = FormalContainment.containedPath(
      workDir,
      'summary_targets.list',
    );
    final text = path == null ? null : _readBounded(path, kMaxListBytes);
    if (text == null) return const <String, String>{};
    final out = <String, String>{};
    for (final raw in const LineSplitter().convert(text.text)) {
      final parts = raw.trim().split('/');
      if (parts.length != 4 ||
          parts[0] != 'strategies' ||
          parts[3] != 'status' ||
          FormalContainment.segmentProblem(parts[1]) != null ||
          FormalContainment.segmentProblem(parts[2]) != null) {
        if (raw.trim().isNotEmpty) {
          notes.add('summary_targets.list line "$raw" was not read.');
        }
        continue;
      }
      out[parts[1]] = parts[2];
    }
    return out;
  }

  EqyPartitionResult _partition({
    required String workDir,
    required String module,
    required String name,
    required String? outputs,
    required String? strategy,
    required EqyLogPartitionStatus? logStatus,
    required List<String> strategyOrder,
  }) {
    final problem = FormalContainment.segmentProblem(name);
    if (problem != null) {
      return EqyPartitionResult(
        name: name,
        module: module,
        outputs: outputs,
        status: FormalPropertyStatus.didNotRun,
        token: FormalVerdict.noOutcome,
        note:
            'partition "$name" cannot name a directory ($problem); its '
            'results were not read.',
      );
    }
    final fileToken = strategy == null
        ? null
        : _statusToken(workDir, name, strategy);
    final fromFile = switch (fileToken) {
      'PASS' => FormalPropertyStatus.proved,
      'FAIL' => FormalPropertyStatus.counterexample,
      'UNKNOWN' || 'TIMEOUT' => FormalPropertyStatus.inconclusive,
      'ERROR' => FormalPropertyStatus.didNotRun,
      null => null,
      _ => FormalPropertyStatus.didNotRun,
    };
    final fromLog = switch (logStatus) {
      EqyLogPartitionStatus.proved => FormalPropertyStatus.proved,
      EqyLogPartitionStatus.notEquivalent =>
        FormalPropertyStatus.counterexample,
      EqyLogPartitionStatus.unknown ||
      EqyLogPartitionStatus.timeout => FormalPropertyStatus.inconclusive,
      EqyLogPartitionStatus.error => FormalPropertyStatus.didNotRun,
      // "Failed to prove" says only "not proved"; the status file says how.
      EqyLogPartitionStatus.failed => null,
      null => null,
    };

    FormalPropertyStatus status;
    var disagreement = false;
    if (fromFile == null) {
      // No status file: a proof the log alone claims is not taken.
      status = switch (fromLog) {
        null || FormalPropertyStatus.proved => FormalPropertyStatus.didNotRun,
        _ => fromLog,
      };
      if (logStatus == EqyLogPartitionStatus.failed) {
        status = FormalPropertyStatus.inconclusive;
      }
      disagreement = fromLog == FormalPropertyStatus.proved;
    } else if (logStatus == EqyLogPartitionStatus.failed) {
      status = fromFile == FormalPropertyStatus.proved
          ? FormalPropertyStatus.inconclusive
          : fromFile;
      disagreement = fromFile == FormalPropertyStatus.proved;
    } else if (fromLog == null) {
      status = fromFile;
    } else {
      status = fromFile.conservativeRank >= fromLog.conservativeRank
          ? fromFile
          : fromLog;
      disagreement = fromFile.bucket != fromLog.bucket;
    }

    final token = switch (status) {
      FormalPropertyStatus.proved ||
      FormalPropertyStatus.reached => FormalVerdict.pass,
      FormalPropertyStatus.counterexample ||
      FormalPropertyStatus.notReached => FormalVerdict.fail,
      FormalPropertyStatus.inconclusive =>
        fileToken == 'TIMEOUT' || logStatus == EqyLogPartitionStatus.timeout
            ? FormalVerdict.timeout
            : FormalVerdict.unknown,
      FormalPropertyStatus.didNotRun =>
        fileToken == 'ERROR' || logStatus == EqyLogPartitionStatus.error
            ? FormalVerdict.error
            : FormalVerdict.noOutcome,
    };

    ({String path, int? step})? trace;
    if (status == FormalPropertyStatus.counterexample) {
      trace = _trace(workDir, name, <String>[
        ?strategy,
        for (final s in strategyOrder)
          if (s != strategy) s,
      ]);
    }
    return EqyPartitionResult(
      name: name,
      module: module,
      outputs: outputs,
      strategy: strategy,
      status: status,
      token: token,
      trace: trace?.path,
      step: trace?.step,
      disagreement: disagreement,
    );
  }

  static final RegExp _summaryTrace = RegExp(
    r'summary:\s+counterexample trace \[[^\]]*\]:\s+(\S+)\s*$',
  );

  static final RegExp _summaryFailedStep = RegExp(
    r'summary:\s+failed assertion\s.*\sstep\s+(\d+)\s*$',
  );

  /// The step each counterexample trace of a SymbiYosys log failed at, from
  /// its summary: a `counterexample trace [...]: <trace>` line followed by
  /// `failed assertion … step <n>`. A trace whose summary names no step is
  /// absent.
  static Map<String, int> summarySteps(String log) {
    final steps = <String, int>{};
    String? current;
    for (final line in const LineSplitter().convert(log)) {
      final trace = _summaryTrace.firstMatch(line);
      if (trace != null) {
        current = trace.group(1);
        continue;
      }
      final failed = _summaryFailedStep.firstMatch(line);
      if (failed != null && current != null) {
        final step = int.tryParse(failed.group(1)!);
        if (step != null) steps.putIfAbsent(current, () => step);
        current = null;
      }
    }
    return steps;
  }

  /// The first word of `strategies/<partition>/<strategy>/status`, or null.
  String? _statusToken(String workDir, String partition, String strategy) {
    final path = FormalContainment.containedPath(
      workDir,
      p.join('strategies', partition, strategy, 'status'),
    );
    if (path == null) return null;
    final text = _readBounded(path, kMaxStatusBytes)?.text.trim();
    if (text == null || text.isEmpty) return null;
    return text.split(RegExp(r'\s+')).first;
  }

  /// Whether `strategies/<partition>/<strategy>/status` records a decision
  /// that strategy made itself (not one carried over with `(cached)`).
  bool _decidedHere(String workDir, String partition, String strategy) {
    final path = FormalContainment.containedPath(
      workDir,
      p.join('strategies', partition, strategy, 'status'),
    );
    final text = path == null ? null : _readBounded(path, kMaxStatusBytes);
    if (text == null) return false;
    final status = text.text.trim();
    return status.startsWith('FAIL') && !status.contains('(cached)');
  }

  /// The counterexample of a failing [partition]: the first of [strategies]
  /// that decided it and left a trace inside [workDir], with the step its
  /// SymbiYosys summary says it failed at, when it says one.
  ({String path, int? step})? _trace(
    String workDir,
    String partition,
    List<String> strategies,
  ) {
    for (final strategy in strategies) {
      if (FormalContainment.segmentProblem(strategy) != null) continue;
      if (!_decidedHere(workDir, partition, strategy)) continue;
      final dir = p.join('strategies', partition, strategy);
      // An `sby` or `imctk` strategy: SymbiYosys names its own
      // counterexample, relative to the strategy directory, and never the
      // induction trace (SbyLogReader drops it).
      final logPath = FormalContainment.containedPath(
        workDir,
        p.join(dir, partition, 'logfile.txt'),
      );
      final log = logPath == null ? null : _readBounded(logPath, kMaxLogBytes);
      if (log != null) {
        final steps = summarySteps(log.text);
        for (final announced in SbyLogReader.parse(log.text).traces) {
          final vcd = announced.toLowerCase().endsWith('.yw')
              ? '${announced.substring(0, announced.length - 3)}.vcd'
              : announced;
          for (final base in <String>[dir, p.join(dir, partition)]) {
            final resolved = _existing(workDir, p.join(base, vcd));
            if (resolved != null) {
              return (path: resolved, step: steps[announced] ?? steps[vcd]);
            }
          }
        }
      }
      // A `sat` strategy dumps its base-case model beside its status, and
      // states no step.
      for (final candidate in <String>[
        p.join(dir, 'trace.vcd'),
        p.join(dir, partition, 'engine_0', 'trace.vcd'),
      ]) {
        final resolved = _existing(workDir, candidate);
        if (resolved != null) return (path: resolved, step: null);
      }
    }
    return null;
  }

  static String? _existing(String workDir, String relative) {
    final path = FormalContainment.containedPath(workDir, relative);
    if (path == null) return null;
    return File(path).existsSync() ? path : null;
  }

  /// At most [cap] bytes of [path] as text, or null when it is not a
  /// readable file.
  static ({String text, bool truncated})? _readBounded(String path, int cap) {
    final file = File(path);
    if (!file.existsSync()) return null;
    RandomAccessFile? raf;
    try {
      raf = file.openSync();
      final length = raf.lengthSync();
      final bytes = raf.readSync(math.min(length, cap));
      return (
        text: utf8.decode(bytes, allowMalformed: true),
        truncated: length > cap,
      );
    } on FileSystemException {
      return null;
    } finally {
      raf?.closeSync();
    }
  }
}

/// The verdict of one EQY run: the log's `DONE (…)` token reconciled with
/// the per-partition statuses by the agreement rule (verification guide
/// §26.11).
@immutable
class EqyReconciliation {
  /// Creates a reconciliation.
  const EqyReconciliation({
    required this.verdict,
    required this.taskVerdict,
    this.disagreement,
  });

  /// Reconciles [taskVerdict] with [snapshot].
  ///
  /// The more conservative fact wins and nothing is ever resolved toward
  /// Proved: a `PASS` stands only when every partition was proved, and a
  /// `PASS` with no `partition.list` at all is `NO_OUTCOME`. A run that
  /// reached no partition keeps its own token.
  factory EqyReconciliation.reconcile({
    required FormalVerdict taskVerdict,
    required EqyWorkdirSnapshot snapshot,
  }) {
    if (!snapshot.partitionListRead) {
      return EqyReconciliation(
        verdict: taskVerdict == FormalVerdict.pass
            ? FormalVerdict.noOutcome
            : taskVerdict,
        taskVerdict: taskVerdict,
        disagreement: taskVerdict == FormalVerdict.pass ? true : null,
      );
    }
    if (snapshot.partitions.isEmpty) {
      return EqyReconciliation(
        verdict: taskVerdict,
        taskVerdict: taskVerdict,
        disagreement: false,
      );
    }
    var worst = snapshot.partitions.first;
    for (final partition in snapshot.partitions.skip(1)) {
      if (_rank(partition.token) > _rank(worst.token)) worst = partition;
    }
    final verdict = _rank(worst.token) > _rank(taskVerdict)
        ? worst.token
        : taskVerdict;
    final disagreement =
        FormalBucket.of(worst.token) != FormalBucket.of(taskVerdict) ||
        snapshot.partitions.any((p) => p.disagreement);
    return EqyReconciliation(
      verdict: verdict,
      taskVerdict: taskVerdict,
      disagreement: disagreement,
    );
  }

  /// How far [v] is from a proof, the ordering
  /// [FormalPropertyStatus.conservativeRank] uses.
  static int _rank(FormalVerdict v) => switch (v) {
    FormalVerdict.pass => 0,
    FormalVerdict.unknown || FormalVerdict.timeout => 1,
    FormalVerdict.error || FormalVerdict.noOutcome => 2,
    FormalVerdict.fail => 3,
  };

  /// The row's verdict.
  final FormalVerdict verdict;

  /// What the log's `DONE (…)` line said.
  final FormalVerdict taskVerdict;

  /// Whether the log and the partitions disagreed; null when there were no
  /// partitions to compare.
  final bool? disagreement;
}
