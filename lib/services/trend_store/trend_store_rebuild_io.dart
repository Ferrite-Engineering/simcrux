// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:developer' as developer;

import 'package:simcrux/domain/interfaces/trend_store.dart';
import 'package:simcrux/domain/models/trend_store_rebuild_report.dart';
import 'package:simcrux/services/result_store/streaming_result_row.dart';
import 'package:simcrux/services/result_store/streaming_results_writer.dart';
import 'package:simcrux/services/trend_store/trend_store_log_name.dart';

/// Rebuilds trend history from the streaming `results.ndjson` archives a run
/// left behind.
///
/// **What this is for.** `trends.db` is PRECIOUS — nothing on disk rebuilds a
/// regression history *in general*. This is the one partial exception, and the
/// word partial is the whole design: a `--ci` run (or any run with
/// `output: { streaming: true }`) writes every result to `results.ndjson` as
/// it arrives, so for those runs, and only those, the archive carries every
/// field a trend point is made of. Runs recorded by the GUI with streaming off
/// left no archive and cannot be recovered by anything.
///
/// **Never automatic.** It is offered from the App Diagnostics recovery card
/// after a quarantine and runs only when the user picks archives and asks for
/// it. Reconstructing a partial history silently, into a store whose whole
/// purpose is trend comparison across runs, would produce charts that look
/// complete and are not — a data-integrity bug wearing recovery's clothes. The
/// user chooses which archives, and is told exactly what came back.
///
/// **It never writes to the archives.** Recovery is read-only over the user's
/// files: [StreamingResultsReader] is invoked with its default
/// [NoopNdjsonRecovery], so a crash-truncated tail is skipped by the decoder
/// rather than trimmed on disk. Repairing an archive in place is a legitimate
/// thing for the *export* pipeline to do to its own output; it is not
/// something a recovery path may do to the only surviving copy of a run.
///
/// **Fidelity.** All seven [TrendPoint] fields come out of the archive
/// verbatim — `run_id` from the `meta` line, `id`, `status`, `runtime_ms`,
/// `started_at`, `waveform_path` and `suite` from each result line, the
/// runtime written as `finishedAt - startedAt`, which is exactly what the live
/// ingest path records. `waveform_path` matters beyond display: it is what
/// the waveform retention sweep reads, so a replay that dropped it would
/// silently exempt every restored run's dump from `maxWaveformRuns`. `suite`
/// is what the per-suite trend view filters on, so a replay that dropped it
/// would restore runs that no suite's chart can show.
/// Two things do not survive: a run's `config_hash` and trigger kind
/// (the live GUI path does not record them either — `recordTrendPoints`
/// creates the run row lazily with the same empty values), and, for archives
/// written before `did_execute` was added to the stream, the distinction
/// between a test that ran and one whose toolchain never launched. Older
/// archives read as "everything executed", which is what the store recorded
/// for them anyway.
class TrendStoreRebuilder {
  /// Creates a [TrendStoreRebuilder].
  const TrendStoreRebuilder();

  /// The archive reader. Not injectable: a rebuild that read anything other
  /// than a real `results.ndjson` off the real disk would prove nothing, so
  /// the tests drive this with actual files written by
  /// [StreamingResultsWriter] — the producer whose output this must consume.
  static const StreamingResultsReader _reader = StreamingResultsReader();

  /// Replays [archivePaths] into [store] and reports what came back.
  ///
  /// Archives are independent: one unreadable file is a line in the report,
  /// not an abandoned rebuild. A rebuild that gave up halfway would leave the
  /// user with a partially reconstructed store and no account of it.
  Future<TrendStoreRebuildReport> rebuild({
    required TrendStore store,
    required List<String> archivePaths,
  }) async {
    final results = <TrendStoreArchiveResult>[];
    for (final path in archivePaths) {
      results.add(await _replay(store, path));
    }
    final report = TrendStoreRebuildReport(archives: results);
    developer.log(
      'Trend store rebuild: ${report.pointsRecovered} points across '
      '${report.runsRecovered} runs from ${archivePaths.length} archives',
      name: kTrendStoreLogName,
    );
    return report;
  }

