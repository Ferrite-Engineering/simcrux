// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/domain/interfaces/trend_store.dart';
import 'package:simcrux/domain/models/retention_policy.dart';

/// Outcome of one sweep.
@immutable
class WaveformSweepResult {
  /// Creates a result.
  const WaveformSweepResult({
    required this.deletedFiles,
    required this.reclaimedBytes,
    required this.missingFiles,
  });

  /// A sweep that did nothing.
  static const WaveformSweepResult none = WaveformSweepResult(
    deletedFiles: 0,
    reclaimedBytes: 0,
    missingFiles: 0,
  );

  /// Files actually unlinked.
  final int deletedFiles;

  /// Bytes freed, summed from each file's size before deletion.
  final int reclaimedBytes;

  /// Paths the store still referenced but that were already gone — the
  /// user cleaned up by hand, or a working directory was wiped. Counted
  /// rather than treated as an error; their rows are still forgotten.
  final int missingFiles;

  /// Whether anything changed.
  bool get didSomething => deletedFiles > 0 || missingFiles > 0;

  @override
  String toString() =>
      'WaveformSweepResult(deleted: $deletedFiles, '
      'reclaimed: $reclaimedBytes B, missing: $missingFiles)';
}

/// Deletes waveform artifacts belonging to runs outside the retention
/// window ("keep waveforms for last N runs").
///
/// The trend store's row-count retention bounds the *database*; nothing
/// bounded the dumps, which are the part that actually fills a disk — a
/// nightly regression writing FSTs will outgrow trends.db by three orders
/// of magnitude and keep going.
///
/// **Deletes files, never directories.** A waveform path points into a
/// working directory that may hold logs, coverage, and build products the
/// user still wants; removing the parent because it happened to contain a
/// dump would destroy data the policy never claimed to govern.
///
/// Every filesystem error is swallowed per-file. A permission-denied dump
/// on a network mount must not abort the sweep for the other ninety, and it
/// certainly must not fail the regression that triggered it.
class WaveformRetentionSweeper {
  /// Creates a sweeper.
  const WaveformRetentionSweeper({FileSystemDelegate? fileSystem})
    : _fs = fileSystem ?? const FileSystemDelegate();

  final FileSystemDelegate _fs;

  /// Sweeps [store] according to [policy]. A null or negative
  /// `maxWaveformRuns` is "keep everything" and returns immediately.
  Future<WaveformSweepResult> sweep(
    TrendStore store,
    RetentionPolicy policy,
  ) async {
    final keep = policy.maxWaveformRuns;
    if (keep == null || keep < 0) return WaveformSweepResult.none;

    final List<String> stale;
    try {
      stale = await store.waveformPathsBeforeRecentRuns(keep);
    } on Object {
      // A store that cannot answer is a store with nothing to sweep.
      return WaveformSweepResult.none;
    }
    if (stale.isEmpty) return WaveformSweepResult.none;

    var deleted = 0;
    var missing = 0;
    var bytes = 0;
    final swept = <String>[];

    for (final path in stale) {
      try {
        final size = await _fs.sizeOf(path);
        if (size == null) {
          missing++;
          swept.add(path);
          continue;
        }
        await _fs.delete(path);
        deleted++;
        bytes += size;
        swept.add(path);
      } on Object catch (e) {
        // Locked by a viewer, read-only mount, vanished mid-sweep. Leave
        // the row pointing at it: the file may still be openable, and a
        // dangling "Open waveform" is worse than a retained one.
        debugPrint('waveform sweep: could not remove $path: $e');
      }
    }

    if (swept.isNotEmpty) {
      try {
        await store.forgetWaveformPaths(swept);
      } on Object {
        // The files are gone either way; the stale paths will be retried
        // on the next sweep.
      }
    }

    return WaveformSweepResult(
      deletedFiles: deleted,
      reclaimedBytes: bytes,
      missingFiles: missing,
    );
  }
}

/// The filesystem operations the sweeper needs, injectable so tests can
/// drive it without touching real files.
class FileSystemDelegate {
  /// Creates a delegate over `dart:io`.
  const FileSystemDelegate();

  /// Size of [path] in bytes, or null when it does not exist.
  Future<int?> sizeOf(String path) async {
    final file = File(path);
    if (!file.existsSync()) return null;
    return file.length();
  }

  /// Unlinks [path].
  Future<void> delete(String path) => File(path).delete();
}

/// The active sweeper. Overridden in tests with a stub filesystem.
final Provider<WaveformRetentionSweeper> waveformRetentionSweeperProvider =
    Provider<WaveformRetentionSweeper>(
      (ref) => const WaveformRetentionSweeper(),
    );
