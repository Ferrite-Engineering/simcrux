// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/pass_fail_detector.dart';
import 'package:simcrux/domain/models/pass_fail_config.dart';

/// Pass if and only if the simulator process exited with code 0.
///
/// Honors only [ExitCodePassFailConfig]. Behavior for other config
/// variants:
///
/// - A null exit code (process did not produce one — e.g. cancelled
///   before completion, or the driver does not surface exit codes)
///   classifies as [TestStatus.unknown].
/// - Negative exit codes from a [kill] (e.g. SIGTERM / SIGKILL during
///   timeout escalation) classify as [TestStatus.fail] — the caller
///   (the scheduler) is responsible for downgrading "timeout-killed
///   processes" to [TestStatus.timeout] before reaching this detector;
///   we only see the post-kill exit code here.
///
/// This is the SimCrux baseline detector — every `TestSpec` defaults
/// to `ExitCodePassFailConfig()` if the user omits a `pass_fail:` block.
class ExitCodeDetector implements PassFailDetector {
  /// Const constructor.
  const ExitCodeDetector();

  @override
  TestStatus detect({
    required String stdout,
    required String stderr,
    required int? exitCode,
    required Duration runtime,
    required PassFailConfig config,
  }) {
    if (config is! ExitCodePassFailConfig) {
      return TestStatus.unknown;
    }
    if (exitCode == null) return TestStatus.unknown;
    if (exitCode == 0) return TestStatus.pass;
    return TestStatus.fail;
  }
}
