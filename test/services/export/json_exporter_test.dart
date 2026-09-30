// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/dashboard_row.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_run.dart';
import 'package:simcrux/services/export/json_exporter.dart';

void main() {
  test('JsonExporter produces the canonical schema', () {
    const exporter = JsonExporter();
    final raw = exporter.encode(
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
            waveformPath: '/tmp/foo.fst',
          ),
          suiteName: 'axi',
          simulatorId: 'verilator',
          testName: 'burst',
        ),
      ],
      configPath: '/p/simcrux.yaml',
    );
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    expect(decoded['version'], JsonExporter.schemaVersion);
    expect(decoded['config_path'], '/p/simcrux.yaml');
    final run = decoded['run'] as Map<String, dynamic>;
    expect(run['id'], 'r1');
    expect(run['total'], 1);
    final tests = decoded['tests'] as List;
    expect(tests, hasLength(1));
    final test0 = tests.first as Map<String, dynamic>;
    expect(test0['id'], 'axi/burst');
    expect(test0['status'], 'pass');
    expect(test0['runtime_ms'], 1000);
    expect(test0['waveform_path'], '/tmp/foo.fst');
  });
}
