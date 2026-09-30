// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:simcrux/domain/models/dashboard_row.dart';
import 'package:simcrux/domain/models/test_run.dart';
import 'package:simcrux/services/export/result_exporter.dart';

/// CSV exporter — one row per test, columns aligned with the
/// dashboard table:
///
/// `test_id,suite,test,simulator,status,runtime_ms,started_at,exit_code,failure_message`
///
/// Excel and Numbers both parse the RFC 4180 dialect this exporter
/// produces (CRLF line endings, double-quoted fields containing
/// commas / quotes / newlines, double-quote escaping via doubling).
class CsvExporter implements ResultExporter {
  /// Const constructor.
  const CsvExporter();

  @override
  ExportFormat get format => ExportFormat.csv;

  @override
  String encode({
    required TestRun run,
    required List<DashboardRow> rows,
    String? configPath,
  }) {
    final buffer = StringBuffer()
      ..write(
        _row(<String>[
          'test_id',
          'suite',
          'test',
          'simulator',
          'status',
          'runtime_ms',
          'started_at',
          'exit_code',
          'failure_message',
        ]),
      );
    for (final row in rows) {
      buffer.write(
        _row(<String>[
          row.testId,
          row.suiteName,
          row.testName,
          row.simulatorId,
          row.result.status.name,
          row.result.runtime.inMilliseconds.toString(),
          row.result.startedAt.toUtc().toIso8601String(),
          row.result.exitCode?.toString() ?? '',
          row.result.failureMessage ?? '',
        ]),
      );
    }
    return buffer.toString();
  }

  static String _row(List<String> columns) {
    final encoded = columns.map(_escape).join(',');
    return '$encoded\r\n';
  }

  static String _escape(String value) {
    if (value.contains(',') ||
        value.contains('"') ||
        value.contains('\n') ||
        value.contains('\r')) {
      final doubled = value.replaceAll('"', '""');
      return '"$doubled"';
    }
    return value;
  }
}
