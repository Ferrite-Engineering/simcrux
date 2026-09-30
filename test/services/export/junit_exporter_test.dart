// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/dashboard_row.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_run.dart';
import 'package:simcrux/services/export/junit_exporter.dart';

DashboardRow _row({
  required String suite,
  required String name,
  required TestStatus status,
  Duration runtime = const Duration(milliseconds: 1234),
  int? exitCode = 0,
  String? failureMessage,
}) {
  final id = '$suite/$name';
  return DashboardRow(
    result: TestResult(
      testId: id,
      runId: 'r1',
      status: status,
      startedAt: DateTime.utc(2026, 5, 23, 17),
      finishedAt: DateTime.utc(2026, 5, 23, 17).add(runtime),
      exitCode: exitCode,
      failureMessage: failureMessage,
    ),
    suiteName: suite,
    simulatorId: 'icarus',
    testName: name,
  );
}

void main() {
  test('JunitExporter renders one testsuite per distinct suite', () {
    const exporter = JunitExporter();
    final xml = exporter.encode(
      run: TestRun(
        id: 'r1',
        startedAt: DateTime.utc(2026, 5, 23, 17),
        testIds: const ['axi/burst', 'axi/wrap', 'uart/rx'],
      ),
      rows: [
        _row(suite: 'axi', name: 'burst', status: TestStatus.pass),
        _row(
          suite: 'axi',
          name: 'wrap',
          status: TestStatus.fail,
          failureMessage: 'mismatch at t=42',
        ),
        _row(suite: 'uart', name: 'rx', status: TestStatus.skipped),
      ],
      configPath: '/p/simcrux.yaml',
    );
    expect(xml, contains('<testsuites name="/p/simcrux.yaml"'));
    expect(xml, contains('<testsuite name="axi"'));
    expect(xml, contains('<testsuite name="uart"'));
    expect(xml, contains('<testcase classname="axi" name="burst"'));
    expect(xml, contains('<failure type="fail"'));
    expect(xml, contains('mismatch at t=42'));
    expect(xml, contains('<skipped/>'));
    expect(xml, contains('failures="1"'));
    expect(xml, contains('skipped="1"'));
  });

  test('JunitExporter escapes special XML characters in messages', () {
    const exporter = JunitExporter();
    final xml = exporter.encode(
      run: TestRun(
        id: 'r1',
        startedAt: DateTime.utc(2026, 5, 23, 17),
        testIds: const ['suite/<bad>'],
      ),
      rows: [
        _row(
          suite: '<bad>',
          name: '"name"',
          status: TestStatus.fail,
          failureMessage: 'a & b < c',
        ),
      ],
    );
    expect(xml, contains('classname="&lt;bad&gt;"'));
    expect(xml, contains('name="&quot;name&quot;"'));
    expect(xml, contains('message="a &amp; b &lt; c"'));
  });

  test('JunitExporter maps timeout to failure, cancelled to error', () {
    const exporter = JunitExporter();
    final xml = exporter.encode(
      run: TestRun(
        id: 'r1',
        startedAt: DateTime.utc(2026, 5, 23, 17),
        testIds: const ['s/t1', 's/t2'],
      ),
      rows: [
        _row(suite: 's', name: 't1', status: TestStatus.timeout),
        _row(suite: 's', name: 't2', status: TestStatus.cancelled),
      ],
    );
    expect(xml, contains('<failure type="timeout"'));
    expect(xml, contains('<error type="cancelled"'));
  });
}
