// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:simcrux/services/export/csv_exporter.dart';
import 'package:simcrux/services/export/html_exporter.dart';
import 'package:simcrux/services/export/json_exporter.dart';
import 'package:simcrux/services/export/junit_exporter.dart';
import 'package:simcrux/services/export/result_exporter.dart';

/// Maps an [ExportFormat] to its [ResultExporter] implementation.
///
/// Const + stateless — every format ships the same way the
/// pass/fail registry ships its four detectors. Pro tier may register
/// additional formats (e.g. an org-internal CSV dialect) via a
/// Riverpod override on the registry.
class ExporterRegistry {
  /// Const constructor — registry is stateless.
  const ExporterRegistry({
    this.junit = const JunitExporter(),
    this.json = const JsonExporter(),
    this.csv = const CsvExporter(),
    this.html = const HtmlExporter(),
  });

  /// JUnit XML exporter.
  final ResultExporter junit;

  /// JSON exporter.
  final ResultExporter json;

  /// CSV exporter.
  final ResultExporter csv;

  /// HTML self-contained-site exporter.
  final ResultExporter html;

  /// Look up the exporter for [format]. Always returns non-null —
  /// every format has a default implementation.
  ResultExporter exporterFor(ExportFormat format) {
    switch (format) {
      case ExportFormat.junit:
        return junit;
      case ExportFormat.json:
        return json;
      case ExportFormat.csv:
        return csv;
      case ExportFormat.html:
        return html;
    }
  }
}
