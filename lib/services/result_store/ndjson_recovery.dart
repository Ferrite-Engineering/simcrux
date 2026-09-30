// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

/// Outcome of an [NdjsonRecovery.recover] pass over a `results.ndjson`.
class NdjsonRecoveryResult {
  /// Creates an [NdjsonRecoveryResult].
  const NdjsonRecoveryResult({
    required this.recoveredRecords,
    required this.trimmedPartialTail,
    required this.repaired,
  });

  /// Number of complete, parseable records retained after recovery.
  final int recoveredRecords;

  /// True when a truncated or garbled trailing record was dropped.
  final bool trimmedPartialTail;

  /// True when the on-disk file was rewritten to its repaired state.
  final bool repaired;

  /// A clean no-op recovery (nothing to recover).
  static const NdjsonRecoveryResult clean = NdjsonRecoveryResult(
    recoveredRecords: 0,
    trimmedPartialTail: false,
    repaired: false,
  );
}

/// Recovers a `results.ndjson` that a crash left in an inconsistent state.
///
/// The streaming writer is one-shot, append-only, and **not** designed for
/// append-resume: a crash mid-run can leave a truncated last record (the
/// process died mid-`writeln`, so the file ends without a trailing newline)
/// or a garbled last record (an interleaved/partial flush). Recovery trims
/// the file to the last complete record and reports how many survived, so
/// the dashboard/export pipeline reads a consistent prefix instead of
/// choking on (or silently misreading) the tail.
///
/// Open-Core Extension Point: the interface + both implementations live
/// in open-core. The export pipeline ([DashboardBundleWriter]) uses
/// [FileNdjsonRecovery] to repair a crash-truncated `results.ndjson`
/// before decoding it. The seam is available to the Pro overlay's
/// per-project stores; no Pro call site consumes it today.
// Single-method by design — this is a swappable seam, not a candidate
// for a top-level function.
// ignore: one_member_abstracts
abstract class NdjsonRecovery {
  /// Scans [path], trims any truncated/garbled trailing record, and (when
  /// it trimmed) rewrites the file to its repaired state. Idempotent: a
  /// second pass over an already-clean file is a no-op.
  Future<NdjsonRecoveryResult> recover(String path);
}

/// The no-op default: never inspects or rewrites the file. Used when
/// recovery is disabled — e.g. tests that want to stay off the disk, and
/// the [StreamingResultsReader.readFile] default that preserves the
/// historical no-repair behaviour for callers that pass nothing.
class NoopNdjsonRecovery implements NdjsonRecovery {
  /// Const constructor.
  const NoopNdjsonRecovery();

  @override
  Future<NdjsonRecoveryResult> recover(String path) async =>
      NdjsonRecoveryResult.clean;
}

/// The production recovery: trims a truncated/garbled trailing record and
/// repairs the file in place.
class FileNdjsonRecovery implements NdjsonRecovery {
  /// Const constructor.
  const FileNdjsonRecovery();

  @override
  Future<NdjsonRecoveryResult> recover(String path) async {
    final file = File(path);
    if (!file.existsSync()) return NdjsonRecoveryResult.clean;
    final content = await file.readAsString();
    if (content.isEmpty) return NdjsonRecoveryResult.clean;

    final endsWithNewline = content.endsWith('\n');
    final parts = content.split('\n');
    // A trailing newline yields a final empty element — drop it; it is not
    // a record. Records never contain a literal newline (the encoder
    // escapes `\n` inside string values), so splitting on `\n` is a safe
    // record boundary.
    if (parts.isNotEmpty && parts.last.isEmpty) parts.removeLast();
    if (parts.isEmpty) return NdjsonRecoveryResult.clean;

    final lines = List<String>.of(parts);
    var trimmed = false;

    // 1. A file that did not end with a newline lost its last record
    //    mid-write (truncation) — the final line is a partial frame.
    if (!endsWithNewline) {
      lines.removeLast();
      trimmed = true;
    }

    // 2. Trim trailing lines that fail to parse as JSON (garbled /
    //    interleaved write), down to the last complete record.
    while (lines.isNotEmpty && !_isParseable(lines.last)) {
      lines.removeLast();
      trimmed = true;
    }

    if (trimmed) {
      final repaired = lines.isEmpty ? '' : '${lines.join('\n')}\n';
      await file.writeAsString(repaired, flush: true);
    }

    return NdjsonRecoveryResult(
      recoveredRecords: lines.length,
      trimmedPartialTail: trimmed,
      repaired: trimmed,
    );
  }

  bool _isParseable(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return false;
    try {
      jsonDecode(trimmed);
      return true;
    } on FormatException {
      return false;
    }
  }
}
