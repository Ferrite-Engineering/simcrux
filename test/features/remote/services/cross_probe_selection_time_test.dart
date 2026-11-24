// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_cxp/crux_cxp.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/dashboard_row.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/features/remote/services/cross_probe_selection.dart';

/// A time (CXP §9.3.3) survives SimCrux forwarding a test row as a
/// cross-probe selection.
void main() {
  final row = DashboardRow(
    suiteName: 'cpu',
    testName: 'alu_add',
    simulatorId: 'verilator',
    result: TestResult(
      testId: 'cpu/alu_add',
      runId: 'r',
      status: TestStatus.fail,
      startedAt: DateTime.utc(2026, 10),
      finishedAt: DateTime.utc(2026, 10),
      waveformPath: '/work/alu_add.vcd',
    ),
  );

  test('the selection carries the time unchanged', () {
    final selection = crossProbeSelectionForRow(
      row,
      time: CxpTime.parse('41250ps'),
    );

    expect(selection.time?.toJson(), '41250ps');
  });

  test('a bare tick time stays a tick time', () {
    final selection = crossProbeSelectionForRow(row, time: CxpTime.ticks(42));

    expect(selection.time?.isTicks, isTrue);
    expect(selection.time?.toJson(), '42');
  });

  test('without a time none is sent', () {
    expect(crossProbeSelectionForRow(row).time, isNull);
  });
}
