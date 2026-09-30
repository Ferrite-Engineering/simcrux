// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

/// Retention policy for per-test working directories and the waveform
/// dumps (`*.vcd` / `*.fst` / `*.ghw`) they contain.
///
/// The scheduler retains the working directory of every *failing* test so
/// the user can inspect logs and reproduce the run; across months of
/// nightly regressions that retained set — and especially the waveform
/// dumps inside it — grows without bound and fills the disk. This policy
/// caps it the same way the SQLite trend store's
/// `retention_policy_provider.dart` caps the database: keep the most
/// recent N failures and enforce a total-byte ceiling, pruning oldest
/// first.
///
/// **The cap is global across runs**, which is the only reading under
/// which the paragraph above is true. [pruneRetainedDumpsAcrossRuns]
/// ranks every retained directory under `<runRoot>/runs/` together; a
/// per-run cap cannot bound growth, because N failures per run times
/// unboundedly many runs is unbounded.
class DumpRetentionPolicy {
  /// Creates a [DumpRetentionPolicy].
  const DumpRetentionPolicy({
    this.keepLastNFailures,
    this.maxTotalBytes,
  });

  /// The default: keep the 50 most recent failure directories and cap the
  /// retained set at 2 GiB. Generous enough for interactive debugging,
  /// bounded enough to never fill a CI disk.
  static const DumpRetentionPolicy defaultPolicy = DumpRetentionPolicy(
    keepLastNFailures: 50,
    maxTotalBytes: 2 * 1024 * 1024 * 1024,
  );

  /// An unbounded policy — retains everything (the historical behaviour).
  static const DumpRetentionPolicy unbounded = DumpRetentionPolicy();

  /// Maximum number of retained failure directories. Null = no count cap.
  final int? keepLastNFailures;

  /// Maximum total bytes across all retained directories. Null = no byte
  /// cap. When exceeded, oldest directories are pruned until under it.
  final int? maxTotalBytes;

  /// Whether this policy prunes anything at all.
  bool get isUnbounded => keepLastNFailures == null && maxTotalBytes == null;
}

/// Marker filename that pins a retained directory against pruning.
///
/// Drop an empty `.simcrux-keep` file into a per-test working directory
/// (or into a `<runRoot>/runs/<runId>` directory, which pins every test
/// dir under it) and retention will never delete it — the escape hatch
/// for "I am still bisecting this failure, do not let tonight's
/// regression garbage-collect it". Pinned directories still count
/// toward the byte total, so a user who pins more than the ceiling
/// simply gets no pruning rather than a silently-violated policy.
const String kRetentionKeepMarker = '.simcrux-keep';

/// Runs [pruneRetainedDumpsAcrossRuns] on a short-lived background isolate
/// via [Isolate.run] and returns the number of directories deleted. This is
/// the production entry point: the scheduler calls it at run completion,
/// and so does the waveform archive.
///
/// The walk stats every retained file under *every* run directory and
/// deletes recursively, which on a large run tree with waveform dumps is
/// seconds of blocking filesystem work — far too much for the UI isolate.
/// Only plain sendables (the path string, the policy's two ints and the
/// excluded run ids) cross the isolate boundary.
Future<int> pruneRetainedDumpsAcrossRunsAsync(
  Directory runsRoot,
  DumpRetentionPolicy policy, {
  Set<String> excludeRunIds = const <String>{},
}) {
  if (policy.isUnbounded) return Future.value(0);
  final path = runsRoot.path;
  final keepLastNFailures = policy.keepLastNFailures;
  final maxTotalBytes = policy.maxTotalBytes;
  // Copy to a plain set so only sendables cross the isolate boundary.
  final excluded = Set<String>.of(excludeRunIds);
  return Isolate.run(
    () => pruneRetainedDumpsAcrossRuns(
      Directory(path),
      DumpRetentionPolicy(
        keepLastNFailures: keepLastNFailures,
        maxTotalBytes: maxTotalBytes,
      ),
      excludeRunIds: excluded,
    ),
    debugName: 'simcrux-dump-retention-all-runs',
  );
}

/// Prunes retained per-test working directories across **every** run
/// under [runsRoot] (the `<runRoot>/runs/` directory), applying
/// [policy] to their union. Returns the number of directories deleted.
///
/// Pruning must span every run for [DumpRetentionPolicy]'s cap to
/// hold: applied per-run, "keep the 50 most recent failures under
/// 2 GiB" means 50 failures *per run* times every run ever executed,
/// which grows without bound across months of nightly regressions.
///
/// Ranking is global and newest-first by directory mtime, so the
/// surviving set is genuinely "the N most recent failures overall".
/// Directories pinned with [kRetentionKeepMarker] always survive.
/// A run directory left empty by pruning is removed too, so
/// `<runRoot>/runs/` does not accumulate thousands of empty shells.
///
/// [excludeRunIds] names run directories (by their `<runId>` basename)
/// that are still in-flight — another tab's live run. They are skipped
/// entirely: neither ranked (so the byte ceiling can never delete a
/// live run's work dir out from under the running simulator) nor swept
/// as empty. The caller passes every in-flight run except the one whose
/// completion triggered this prune.
///
/// The directory walks are per-directory exception-tolerant: when two
/// tabs prune the same tree near-simultaneously a directory can vanish
/// mid-walk, and a thrown [FileSystemException] must not abort the whole
/// prune (which, awaited unguarded at run completion, would wedge the
/// run in "running" forever). A vanished directory is treated as empty
/// and skipped.
int pruneRetainedDumpsAcrossRuns(
  Directory runsRoot,
  DumpRetentionPolicy policy, {
  Set<String> excludeRunIds = const <String>{},
}) {
  if (policy.isUnbounded || !runsRoot.existsSync()) return 0;
  final runDirs = _listDirsTolerant(
    runsRoot,
  ).where((d) => !excludeRunIds.contains(p.basename(d.path))).toList();
  final candidates = <_DumpDir>[];
  for (final runDir in runDirs) {
    // A marker at the run level pins the whole run.
    final runPinned = File(
      p.join(runDir.path, kRetentionKeepMarker),
    ).existsSync();
    for (final testDir in _listDirsTolerant(runDir)) {
      candidates.add(_describe(testDir, forcePinned: runPinned));
    }
  }
  final deleted = _applyPolicy(candidates, policy);
  // Sweep run directories that pruning emptied of test dirs.
  for (final runDir in runDirs) {
    try {
      final remaining = runDir.listSync();
      if (remaining.isEmpty) runDir.deleteSync();
    } on Object {
      // Best-effort: a locked or already-removed dir is skipped.
    }
  }
  return deleted;
}

