// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/pass_fail_detector.dart';
import 'package:simcrux/domain/models/pass_fail_config.dart';

/// Substring-based pass/fail classifier.
///
/// Honors [StringMatchPassFailConfig]. Both `passString` and
/// `failString` may be supplied independently:
///
/// - If `failString` is non-null and is present in either stdout or
///   stderr, the test is classified as [TestStatus.fail]. Fail strings
///   always win — a test that prints the expected pass message **and**
///   the forbidden fail message is still a failure (matches every
///   commercial regression manager's convention; once the testbench
///   has reported an error, the run is broken regardless of any
///   later "TEST PASSED" line).
/// - Otherwise, if `passString` is non-null and is present in either
///   stdout or stderr, the test is classified as [TestStatus.pass].
/// - Otherwise, [TestStatus.fail] when `passString` was required but
///   not seen; [TestStatus.unknown] when neither `passString` nor
///   `failString` matched but the config provided only a `failString`
///   (i.e. "the absence of a fail string is not by itself a positive
///   signal — the scheduler should fall back to exit code").
///
/// The matcher does **not** consider the simulator's exit code —
/// pair this detector with `ExitCodeDetector` via
/// [CompositePassFailConfig] (`all_of`) when both signals are
/// required to agree.
class StringMatchDetector implements PassFailDetector {
  /// Const constructor.
  const StringMatchDetector();

  @override
  TestStatus detect({
    required String stdout,
    required String stderr,
    required int? exitCode,
    required Duration runtime,
    required PassFailConfig config,
  }) {
    if (config is! StringMatchPassFailConfig) return TestStatus.unknown;

    final failString = config.failString;
    if (failString != null && failString.isNotEmpty) {
      if (stdout.contains(failString) || stderr.contains(failString)) {
        return TestStatus.fail;
      }
    }

    final passString = config.passString;
    if (passString != null && passString.isNotEmpty) {
      if (stdout.contains(passString) || stderr.contains(passString)) {
        return TestStatus.pass;
      }
      // Pass-string was required but never seen — that is a failure.
      return TestStatus.fail;
    }

    // Only `failString` was configured and it didn't appear. We have no
    // positive signal of our own; let the scheduler/upstream fall
    // through to its exit-code default by reporting unknown.
    return TestStatus.unknown;
  }
}
