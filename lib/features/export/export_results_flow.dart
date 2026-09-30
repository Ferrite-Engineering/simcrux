// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';
import 'dart:typed_data';

import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:crux_telemetry/crux_telemetry.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/export/widgets/export_format_dialog.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/export/exporter_registry.dart';
import 'package:simcrux/services/result_store/in_memory_result_store.dart';
import 'package:simcrux/services/result_store/result_store_provider.dart';

/// Writes [contents] to [path]. Injectable so the flow's tests never touch the
/// real filesystem — the same seam shape as `CiRunner.fileWriter`.
typedef ExportFileWriter = Future<void> Function(String path, String contents);

/// Picks the destination path for a file named [suggestedName] with
/// [extension], or returns null if the user cancelled.
///
/// Injectable because the platform save panel cannot run in a widget test.
typedef ExportPathPicker =
    Future<String?> Function({
      required String suggestedName,
      required String extension,
    });

Future<void> _writeFile(String path, String contents) =>
    File(path).writeAsString(contents);

Future<String?> _pickPath({
  required String suggestedName,
  required String extension,
}) => FilePicker.saveFile(
  // file_picker 12 requires bytes and writes the file itself; pass empty so it
  // only returns the chosen path and the real content is written below. Same
  // shape as the RISC-V import and keymap export pickers.
  bytes: Uint8List(0),
  fileName: suggestedName,
  allowedExtensions: [extension],
  type: FileType.custom,
);

/// Runs the whole GUI export: choose a format, choose a destination, encode
/// through [ExporterRegistry], write, and report the outcome.
///
/// [tabContainer] is the active tab's `ProviderContainer`. The result store,
/// the active config and the dashboard rows are all per-tab overrides, so
/// reading them from the root container yields a different, empty instance.
///
/// The GUI door onto the exporters — see [showExportFormatDialog] for why.
Future<void> runExportResultsFlow({
  required BuildContext context,
  required ProviderContainer tabContainer,
  ExporterRegistry registry = const ExporterRegistry(),
  ExportFileWriter fileWriter = _writeFile,
  ExportPathPicker pathPicker = _pickPath,
}) async {
  final l10n = L10N.of(context);
  final store = tabContainer.read(resultStoreProvider);

  // The concrete in-memory store is what the dashboard runs against; the
  // interface exposes only streams, which is the wrong shape for a one-shot
  // "everything recorded so far" read. Same narrowing the Pro PR-annotation
  // dispatcher does on the same data.
  //
  // Re-checked here rather than trusted from the descriptor's `_requiresResults`
  // grey-out: the command palette drops disabled actions and the menu greys
  // them, but a user-assigned keyboard binding fires regardless.
  if (store is! InMemoryResultStore || store.results.isEmpty) {
    showCruxInfoSnack(context, l10n.exportEmpty);
    return;
  }

  final format = await showExportFormatDialog(context);
  if (format == null) return;

  final run = store.latestRun;
  final rows = allDashboardRows(
    run: run,
    config: tabContainer.read(activeConfigProvider),
  );
  final configPath = tabContainer.read(activeConfigProvider)?.projectFilePath;

  final String? path;
  try {
    path = await pathPicker(
      suggestedName: '${run.id}.${format.extension}',
      extension: format.extension,
    );
  } on Object {
    // A save panel that fails to open is a cancelled export, not an error to
    // report against a file the user never chose.
    return;
  }
  if (path == null) return;

  try {
    final encoded = registry
        .exporterFor(format)
        .encode(run: run, rows: rows, configPath: configPath);
    await fileWriter(path, encoded);
  } on Object catch (e) {
    if (!context.mounted) return;
    showCruxErrorSnack(context, l10n.exportFailure('$e'));
    return;
  }

  // After the write, so a failed export is not counted as one — the same rule
  // `CiRunner._writeExports` follows for the same event. The format id is the
  // only property: the path is user data and never leaves the machine.
  tabContainer
      .read(telemetryServiceProvider)
      .record(
        TelemetryEvent(
          'export.completed',
          properties: <String, Object?>{'format': format.id},
        ),
      );

  if (!context.mounted) return;
  showCruxInfoSnack(context, l10n.exportSuccess(path));
}
