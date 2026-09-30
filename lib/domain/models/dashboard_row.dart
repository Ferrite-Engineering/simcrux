// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_spec.dart';

/// One row in the dashboard's results table.
///
/// Joins a [TestResult] (status / runtime / exit code) with its
/// originating [TestSpec] (suite name / simulator id), which the
/// `TestResult` does not carry on its own. The dashboard builds
/// rows from the active `ResultStore.currentRun` results and the
/// `RegressionConfig.suites` map, then filters/sorts them in a
/// derived provider.
@immutable
class DashboardRow {
  /// Creates a [DashboardRow].
  const DashboardRow({
    required this.result,
    required this.suiteName,
    required this.simulatorId,
    required this.testName,
  });

  /// The classified, finalized result for this test.
  final TestResult result;

  /// Suite this test belongs to (from [TestSpec.suiteName]).
  final String suiteName;

  /// Simulator the test ran on (from [TestSpec.simulatorId]).
  final String simulatorId;

  /// User-supplied test name (from [TestSpec.name]) — the
  /// human-readable id segment displayed in the table.
  final String testName;

  /// Convenience: the stable test id from the underlying result.
  String get testId => result.testId;
}
