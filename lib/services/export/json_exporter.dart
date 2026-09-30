// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

import 'package:simcrux/domain/models/dashboard_row.dart';
import 'package:simcrux/domain/models/test_run.dart';
import 'package:simcrux/services/export/result_exporter.dart';

/// JSON exporter producing the canonical "simcrux run" document.
///
/// Schema (`version: 1`):
///
/// ```json
/// {
///   "version": 1,
///   "config_path": "/abs/simcrux.yaml",
///   "run": {
///     "id": "1716321600000",
///     "started_at": "2026-05-23T17:00:00.000Z",
///     "finished_at": "2026-05-23T17:00:42.000Z",
///     "total": 12
///   },
///   "tests": [
///     {
///       "id": "axi/burst",
///       "name": "burst",
///       "suite": "axi",
///       "simulator": "verilator",
///       "status": "pass",
///       "runtime_ms": 1234,
///       "started_at": "…", "finished_at": "…",
///       "exit_code": 0,
///       "waveform_path": "…",
///       "stdout_path": "…",
///       "stderr_path": "…",
///       "failure_message": null
///     }
///   ]
/// }
/// ```
///
/// `version` is the schema version the exporter writes (NOT the
/// SimCrux app version) so downstream tools can branch on it.
class JsonExporter implements ResultExporter {
  /// Const constructor.
  const JsonExporter();

  /// Stable schema version. Bump only on incompatible changes.
  static const int schemaVersion = 1;

  @override
  ExportFormat get format => ExportFormat.json;

  @override
  String encode({
    required TestRun run,
    required List<DashboardRow> rows,
    String? configPath,
  }) {
    final doc = <String, Object?>{
      'version': schemaVersion,
      'config_path': configPath,
      'run': <String, Object?>{
        'id': run.id,
        'started_at': run.startedAt.toUtc().toIso8601String(),
        'finished_at': run.finishedAt?.toUtc().toIso8601String(),
        'total': rows.length,
      },
      'tests': [
        for (final row in rows)
          <String, Object?>{
            'id': row.testId,
            'name': row.testName,
            'suite': row.suiteName,
            'simulator': row.simulatorId,
            'status': row.result.status.name,
            'runtime_ms': row.result.runtime.inMilliseconds,
            'started_at': row.result.startedAt.toUtc().toIso8601String(),
            'finished_at': row.result.finishedAt.toUtc().toIso8601String(),
            'exit_code': row.result.exitCode,
            'waveform_path': row.result.waveformPath,
            'stdout_path': row.result.stdoutPath,
            'stderr_path': row.result.stderrPath,
            'failure_message': row.result.failureMessage,
            if (row.result.metrics.isNotEmpty)
              'metrics': Map<String, String>.from(row.result.metrics),
          },
      ],
    };
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert(doc);
  }
}
