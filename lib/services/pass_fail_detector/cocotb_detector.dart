// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/pass_fail_detector.dart';
import 'package:simcrux/domain/models/pass_fail_config.dart';
import 'package:simcrux/services/simulator/cocotb_driver.dart';

/// Pass/fail classifier for Cocotb runs, from the end-of-run summary line.
///
/// Honors [CocotbPassFailConfig]. Reuses [parseCocotbSummary] rather than
/// re-implementing the aggregate, so the two agree by construction and a
/// change to Cocotb's format is absorbed in one place.
///
/// Rules, in order:
///
/// - No summary line at all ⇒ [TestStatus.unknown], so the composite detector
///   or the scheduler falls back to the exit-code default. Cocotb prints the
///   aggregate unconditionally, so its absence means the run died before the
///   regression finished — a verdict this detector has no business inventing.
/// - `TESTS=0` ⇒ [TestStatus.fail], unless `allowNoTests`. A run that executed
///   nothing is not a pass.
/// - `FAIL>0` ⇒ [TestStatus.fail].
/// - Anything unaccounted for — `PASS + SKIP + XFAIL` short of `TESTS` ⇒
///   [TestStatus.fail]. A case that neither passed, skipped nor xfailed did
///   something the summary has no word for, and guessing in its favour is how
///   a crashed case reads as green.
/// - Otherwise [TestStatus.pass].
///
/// **XFAIL counts as expected.** Cocotb 2.1 reports `@cocotb.xfail` tests as
/// `XFAIL` only under `COCOTB_PREVIEW=xfail_in_results`; without it they are
/// reported as `PASS`, exactly as 2.0 did. Both shapes therefore classify the
/// same way here, so enabling the preview flag does not change a verdict —
/// which it would if XFAIL were treated as a residual.
///
/// Composable through [CompositePassFailConfig]: `all_of: [exit_code, cocotb]`
/// requires both a clean exit and a clean summary, which is the useful
/// combination when a Makefile can swallow a non-zero status.
///
/// Like every other detector this is a pure classifier and surfaces no
/// counters; the Cocotb driver already emits `cocotb.*` metrics, and from
/// `results.xml` where it can, which carries more than the summary line does.
class CocotbDetector implements PassFailDetector {
  /// Const constructor.
  const CocotbDetector();

  @override
  TestStatus detect({
    required String stdout,
    required String stderr,
    required int? exitCode,
    required Duration runtime,
    required PassFailConfig config,
  }) {
    final cfg = config is CocotbPassFailConfig
        ? config
        : const CocotbPassFailConfig();

    final summary = parseCocotbSummary('$stdout\n$stderr');
    if (summary == null) return TestStatus.unknown;

    if (summary.tests == 0) {
      return cfg.allowNoTests ? TestStatus.pass : TestStatus.fail;
    }
    if (summary.fails > 0) return TestStatus.fail;
    if (summary.expectedCompletions != summary.tests) return TestStatus.fail;
    return TestStatus.pass;
  }
}
