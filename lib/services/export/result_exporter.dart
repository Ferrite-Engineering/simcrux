// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:simcrux/domain/models/dashboard_row.dart';
import 'package:simcrux/domain/models/test_run.dart';

/// Discriminator for the four export formats. Drives both the
/// in-app Export dialog and the `simcrux --ci` CLI's
/// `--export <format>=<path>` flag.
enum ExportFormat {
  /// Standard JUnit XML — one `<testsuite>` per [Suite] and one
  /// `<testcase>` per [DashboardRow]. Drop-in for Jenkins / Bamboo /
  /// GitHub Actions test reporters.
  junit('junit', 'xml'),

  /// Structured JSON dump matching the canonical [TestRunResult]
  /// model. The format is stable across SimCrux releases (the schema
  /// version is embedded in the document root).
  json('json', 'json'),

  /// One row per [DashboardRow] with columns matching the dashboard
  /// table. Useful for ad-hoc spreadsheet inspection.
  csv('csv', 'csv'),

  /// Static-site dashboard — a single self-contained HTML file with
  /// sortable table, filter chips, status colors, embedded log
  /// previews. No JS framework required.
  html('html', 'html');

  const ExportFormat(this.id, this.extension);

  /// Stable id used in CLI flags and serialized session files.
  final String id;

  /// File extension to suggest on the file picker.
  final String extension;

  /// Look up a format by its [id], or null when the id is unknown.
  static ExportFormat? fromId(String id) {
    for (final format in ExportFormat.values) {
      if (format.id == id) return format;
    }
    return null;
  }
}

/// One-shot exporter that consumes the active dashboard rows + the
/// owning [TestRun] and returns the format-specific bytes.
///
/// Implementations are stateless (`const` constructors) so the
/// caller (Settings → Export, CLI --export) can swap them without
/// rebuilding application state.
abstract class ResultExporter {
  /// Const default.
  const ResultExporter();

  /// The format this exporter produces.
  ExportFormat get format;

  /// Encode the run + rows into the exporter's target format.
  String encode({
    required TestRun run,
    required List<DashboardRow> rows,
    String? configPath,
  });
}
