// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:simcrux/domain/enums/formal_verdict.dart';

/// What EQY's log said about one partition.
enum EqyLogPartitionStatus {
  /// `Proved equivalence of partition …` or, in the summary,
  /// `Successfully proved equivalence of partition …`.
  proved,

  /// `Could not prove equivalence of partition … : partitions not
  /// equivalent`: the strategy found a difference.
  notEquivalent,

  /// `… : equivalence unknown`.
  unknown,

  /// `… : timeout`.
  timeout,

  /// `Execution of strategy … on partition … encountered an error`.
  error,

  /// The summary's `Failed to prove equivalence of partition …`, with no
  /// strategy line saying why.
  failed,
}

/// What one EQY run reported, distilled from its log.
///
/// Pure and I/O-free (`domain/`) for the reason [SbyOutcome] is: the `eqy`
/// driver classifies from this, and the `string_match` detector the EQY
/// importer emits keys off [EqyLogReader.kPassMarker], the literal this
/// parser recognises.
@immutable
class EqyOutcome {
  /// Creates an [EqyOutcome].
  const EqyOutcome({
    required this.verdict,
    this.returnCode,
    this.elapsedSeconds,
    this.errorLine,
    this.partitions = const <String, EqyLogPartitionStatus>{},
    this.designsEquivalent = false,
  });

  /// What `eqy` concluded on its `DONE (…)` line;
  /// [FormalVerdict.noOutcome] when there was none.
  final FormalVerdict verdict;

  /// The `rc=` on the `DONE (…)` line. Recorded, never the verdict.
  final int? returnCode;

  /// EQY's own "Elapsed clock time", in seconds.
  final int? elapsedSeconds;

  /// The first `ERROR:` line.
  final String? errorLine;

  /// The log's word on each partition, by partition name: the last
  /// strategy's result, confirmed or made more conservative by the summary.
  final Map<String, EqyLogPartitionStatus> partitions;

  /// Whether the log said `Successfully proved designs equivalent`.
  final bool designsEquivalent;
}

/// Incremental, pure reader that turns EQY log lines into an [EqyOutcome].
///
/// Fed from the driver's `onLine` hook, so the live stream and a replayed
/// log go through the same parser. Every line EQY prints is prefixed
/// `EQY <time> [<work dir>] `; the reader strips the prefix when present.
/// The partition lines are a second source beside the work directory's
/// status files, never the only one.
class EqyLogReader {
  /// Creates a reader with no lines seen yet.
  EqyLogReader();

  /// The literal that means "every partition was proved equivalent", and
  /// the single point of agreement between this parser and the
  /// `string_match` detector the EQY importer emits as `pass_string`.
  static const String kPassMarker = 'DONE (PASS';

  /// The most partitions the reader keeps a status for. A design with more
  /// is still classified from its work directory.
  static const int kMaxPartitions = 4096;

  static final RegExp _prefix = RegExp(r'^EQY\s+(?:\S+\s+)?\[.*?\]\s');
  static final RegExp _done = RegExp(
    r'DONE\s*\(\s*([A-Za-z_]+)\s*(?:,\s*rc\s*=\s*(-?\d+)\s*)?\)',
  );
  static final RegExp _proved = RegExp(
    r"(?:^|\s)Proved equivalence of partition '([^']+)' using strategy '[^']*'",
  );
  static final RegExp _couldNot = RegExp(
    "Could not prove equivalence of partition '([^']+)' using strategy "
    r"'[^']*':\s*(.*)$",
  );
  static final RegExp _execError = RegExp(
    "Execution of strategy '[^']*' on partition '([^']+)' encountered an error",
  );
  static final RegExp _summaryProved = RegExp(
    r'Successfully proved equivalence of partition (\S+)\s*$',
  );
  static final RegExp _summaryFailed = RegExp(
    r'Failed to prove equivalence of partition (\S+)\s*$',
  );
  static final RegExp _elapsed = RegExp(
    r'Elapsed clock time.*?\(\s*(\d+)\s*\)\s*$',
  );

