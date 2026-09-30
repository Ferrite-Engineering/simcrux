// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/dashboard_row.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_run.dart';
import 'package:simcrux/services/export/csv_exporter.dart';

void main() {
  test(
    'CsvExporter writes header row and quotes fields with commas / quotes',
    () {
      const exporter = CsvExporter();
      final csv = exporter.encode(
        run: TestRun(
          id: 'r1',
          startedAt: DateTime.utc(2026, 5, 23, 17),
          testIds: const ['axi/burst', 'axi/wrap'],
        ),
        rows: [
          DashboardRow(
            result: TestResult(
              testId: 'axi/burst',
              runId: 'r1',
              status: TestStatus.pass,
              startedAt: DateTime.utc(2026, 5, 23, 17),
              finishedAt: DateTime.utc(2026, 5, 23, 17, 0, 1),
              exitCode: 0,
            ),
            suiteName: 'axi',
            simulatorId: 'verilator',
            testName: 'burst',
          ),
          DashboardRow(
            result: TestResult(
              testId: 'axi/wrap',
              runId: 'r1',
              status: TestStatus.fail,
              startedAt: DateTime.utc(2026, 5, 23, 17),
              finishedAt: DateTime.utc(2026, 5, 23, 17, 0, 1),
              exitCode: 1,
              failureMessage: 'expected "x", got "y"',
            ),
            suiteName: 'axi,things',
            simulatorId: 'verilator',
            testName: 'wrap',
          ),
        ],
      );
      final lines = csv.split('\r\n');
      expect(lines.first, startsWith('test_id,suite,test,'));
      // The fail-message has a comma + quotes, the suite has a comma —
      // both fields must be properly quoted.
      expect(lines[2], contains('"axi,things"'));
      expect(lines[2], contains('"expected ""x"", got ""y"""'));
    },
  );
}
