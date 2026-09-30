// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/dashboard_row.dart';
import 'package:simcrux/domain/models/test_run.dart';
import 'package:simcrux/services/export/result_exporter.dart';

/// Encodes a [TestRun] + [DashboardRow] list as JUnit XML.
///
/// One `<testsuite>` per distinct suite name; one `<testcase>` per
/// row. Maps SimCrux's [TestStatus] onto JUnit's failure / error /
/// skipped child elements:
///
/// - `pass` / `vacuous` / `cover` → no child element (success).
/// - `fail` → `<failure type="fail" message="…"/>`.
/// - `timeout` → `<failure type="timeout" message="…"/>`.
/// - `cancelled` → `<error type="cancelled"/>`.
/// - `skipped` → `<skipped/>`.
/// - `unknown` → `<error type="unknown"/>` (treated as an
///   infrastructure failure so CI doesn't silently pass).
/// - `running` → never emitted; the exporter only reads completed
///   results.
///
/// JUnit consumers (Jenkins, GitHub Actions test-reporter, Bamboo)
/// all key off the `failure` / `error` / `skipped` distinction, so
/// the mapping is meaningful in downstream dashboards.
class JunitExporter implements ResultExporter {
  /// Const constructor.
  const JunitExporter();

  @override
  ExportFormat get format => ExportFormat.junit;

  @override
  String encode({
    required TestRun run,
    required List<DashboardRow> rows,
    String? configPath,
  }) {
    final bySuite = <String, List<DashboardRow>>{};
    for (final row in rows) {
      bySuite.putIfAbsent(row.suiteName, () => <DashboardRow>[]).add(row);
    }
    final buffer = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln(
        '<testsuites name="${_escape(configPath ?? 'simcrux')}" '
        'tests="${rows.length}" '
        'failures="${rows.where((r) => r.result.status == TestStatus.fail || r.result.status == TestStatus.timeout).length}" '
        'errors="${rows.where((r) => r.result.status == TestStatus.cancelled || r.result.status == TestStatus.unknown).length}" '
        'skipped="${rows.where((r) => r.result.status == TestStatus.skipped).length}" '
        'time="${_seconds(_totalRuntime(rows))}">',
      );
    bySuite.forEach((suiteName, suiteRows) {
      buffer.writeln(
        '  <testsuite name="${_escape(suiteName)}" '
        'tests="${suiteRows.length}" '
        'failures="${suiteRows.where((r) => r.result.status == TestStatus.fail || r.result.status == TestStatus.timeout).length}" '
        'errors="${suiteRows.where((r) => r.result.status == TestStatus.cancelled || r.result.status == TestStatus.unknown).length}" '
        'skipped="${suiteRows.where((r) => r.result.status == TestStatus.skipped).length}" '
        'time="${_seconds(_totalRuntime(suiteRows))}">',
      );
      for (final row in suiteRows) {
        buffer.writeln(_encodeCase(row));
      }
      buffer.writeln('  </testsuite>');
    });
    buffer.writeln('</testsuites>');
    return buffer.toString();
  }

  String _encodeCase(DashboardRow row) {
    final result = row.result;
    final time = _seconds(result.runtime);
    final classname = _escape(row.suiteName);
    final name = _escape(row.testName);
    final base =
        '    <testcase classname="$classname" name="$name" time="$time"';
    final inner = StringBuffer();
    switch (result.status) {
      case TestStatus.pass:
      case TestStatus.vacuous:
      case TestStatus.cover:
        // Empty body — JUnit treats it as a pass.
        return '$base/>';
      case TestStatus.fail:
        inner.writeln(
          '      <failure type="fail" message="${_escape(result.failureMessage ?? 'failed')}"/>',
        );
      case TestStatus.timeout:
        inner.writeln(
          '      <failure type="timeout" message="${_escape(result.failureMessage ?? 'timeout')}"/>',
        );
      case TestStatus.cancelled:
        inner.writeln('      <error type="cancelled"/>');
      case TestStatus.skipped:
        inner.writeln('      <skipped/>');
      case TestStatus.unknown:
        inner.writeln(
          '      <error type="unknown" message="${_escape(result.failureMessage ?? 'unknown')}"/>',
        );
      case TestStatus.running:
        // Defensive: incomplete results should never reach an
        // exporter, but emit a skipped element rather than crashing.
        inner.writeln('      <skipped/>');
    }
    return '$base>\n$inner    </testcase>';
  }

  static Duration _totalRuntime(Iterable<DashboardRow> rows) {
    var sum = Duration.zero;
    for (final row in rows) {
      sum += row.result.runtime;
    }
    return sum;
  }

  static String _seconds(Duration d) {
    final ms = d.inMilliseconds;
    return (ms / 1000.0).toStringAsFixed(3);
  }

  static String _escape(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}