  FormalVerdict? _verdict;
  int? _returnCode;
  int? _elapsedSeconds;
  String? _errorLine;
  bool _equivalent = false;
  final Map<String, EqyLogPartitionStatus> _partitions =
      <String, EqyLogPartitionStatus>{};

  /// Feeds one log line, stdout or stderr.
  void addLine(String raw) {
    final line = raw.replaceFirst(_prefix, '').trimRight();
    if (line.isEmpty) return;

    final done = _done.firstMatch(line);
    if (done != null) {
      final parsed = FormalVerdict.fromWireName(done.group(1));
      final rc = int.tryParse(done.group(2) ?? '');
      if (_worse(parsed)) {
        _verdict = parsed ?? FormalVerdict.error;
        _returnCode = rc;
        if (parsed == null) {
          _errorLine ??= 'eqy reported an unrecognized outcome: $line';
        }
      }
      return;
    }

    if (_execError.firstMatch(line) case final m?) {
      _set(m.group(1)!, EqyLogPartitionStatus.error);
    } else if (_couldNot.firstMatch(line) case final m?) {
      final reason = m.group(2)!.trim();
      _set(m.group(1)!, switch (reason) {
        'partitions not equivalent' => EqyLogPartitionStatus.notEquivalent,
        'timeout' => EqyLogPartitionStatus.timeout,
        _ => EqyLogPartitionStatus.unknown,
      });
    } else if (_summaryProved.firstMatch(line) case final m?) {
      _set(m.group(1)!, EqyLogPartitionStatus.proved, summary: true);
    } else if (_summaryFailed.firstMatch(line) case final m?) {
      _set(m.group(1)!, EqyLogPartitionStatus.failed, summary: true);
    } else if (_proved.firstMatch(line) case final m?) {
      _set(m.group(1)!, EqyLogPartitionStatus.proved);
    } else if (line.contains('Successfully proved designs equivalent')) {
      _equivalent = true;
    }

    final elapsed = _elapsed.firstMatch(line);
    if (elapsed != null) _elapsedSeconds ??= int.tryParse(elapsed.group(1)!);

    if (_errorLine == null && line.startsWith('ERROR')) _errorLine = line;
  }

  /// Records [status] for [partition].
  ///
  /// EQY tries a partition's strategies in order and stops at the first
  /// that decides it, so a later strategy line replaces an earlier one. The
  /// closing summary only confirms: it never replaces a strategy's reason
  /// with the coarser `failed`, and never turns a partition a strategy left
  /// unproved into a proved one.
  void _set(
    String partition,
    EqyLogPartitionStatus status, {
    bool summary = false,
  }) {
    final current = _partitions[partition];
    if (current == null) {
      if (_partitions.length >= kMaxPartitions) return;
      _partitions[partition] = status;
      return;
    }
    if (summary && current != EqyLogPartitionStatus.proved) return;
    _partitions[partition] = status;
  }

  /// `pass` never replaces anything; anything else replaces a `pass`.
  bool _worse(FormalVerdict? candidate) {
    final current = _verdict;
    if (current == null) return true;
    if (candidate == FormalVerdict.pass) return false;
    return current == FormalVerdict.pass;
  }

  /// The outcome distilled from everything fed so far.
  EqyOutcome get outcome => EqyOutcome(
    verdict: _verdict ?? FormalVerdict.noOutcome,
    returnCode: _returnCode,
    elapsedSeconds: _elapsedSeconds,
    errorLine: _errorLine,
    partitions: Map<String, EqyLogPartitionStatus>.unmodifiable(_partitions),
    designsEquivalent: _equivalent,
  );

  /// Parses a whole captured log, for tests and tools.
  static EqyOutcome parse(String log) {
    final reader = EqyLogReader();
    const LineSplitter().convert(log).forEach(reader.addLine);
    return reader.outcome;
  }
}
