// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/dashboard_row.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_run.dart';
import 'package:simcrux/services/export/html_exporter.dart';

void main() {
  test(
    'HtmlExporter emits a self-contained HTML document with embedded data',
    () {
      const exporter = HtmlExporter();
      final html = exporter.encode(
        run: TestRun(
          id: 'r1',
          startedAt: DateTime.utc(2026, 5, 23, 17),
          finishedAt: DateTime.utc(2026, 5, 23, 17, 0, 42),
          testIds: const ['axi/burst'],
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
        ],
        configPath: '/p/simcrux.yaml',
      );
      expect(html, startsWith('<!DOCTYPE html>'));
      expect(html, contains('SimCrux regression'));
      expect(html, contains('id="data"'));
      expect(html, contains('"id":"axi/burst"'));
      expect(html, contains('"status":"pass"'));
      expect(html, contains('chip status-pass'));
      // No external CDN / framework references.
      expect(html, isNot(contains('http://')));
      expect(html, isNot(contains('https://')));
    },
  );
}
