// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/pass_fail_detector.dart';
import 'package:simcrux/domain/models/pass_fail_config.dart';
import 'package:simcrux/services/pass_fail_detector/uvm_report_parser.dart';

/// Pass/fail classifier for UVM testbenches.
///
/// Honors [UvmReportPassFailConfig]. Parses the simulator's stdout +
/// stderr through [parseUvmReport] and applies the configured
/// thresholds:
///
/// - `UVM_FATAL >= fatalThreshold` ⇒ [TestStatus.fail]
/// - `UVM_ERROR >= errorThreshold` ⇒ [TestStatus.fail]
/// - `warningThreshold != null && UVM_WARNING >= warningThreshold` ⇒
///   [TestStatus.fail]
/// - Otherwise, if any UVM signal was seen, [TestStatus.pass].
/// - If no UVM signal at all (no summary, no per-message lines),
///   [TestStatus.unknown] so the composite detector / scheduler can
///   fall back to the exit-code default.
///
/// Threshold semantics:
/// - A threshold of `0` disables the check.
/// - A threshold of `1` (the default for fatals and errors) means
///   "any at all" — matches commercial UVM-aware regression tools.
///
/// Composable through [CompositePassFailConfig]: a common pattern is
/// `all_of: [exit_code, uvm_report]` to require both a clean exit and
/// a clean UVM report; or `any_of: [string_match, uvm_report]` to
/// pass when either the testbench's own banner OR the UVM summary
/// reports success.
///
/// The detector does **not** mutate or surface the parsed counts on
/// its own — drivers that want the counters on
/// [TestResult.metrics] should call [parseUvmReport] themselves and
/// emit the values via [TestExecutionFinished.metrics]. Keeping the
/// detector pure-classifier matches every other detector in the
/// registry.
class UvmReportDetector implements PassFailDetector {
  /// Const constructor.
  const UvmReportDetector();

  @override
  TestStatus detect({
    required String stdout,
    required String stderr,
    required int? exitCode,
    required Duration runtime,
    required PassFailConfig config,
  }) {
    if (config is! UvmReportPassFailConfig) return TestStatus.unknown;

    final counts = parseUvmReport('$stdout\n$stderr');
    if (!counts.hasAnySignal) return TestStatus.unknown;

    if (config.fatalThreshold > 0 && counts.fatal >= config.fatalThreshold) {
      return TestStatus.fail;
    }
    if (config.errorThreshold > 0 && counts.error >= config.errorThreshold) {
      return TestStatus.fail;
    }
    final wt = config.warningThreshold;
    if (wt != null && wt > 0 && counts.warning >= wt) {
      return TestStatus.fail;
    }
    return TestStatus.pass;
  }
}
