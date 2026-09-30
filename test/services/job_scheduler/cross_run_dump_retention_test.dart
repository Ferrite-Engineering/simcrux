// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/services/job_scheduler/dump_retention.dart';

/// Dump retention must bound the retained set **across
/// runs**. The policy's own doc promised a cap holding "across months of
/// nightly regressions", but the only caller pruned the current run's
/// directory, so the real bound was N failures *per run* × unboundedly
/// many runs — no bound at all.
void main() {
  late Directory runRoot;
  late Directory runsRoot;
  late DateTime base;

  setUp(() {
    runRoot = Directory.systemTemp.createTempSync('simcrux_xrun_');
    runsRoot = runsRootFor(runRoot.path)..createSync(recursive: true);
    // One wall-clock reading shared by every stamp in a test — reading
    // `DateTime.now()` per-dump would make ordering depend on
    // file-I/O latency: on a loaded runner a slow iteration cancels the
    // intended age offset and scrambles the newest-first order.
    base = DateTime.now();
  });
  tearDown(() {
    if (runRoot.existsSync()) runRoot.deleteSync(recursive: true);
  });

  /// Creates `<runsRoot>/<runId>/<testId>/dump.vcd` of [bytes] bytes,
  /// stamped [ageSeconds] before [base].
  Directory makeDump(
    String runId,
    String testId,
    int bytes,
    int ageSeconds, {
    bool pinned = false,
  }) {
    final dir = Directory('${runsRoot.path}/$runId/$testId')
      ..createSync(recursive: true);
    File('${dir.path}/dump.vcd')
      ..writeAsBytesSync(List<int>.filled(bytes, 0x41))
      ..setLastModifiedSync(base.subtract(Duration(seconds: ageSeconds)));
    if (pinned) {
      File('${dir.path}/$kRetentionKeepMarker')
        ..writeAsStringSync('')
        ..setLastModifiedSync(base.subtract(Duration(seconds: ageSeconds)));
    }
    return dir;
  }

  Set<String> survivingTestDirs() {
    if (!runsRoot.existsSync()) return <String>{};
    final out = <String>{};
    for (final runDir in runsRoot.listSync().whereType<Directory>()) {
      final runId = runDir.path.split(Platform.pathSeparator).last;
      for (final testDir in runDir.listSync().whereType<Directory>()) {
        out.add('$runId/${testDir.path.split(Platform.pathSeparator).last}');
      }
    }
    return out;
  }

  test('keep-last-N is enforced across runs, not per run', () {
    // 5 runs × 4 failures each = 20 dirs; run 0 is newest.
    for (var run = 0; run < 5; run++) {
      for (var t = 0; t < 4; t++) {
        makeDump('r$run', 't$t', 10, run * 10 + t);
      }
    }
    final deleted = pruneRetainedDumpsAcrossRuns(
      runsRoot,
      const DumpRetentionPolicy(keepLastNFailures: 5),
    );
    expect(deleted, 15);
    final survivors = survivingTestDirs();
    expect(survivors, hasLength(5));
    // The five newest overall — all from the newest run(s), not five
    // per run.
    expect(
      survivors,
      <String>{'r0/t0', 'r0/t1', 'r0/t2', 'r0/t3', 'r1/t0'},
    );
  });

  test('byte ceiling is enforced across runs', () {
    for (var run = 0; run < 4; run++) {
      makeDump('r$run', 't0', 1000, run * 10);
    }
    final deleted = pruneRetainedDumpsAcrossRuns(
      runsRoot,
      const DumpRetentionPolicy(maxTotalBytes: 2500),
    );
    expect(deleted, 2);
    expect(survivingTestDirs(), <String>{'r0/t0', 'r1/t0'});
  });

  test('a $kRetentionKeepMarker marker pins a test dir against pruning', () {
    for (var run = 0; run < 6; run++) {
      // r5 is the oldest and would normally be pruned first.
      makeDump('r$run', 't0', 10, run * 10, pinned: run == 5);
    }
    pruneRetainedDumpsAcrossRuns(
      runsRoot,
      const DumpRetentionPolicy(keepLastNFailures: 2),
    );
    final survivors = survivingTestDirs();
    expect(
      survivors,
      contains('r5/t0'),
      reason: 'the pinned dir must survive despite being the oldest',
    );
    // Pinned dirs count toward the cap, so only one unpinned survivor.
    expect(survivors, <String>{'r0/t0', 'r5/t0'});
  });

  test('a run-level marker pins every test dir under that run', () {
    for (var run = 0; run < 4; run++) {
      for (var t = 0; t < 2; t++) {
        makeDump('r$run', 't$t', 10, run * 10 + t);
      }
    }
    File('${runsRoot.path}/r3/$kRetentionKeepMarker').writeAsStringSync('');
    pruneRetainedDumpsAcrossRuns(
      runsRoot,
      const DumpRetentionPolicy(keepLastNFailures: 1),
    );
    final survivors = survivingTestDirs();
    expect(survivors, containsAll(<String>['r3/t0', 'r3/t1']));
  });

  test('run directories emptied by pruning are swept', () {
    for (var run = 0; run < 4; run++) {
      makeDump('r$run', 't0', 10, run * 10);
    }
    pruneRetainedDumpsAcrossRuns(
      runsRoot,
      const DumpRetentionPolicy(keepLastNFailures: 1),
    );
    final runDirs = runsRoot.listSync().whereType<Directory>();
    expect(
      runDirs,
      hasLength(1),
      reason: 'emptied run shells must not accumulate under runs/',
    );
  });

  test('unbounded policy and a missing root are no-ops', () {
    makeDump('r0', 't0', 10, 0);
    expect(
      pruneRetainedDumpsAcrossRuns(runsRoot, DumpRetentionPolicy.unbounded),
      0,
    );
    expect(survivingTestDirs(), hasLength(1));
    expect(
      pruneRetainedDumpsAcrossRuns(
        Directory('${runRoot.path}/nope'),
        DumpRetentionPolicy.defaultPolicy,
      ),
      0,
    );
  });

  test(
    'an excluded (in-flight) run is never ranked, so the byte ceiling '
    'cannot delete its work dir',
    () {
      // r0 is the newest and largest; it stands in for another tab's LIVE
      // run. r1..r3 are older completed runs. A byte ceiling that would
      // otherwise evict r0 (newest-first ranking keeps it) is not the
      // hazard — the hazard is a ceiling small enough that r0 gets deleted.
      // Excluding r0 must keep it regardless of the ceiling.
      makeDump('r0', 't0', 5000, 0);
      for (var run = 1; run < 4; run++) {
        makeDump('r$run', 't0', 10, run * 10);
      }
      final deleted = pruneRetainedDumpsAcrossRuns(
        runsRoot,
        // Ceiling below r0's size: if r0 were ranked (newest-first) it would
        // consume the whole budget and doom r1..r3; counted at all, a tiny
        // ceiling would instead doom r0 itself. Excluding it must remove it
        // from the accounting entirely.
        const DumpRetentionPolicy(maxTotalBytes: 100),
        excludeRunIds: <String>{'r0'},
      );
      final survivors = survivingTestDirs();
      expect(
        survivors,
        contains('r0/t0'),
        reason: 'the in-flight run must survive regardless of the ceiling',
      );
      // r0 is neither counted nor deleted; r1..r3 (30 bytes total) fit
      // under the 100-byte ceiling, so nothing is pruned.
      expect(deleted, 0);
      expect(survivors, <String>{'r0/t0', 'r1/t0', 'r2/t0', 'r3/t0'});
    },
  );

  test(
    'MUTATION: without the in-flight guard, a tiny ceiling deletes the '
    'live run',
    () {
      makeDump('r0', 't0', 5000, 0);
      makeDump('r1', 't0', 10, 10);
      // No exclusion — the old behaviour ranked every dir including r0.
      pruneRetainedDumpsAcrossRuns(
        runsRoot,
        const DumpRetentionPolicy(maxTotalBytes: 100),
      );
      expect(
        survivingTestDirs(),
        isNot(contains('r0/t0')),
        reason: 'demonstrates the pre-fix hazard the exclusion guards',
      );
    },
  );

  test(
    'a directory already gone before describe does not throw the prune',
    () {
      for (var run = 0; run < 3; run++) {
        makeDump('r$run', 't0', 10, run * 10);
      }
      // r1/t0 was enumerated by a real race but deleted before _describe
      // walks it; here it is simply already gone. The tolerant walk must
      // treat it as empty rather than throwing FileSystemException out of
      // the whole prune (which, awaited unguarded, wedges run completion).
      Directory('${runsRoot.path}/r1/t0').deleteSync(recursive: true);
      expect(
        () => pruneRetainedDumpsAcrossRuns(
          runsRoot,
          const DumpRetentionPolicy(keepLastNFailures: 1),
        ),
        returnsNormally,
      );
    },
  );

  test(
    'two concurrent prunes over one tree both complete (the two-tab race)',
    () async {
      // The two-tab wedge: two tabs prune the same runs/ tree
      // near-simultaneously; one deletes a dir the other is mid-walk on,
      // throwing FileSystemException. The async isolate form is a genuine
      // cross-isolate race over a shared filesystem — both must settle
      // without throwing, or the unguarded await at run completion never
      // reaches RegressionFinished.
      for (var run = 0; run < 40; run++) {
        for (var t = 0; t < 4; t++) {
          makeDump('r$run', 't$t', 10, run * 4 + t);
        }
      }
      const policy = DumpRetentionPolicy(keepLastNFailures: 10);
      final results = await Future.wait<int>(<Future<int>>[
        pruneRetainedDumpsAcrossRunsAsync(runsRoot, policy),
        pruneRetainedDumpsAcrossRunsAsync(runsRoot, policy),
      ]);
      // Both futures resolved (no thrown FileSystemException escaped).
      expect(results, hasLength(2));
      // The tree converged to at most the cap (the two racers may each
      // count some already-deleted dirs, but never over-retain).
      expect(survivingTestDirs().length, lessThanOrEqualTo(10));
    },
  );

  test('the async off-isolate form prunes identically', () async {
    for (var run = 0; run < 5; run++) {
      for (var t = 0; t < 4; t++) {
        makeDump('r$run', 't$t', 10, run * 10 + t);
      }
    }
    final deleted = await pruneRetainedDumpsAcrossRunsAsync(
      runsRoot,
      const DumpRetentionPolicy(keepLastNFailures: 5),
    );
    expect(deleted, 15);
    expect(survivingTestDirs(), hasLength(5));
  });
}
