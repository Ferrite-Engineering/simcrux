// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_run.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/services/flow/flow_metric_keys.dart';

TestResult _result(String id, {Map<String, String> metrics = const {}}) =>
    TestResult(
      testId: id,
      runId: 'r',
      status: TestStatus.pass,
      startedAt: DateTime.utc(2026),
      finishedAt: DateTime.utc(2026),
      metrics: metrics,
    );

/// A gate-level row's test is not one of the project's, so the table cannot
/// look its simulator up; the row shows the one the result records, not
/// "unknown" beside a Details panel that names Icarus.
void main() {
  test('a gate-level row shows the simulator its result records', () {
    final rows = allDashboardRows(
      run: TestRun(
        id: 'r',
        startedAt: DateTime.utc(2026),
        testIds: const ['gls/rtl/smoke', 'rtl/other'],
        results: [
          _result(
            'gls/rtl/smoke',
            metrics: const {GlsMetricKeys.simulator: 'icarus'},
          ),
          _result('rtl/other'),
        ],
      ),
      config: null,
    );
    final byId = {for (final r in rows) r.testId: r.simulatorId};
    expect(byId['gls/rtl/smoke'], 'icarus');
    expect(byId['rtl/other'], 'unknown');
  });
}
