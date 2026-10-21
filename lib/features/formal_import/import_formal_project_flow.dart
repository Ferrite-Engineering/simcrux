// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';
import 'dart:typed_data';

import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:crux_telemetry/crux_telemetry.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/models/formal_import_result.dart';
import 'package:simcrux/features/formal_import/widgets/import_formal_project_dialog.dart';
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';
import 'package:simcrux/features/workspace/providers/recent_lists.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/import/sby_project_importer.dart';
import 'package:simcrux/services/telemetry/project_opened_event.dart';
import 'package:simcrux/services/telemetry/telemetry_event_catalog.dart';

/// Writes [contents] to [path]. Injected by tests.
typedef FormalImportWriter =
    Future<void> Function(String path, String contents);

/// File > Import Formal Project…: opens the dialog, and on Import reads the
/// job file, writes the project file, records the import and opens the file
/// as a workspace tab.
///
/// [root] is the container the handler's `ref` reads from: the dialog and
/// the write outlive the widget that started them.
Future<void> runImportFormalProject(
  BuildContext context,
  ProviderContainer root, {
  SbyProjectImporter? importer,
  FormalImportWriter? write,
  Future<String?> Function()? pickJobFile,
  Future<String?> Function(String suggestedPath)? pickProjectFile,
}) async {
  final sby = importer ?? SbyProjectImporter();
  final writeFile =
      write ??
      (String path, String contents) => File(path).writeAsString(contents);
  final l10n = L10N.of(context);

  Future<String?> commit(ImportFormalProjectRequest request) async {
    final FormalImportResult result;
    try {
      result = sby.importJobs(
        path: request.sbyPath,
        outputDirectory: p.dirname(request.outputPath),
        tasks: request.tasks,
      );
      await writeFile(request.outputPath, result.simcruxYaml);
    } on FormalImportException catch (e) {
      return l10n.importFormalFailed(e.message);
    } on Object catch (e) {
      return l10n.importFormalFailed('$e');
    }
    // After the write: an import that failed opened no project, and the
    // counters answer "is import the front door", not "was it reached".
    root.read(telemetryServiceProvider)
      ..record(projectOpenedEvent('formal'))
      ..record(
        TelemetryEvent(
          'formal.import.completed',
          properties: <String, Object?>{
            'kind': 'sby',
            'tasks': telemetryCount(result.testCount),
          },
        ),
      );
    await root
        .read(workspaceProvider.notifier)
        .openTab(
          displayName: p.basename(request.outputPath),
          payload: SimcruxTabPayload(configPath: request.outputPath),
        );
    root.read(recentProjects.provider.notifier).markOpened(request.outputPath);
    if (context.mounted) {
      if (result.warnings.isEmpty) {
        showCruxInfoSnack(
          context,
          l10n.importFormalSuccess(result.testCount, request.outputPath),
        );
      } else {
        // Not a failure (the file was written and opened), but a job file
        // that turns its assertions off must not import silently.
        showCruxErrorSnack(
          context,
          l10n.importFormalSuccessWithWarnings(
            result.testCount,
            request.outputPath,
          ),
        );
      }
    }
    return null;
  }

  await showImportFormalProjectDialog(
    context,
    onImport: commit,
    readJobFile: sby.readScript,
    pickJobFile: pickJobFile ?? _pickJobFile,
    pickProjectFile: pickProjectFile ?? _pickProjectFile,
  );
}

Future<String?> _pickJobFile() async {
  try {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['sby'],
    );
    if (result == null || result.files.isEmpty) return null;
    return result.files.single.path;
  } on Object {
    return null;
  }
}

Future<String?> _pickProjectFile(String suggestedPath) async {
  try {
    return await FilePicker.saveFile(
      // file_picker requires bytes and writes the file itself; pass empty so
      // it only returns the chosen path, and the real content is written by
      // the import. Same shape as the RISC-V import's save picker.
      bytes: Uint8List(0),
      fileName: p.basename(suggestedPath),
      initialDirectory: p.dirname(suggestedPath),
      allowedExtensions: const <String>['yaml', 'yml'],
      type: FileType.custom,
    );
  } on Object {
    return null;
  }
}
