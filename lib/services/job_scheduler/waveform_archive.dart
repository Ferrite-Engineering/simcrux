// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:simcrux/services/job_scheduler/dump_retention.dart';

/// A durable, size-bounded archive of waveform dumps from *passing* tests.
///
/// [LocalJobScheduler] deletes a passing test's working directory the moment
/// the test finishes (only failing tests' dirs are retained, for
/// reproduction). That directory holds the run's waveform dump — the very
/// artifact "Debug in WaveCrux" and the inspector's waveform view hand off —
/// so without intervention the dump is gone before the user can open it, and
/// the recorded `waveformPath` dangles into a deleted temp directory.
///
/// This archive relocates a passing test's dump into a durable pool under the
/// application-support directory *before* the work dir is deleted, so a later
/// hand-off resolves a file that still exists across app restarts (the run
/// tree itself lives in the system temp dir, which the OS reaps).
///
/// The pool is bounded by its **own** [DumpRetentionPolicy], independent of
/// the failing-work-dir retention budget. Keeping the budgets separate is the
/// whole point: retained passing waveforms can never evict the failing-test
/// directories a user reproduces from, and vice versa.
class WaveformArchive {
  /// Creates an archive whose pool root is produced by [resolveRoot].
  ///
  /// [resolveRoot] is awaited once (lazily, on first [retain]/[prune]) and
  /// memoised — production resolves `<applicationSupportDirectory>/waveforms`;
  /// tests point it at a temp directory.
  WaveformArchive({required Future<String> Function() resolveRoot})
    // A private field cannot be a named initializing formal (named parameters
    // can't start with `_`), so the lint's suggested fix does not apply here.
    // ignore: prefer_initializing_formals
    : _resolveRoot = resolveRoot;

  final Future<String> Function() _resolveRoot;
  Future<String>? _rootFuture;

  Future<String> _root() => _rootFuture ??= _resolveRoot();

  /// The conventional per-test destination directory basename.
  ///
  /// Mirrors [LocalJobScheduler]'s work-dir sanitisation so a test's archive
  /// entry lines up with its (transient) work dir name.
  static String _safeTestId(String testId) =>
      testId.replaceAll(RegExp('[^A-Za-z0-9._+-]'), '_');

  /// Move the dump at [waveformPath] into the pool under
  /// `<root>/<runId>/<safeTestId>/<basename>`, returning the new absolute
  /// path — or `null` if it could not be archived (source already gone, or an
  /// IO error). Callers treat `null` as "no durable waveform" and null out the
  /// recorded path rather than record a location that does not exist.
  ///
  /// Cross-device safe: the run tree is in the system temp dir and the pool is
  /// under application-support, which can be a different filesystem where
  /// [File.rename] throws — so a failed rename falls back to copy-then-delete.
  Future<String?> retain({
    required String waveformPath,
    required String runId,
    required String testId,
  }) async {
    final source = File(waveformPath);
    if (!source.existsSync()) return null;
    try {
      final root = await _root();
      final destDir = Directory(
        p.join(root, runId, _safeTestId(testId)),
      )..createSync(recursive: true);
      final destPath = p.join(destDir.path, p.basename(waveformPath));
      try {
        await source.rename(destPath);
      } on FileSystemException {
        // Cross-device rename is not permitted — copy then remove the source.
        await source.copy(destPath);
        try {
          await source.delete();
        } on Object {
          // The copy is what matters; a lingering source is swept with the
          // work dir moments later.
        }
      }
      return destPath;
    } on Object {
      // Best-effort: if the pool is unwritable, the caller nulls the path and
      // the "waveform was cleaned up" message covers the hand-off.
      return null;
    }
  }

  /// Prune the pool to [policy] across all runs, returning the number of
  /// per-test entries deleted. Reuses the cross-run dump-retention ranking:
  /// the pool root plays the role of `<runRoot>/runs`, with one `<runId>/`
  /// subdirectory per run and one `<safeTestId>/` directory per entry.
  Future<int> prune(DumpRetentionPolicy policy) async {
    if (policy.isUnbounded) return 0;
    final root = await _root();
    return await pruneRetainedDumpsAcrossRunsAsync(Directory(root), policy);
  }
}
