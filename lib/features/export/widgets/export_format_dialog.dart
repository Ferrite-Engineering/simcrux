// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/export/result_exporter.dart';

/// Widget key of the dialog frame, so tests and the modal guard can find it.
const Key kExportFormatDialogKey = Key('exportFormatDialog');

/// Widget key of the confirm button.
const Key kExportFormatDialogExportKey = Key('exportFormatDialogExport');

/// Asks the user which of the four formats to export, returning the chosen
/// [ExportFormat] or null if they cancelled.
///
/// `ResultExporter` "drives both the in-app Export dialog and the
/// `simcrux --ci` CLI"; this is the in-app half. Without it
/// `ExporterRegistry` has only CLI consumers. Nothing here is new
/// capability; it is the door onto the existing exporters.
///
/// Format choice only. The destination comes from the platform save panel
/// afterwards, seeded with [ExportFormat.extension] — which is precisely what
/// that field's doc comment says it exists for.
Future<ExportFormat?> showExportFormatDialog(BuildContext context) {
  return showDialog<ExportFormat>(
    context: context,
    builder: (dialogContext) => const _ExportFormatDialog(),
  );
}

class _ExportFormatDialog extends StatefulWidget {
  const _ExportFormatDialog();

  @override
  State<_ExportFormatDialog> createState() => _ExportFormatDialogState();
}

class _ExportFormatDialogState extends State<_ExportFormatDialog> {
  // JUnit leads the enum and is the format a CI pipeline actually consumes,
  // which is the common reason to reach for this dialog at all.
  ExportFormat _format = ExportFormat.junit;

  @override
  Widget build(BuildContext context) {
    final l10n = L10N.of(context);
    return AlertDialog(
      key: kExportFormatDialogKey,
      title: Text(l10n.exportDialogTitle),
      content: RadioGroup<ExportFormat>(
        groupValue: _format,
        onChanged: (v) => setState(() => _format = v ?? _format),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final format in ExportFormat.values)
              RadioListTile<ExportFormat>(
                key: Key('exportFormat_${format.id}'),
                value: format,
                title: Text(_formatLabel(l10n, format)),
                contentPadding: EdgeInsets.zero,
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.exportActionCancel),
        ),
        FilledButton(
          key: kExportFormatDialogExportKey,
          onPressed: () => Navigator.of(context).pop(_format),
          child: Text(l10n.exportActionExport),
        ),
      ],
    );
  }
}

/// The localized display name for [format].
///
/// Exhaustive with no default, so a fifth format fails to compile until it has
/// a label rather than shipping as a blank radio row.
String _formatLabel(L10N l10n, ExportFormat format) => switch (format) {
  ExportFormat.junit => l10n.exportFormatJunit,
  ExportFormat.json => l10n.exportFormatJson,
  ExportFormat.csv => l10n.exportFormatCsv,
  ExportFormat.html => l10n.exportFormatHtml,
};
