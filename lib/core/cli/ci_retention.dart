// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:simcrux/services/job_scheduler/dump_retention.dart';

/// The failure-folder retention a `--ci` run prunes by.
///
/// [keepFailures] is `--keep-failures <n>` (null = the default 50). The
/// run's own failure folders are never removed; earlier runs' are, oldest
/// first, and every removal is reported through [log] (stderr), so a
/// counterexample or log never disappears from a runner without a line in
/// the job output saying where it was.
///
/// Shared by the standalone binary and the desktop app's `--ci` branch so
/// the two prune and report alike.
DumpRetentionPolicy ciDumpRetentionPolicy({
  required int? keepFailures,
  required void Function(String line) log,
}) {
  final keep =
      keepFailures ?? DumpRetentionPolicy.defaultPolicy.keepLastNFailures;
  return DumpRetentionPolicy.withKeepCount(
    keepFailures,
    onPruned: (removed) {
      final noun = removed.length == 1 ? 'folder' : 'folders';
      log(
        'simcrux: removed ${removed.length} failure $noun of earlier runs '
        "(keeping the newest $keep failures across runs; this run's own are "
        'always kept; --keep-failures <n> sets the number):',
      );
      for (final path in removed) {
        log('simcrux:   $path');
      }
    },
  );
}
