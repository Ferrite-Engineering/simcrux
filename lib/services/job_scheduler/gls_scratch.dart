// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:simcrux/services/scratch/simcrux_scratch.dart';

/// SimCrux's own scratch directory for gate-level simulation: the generated
/// port-dump modules and the two port dumps of every gate-level test.
///
/// Every run gets one generated safe segment under [root], and every test one
/// below it, so a generated file is never written into a run directory or the
/// project. The newest [keepRuns] runs are kept (the triage view and "Open
/// gate-level waveform" read their dumps); older ones are removed, and only
/// directories directly under [root] that this class made.
///
/// It lives beside the job scheduler's work-directory sweep: this is the one
/// place that deletes anything on behalf of gate level, and what it deletes is
/// only ever its own scratch, never anything under a flow run's root.
class GlsScratch {
  /// Creates the scratch. [root] defaults to `gls` in SimCrux's own scratch
  /// ([SimcruxScratch]), which on Linux is in the user's cache directory
  /// rather than the shared `/tmp`.
  GlsScratch({String? root, this.keepRuns = 3})
    : root = root ?? SimcruxScratch.gateLevel(),
      _base = root ?? SimcruxScratch.defaultBase();

  /// The directory runs are allocated under.
  final String root;

  /// The directory checked before anything is written: SimCrux's scratch
  /// base for the default root, else [root] itself.
  final String _base;

  /// How many runs are kept.
  final int keepRuns;

  static const String _prefix = 'gls-';

  /// A safe segment for [runId]: `gls-<id with unsafe characters replaced>`,
  /// at most 64 characters.
  static String segmentFor(String runId) {
    final safe = runId.replaceAll(RegExp('[^A-Za-z0-9._-]'), '_');
    final clipped = safe.length > 56 ? safe.substring(0, 56) : safe;
    return '$_prefix$clipped';
  }

  /// Creates the directory for [runId] and returns its path, removing the
  /// oldest runs beyond [keepRuns] first. A directory the run id already has
  /// gets a numeric suffix, so nothing an earlier run wrote is reused.
  ///
  /// Throws a [FileSystemException] when the scratch is refused: a symbolic
  /// link, or a directory other users can write.
  Future<String> allocateRun(String runId) async {
    SimcruxScratch.prepare(root, base: _base);
    await _prune();
    final segment = segmentFor(runId);
    var name = segment;
    for (var n = 2; n < 1000; n++) {
      if (FileSystemEntity.typeSync(p.join(root, name), followLinks: false) ==
          FileSystemEntityType.notFound) {
        break;
      }
      name = '$segment-$n';
    }
    final dir = p.join(root, name);
    await Directory(dir).create();
    return dir;
  }

  /// The directory of test number [index] in the run at [runDir], created.
  Future<String> allocateTest(String runDir, int index) async {
    final dir = p.join(runDir, 't$index');
    await Directory(dir).create(recursive: true);
    return dir;
  }

  Future<void> _prune() async {
    final dirs = <({String path, DateTime modified})>[];
    try {
      for (final entity in Directory(root).listSync(followLinks: false)) {
        if (entity is! Directory) continue;
        if (!p.basename(entity.path).startsWith(_prefix)) continue;
        if (p.dirname(entity.path) != root) continue;
        dirs.add((path: entity.path, modified: entity.statSync().modified));
      }
    } on FileSystemException {
      return;
    }
    // Leave room for the run about to be made.
    final keep = keepRuns > 0 ? keepRuns - 1 : 0;
    if (dirs.length <= keep) return;
    dirs.sort((a, b) => b.modified.compareTo(a.modified));
    for (final old in dirs.skip(keep)) {
      try {
        await Directory(old.path).delete(recursive: true);
      } on FileSystemException {
        // A directory another process holds is left for the next run.
      }
    }
  }
}