  Future<TrendStoreArchiveResult> _replay(
    TrendStore store,
    String path,
  ) async {
    final StreamingResultsDocument doc;
    try {
      doc = await _reader.readFile(path);
    } on Object catch (error) {
      // Missing, unreadable, a directory, not text. One bad selection must
      // not cost the user the archives either side of it.
      return TrendStoreArchiveResult(
        path: path,
        outcome: TrendStoreArchiveOutcome.unreadable,
        runId: null,
        pointsRecovered: 0,
        rowsSkipped: 0,
        runWasComplete: false,
        detail: '$error',
      );
    }

    final runId = doc.meta?.runId;
    if (runId == null || runId.isEmpty) {
      return TrendStoreArchiveResult(
        path: path,
        outcome: TrendStoreArchiveOutcome.missingRunId,
        runId: null,
        pointsRecovered: 0,
        rowsSkipped: doc.rows.length,
        runWasComplete: doc.summary != null,
      );
    }

    final points = <TrendPoint>[];
    var skipped = 0;
    for (final row in doc.rows) {
      final point = _pointFrom(row, runId);
      if (point == null) {
        skipped++;
        continue;
      }
      points.add(point);
    }

    if (points.isEmpty) {
      return TrendStoreArchiveResult(
        path: path,
        outcome: TrendStoreArchiveOutcome.empty,
        runId: runId,
        pointsRecovered: 0,
        rowsSkipped: skipped,
        runWasComplete: doc.summary != null,
      );
    }

    // Idempotence, and the reason it is a query rather than an
    // `INSERT OR IGNORE`: `test_results.id` is `<runId>:<testId>`, so a second
    // replay of the same archive would violate the primary key. Deciding it
    // up front lets a user re-run the rebuild with an overlapping selection
    // — which is exactly what happens when they find one more archive an hour
    // later — without either an exception or a double-counted run.
    if ((await store.pointsForRun(runId)).isNotEmpty) {
      return TrendStoreArchiveResult(
        path: path,
        outcome: TrendStoreArchiveOutcome.alreadyPresent,
        runId: runId,
        pointsRecovered: 0,
        rowsSkipped: skipped,
        runWasComplete: doc.summary != null,
      );
    }

    await store.recordTrendPoints(points);

    // Stamp the finish time when — and only when — the archive proves the run
    // finished. `recordTrendPoints` creates the run row with a null
    // `finished_at`, and `reconcileInterruptedRuns` marks every such row
    // `interrupted` at the next open. Without this every rebuilt run would be
    // relabelled a crash; with it, the runs that *were* crashes (no trailing
    // `summary` line) keep the label they earned.
    final finishedAt = doc.summary?.finishedAt;
    if (finishedAt != null) {
      await store.markRunFinished(runId, finishedAt);
    }

    return TrendStoreArchiveResult(
      path: path,
      outcome: TrendStoreArchiveOutcome.recovered,
      runId: runId,
      pointsRecovered: points.length,
      rowsSkipped: skipped,
      runWasComplete: finishedAt != null,
    );
  }

  /// Projects one archived `result` line onto a [TrendPoint], or `null` when
  /// the row is not one the live ingest path would have recorded.
  /// Narrows one archive row to the fields a [TrendPoint] holds.
  ///
  /// **The key names are not here.** They live once, in
  /// [StreamingResultRow.parse], because this is no longer the only reader of
  /// an archive — the Enterprise shared team database projects the same lines
  /// and wants every field rather than a trend point's few. Two callers each reaching into
  /// the raw map by string key would be two copies of the wire format, and the
  /// second one added would drift from this one the first time a key changed.
  ///
  /// What this method still owns is the *narrowing*, which is a trend-store
  /// decision rather than an archive one.
  static TrendPoint? _pointFrom(Map<String, Object?> row, String runId) {
    final parsed = StreamingResultRow.parse(row);
    if (parsed == null) return null;
    // The live ingest filter, replayed. A run that never launched the
    // toolchain (`iverilog` not installed, no driver registered) is surfaced
    // on the dashboard but excluded from the trend store, because a missing
    // simulator is not a fact about the test's behaviour.
    if (!parsed.didExecute) return null;
    return TrendPoint(
      runId: runId,
      testId: parsed.testId,
      status: parsed.status,
      runtime: parsed.runtime,
      startedAt: parsed.startedAt,
      waveformPath: parsed.waveformPath,
      suiteName: parsed.suiteName,
    );
  }
}
