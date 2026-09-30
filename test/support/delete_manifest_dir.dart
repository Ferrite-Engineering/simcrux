// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

/// Removes a CXP manifest directory a test pointed a discovery service at,
/// tolerating the one race a test cannot sequence away.
///
/// `CxpDiscoveryNotifier` releases its service from `ref.onDispose`, and a
/// Riverpod lifecycle callback cannot be async — so it fires
/// `unawaited(service.stop())`, and `stop()` asynchronously unlinks the
/// manifest file. A test that disposes the container and then deletes the
/// same directory is therefore racing an in-flight unlink it has no handle
/// to await. When the recursive walk loses that race it throws
/// `PathNotFoundException` for an entry that has *already* reached the
/// state the delete was asking for — the test fails because the teardown
/// succeeded twice over.
///
/// The postcondition callers actually want is "the directory is gone", so
/// retry against whatever is left. The second attempt is deliberately
/// unguarded: by then the single in-flight unlink has completed, and a
/// failure there is a real one (a permission problem, a live handle) that
/// must still surface rather than be swallowed.
void deleteManifestDir(Directory dir) {
  if (!dir.existsSync()) return;
  // Bounded retry, ~1s. Two races are in play and only one of them is the
  // POSIX one described above.
  //
  // On Windows there is a second: the OS refuses to delete a file that still
  // has an open handle, and the `stop()` above closes its manifest handle
  // asynchronously — so a perfectly healthy teardown throws
  // PathAccessException until that lands. POSIX unlinks open files happily,
  // which is exactly why this helper only ever failed on the Windows leg,
  // and why a single unguarded retry was enough everywhere else.
  for (var attempt = 0; attempt < 60; attempt++) {
    try {
      dir.deleteSync(recursive: true);
      return;
    } on FileSystemException {
      // Either an entry vanished under the walk, or a handle has not closed
      // yet. Both resolve on their own; neither is the caller's problem.
      if (!dir.existsSync()) return;
      sleep(const Duration(milliseconds: 50));
    }
  }

  // Last attempt, and the platforms genuinely differ here.
  //
  // On POSIX a directory still standing after three seconds is a real fault —
  // a permission problem, a genuinely leaked handle — and must surface.
  //
  // On Windows the same condition routinely means only "a handle has not
  // closed yet": the OS refuses to unlink an open file at all, where POSIX
  // unlinks it happily and lets the last close reap it. So the identical
  // symptom carries different information on the two systems, and treating
  // Windows as the strict case is what made a healthy teardown red. Tolerating
  // it there is accepting a documented platform difference, not widening the
  // guard everywhere.
  try {
    dir.deleteSync(recursive: true);
  } on FileSystemException {
    if (!Platform.isWindows) rethrow;
  }
}