/// Lists the immediate subdirectories of [dir], tolerating a
/// [FileSystemException] from a directory that vanished mid-walk
/// (concurrent prune over the same tree) by returning what was read so
/// far — or nothing when the listing itself threw.
List<Directory> _listDirsTolerant(Directory dir) {
  try {
    return dir.listSync().whereType<Directory>().toList();
  } on FileSystemException {
    return const <Directory>[];
  }
}

/// One retained directory with the two facts the policy ranks on, plus
/// whether the user pinned it with [kRetentionKeepMarker].
typedef _DumpDir = ({Directory dir, DateTime mtime, int bytes, bool pinned});

_DumpDir _describe(Directory dir, {bool forcePinned = false}) {
  var newest = DateTime.fromMillisecondsSinceEpoch(0);
  var sawFile = false;
  var bytes = 0;
  var pinned = forcePinned;
  // One walk for mtime, size and the pin marker — the previous code
  // walked the tree twice per directory (_dirMtime then _dirBytes).
  //
  // Tolerate the directory vanishing mid-walk: a concurrent prune over
  // the same tree (two tabs finishing near-simultaneously) can delete it
  // between the enclosing listing and this recursive walk. A thrown
  // FileSystemException here would otherwise propagate out of the prune
  // and — awaited unguarded at run completion — wedge the run forever.
  List<FileSystemEntity> entities;
  try {
    entities = dir.listSync(recursive: true);
  } on FileSystemException {
    entities = const <FileSystemEntity>[];
  }
  for (final entity in entities) {
    if (entity is! File) continue;
    if (p.basename(entity.path) == kRetentionKeepMarker) pinned = true;
    try {
      bytes += entity.lengthSync();
    } on Object {
      // Ignore unreadable files in the size accounting.
    }
    try {
      final m = entity.statSync().modified;
      if (!sawFile || m.isAfter(newest)) newest = m;
      sawFile = true;
    } on Object {
      // Ignore unstatable files in the age accounting.
    }
  }
  return (
    dir: dir,
    // Fall back to the directory's own mtime only when it holds no files.
    // statSync on a vanished dir returns a notFound stat (epoch), never
    // throws, so a raced-away empty dir sorts oldest and is pruned first.
    mtime: sawFile ? newest : dir.statSync().modified,
    bytes: bytes,
    pinned: pinned,
  );
}

/// Ranks [candidates] newest-first and deletes those the policy does
/// not admit. Returns the number of directories deleted.
///
/// The byte ceiling is enforced against a **running** total rather
/// than by re-folding the survivor list per candidate, which would be
/// O(n²) in the number of retained directories — on the cross-run set
/// (thousands of dirs across months of runs) that is the difference
/// between a linear walk and a quadratic one.
int _applyPolicy(List<_DumpDir> candidates, DumpRetentionPolicy policy) {
  // Newest first.
  candidates.sort((a, b) => b.mtime.compareTo(a.mtime));

  final doomed = <Directory>[];
  var survivorCount = 0;
  var survivorBytes = 0;

  // Pinned directories are charged against the budget up front, before
  // any unpinned directory is admitted. Charging them in mtime order
  // instead would let unpinned dirs newer than a pin claim slots the
  // pin then exceeds — the cap would be silently over-subscribed by
  // exactly the number of pins. Accounting first means a pinned set at
  // or over the ceiling degrades to "prune everything unpinned", and
  // the ceiling still holds.
  for (final entry in candidates) {
    if (!entry.pinned) continue;
    survivorCount++;
    survivorBytes += entry.bytes;
  }

  for (final entry in candidates) {
    if (entry.pinned) continue; // Already accounted for; always survives.
    final overCount =
        policy.keepLastNFailures != null &&
        survivorCount >= policy.keepLastNFailures!;
    final overBytes =
        policy.maxTotalBytes != null &&
        survivorBytes + entry.bytes > policy.maxTotalBytes!;
    if (overCount || overBytes) {
      doomed.add(entry.dir);
    } else {
      survivorCount++;
      survivorBytes += entry.bytes;
    }
  }

  var deleted = 0;
  for (final dir in doomed) {
    try {
      dir.deleteSync(recursive: true);
      deleted++;
    } on Object {
      // Best-effort; a locked dir is skipped rather than failing the run.
    }
  }
  return deleted;
}

/// Convenience: the conventional `<runRoot>/runs` directory holding one
/// subdirectory per run. The unit [pruneRetainedDumpsAcrossRuns] caps.
Directory runsRootFor(String runRoot) => Directory(p.join(runRoot, 'runs'));
