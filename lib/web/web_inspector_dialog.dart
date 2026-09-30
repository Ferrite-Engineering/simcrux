// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/web/web_results_document.dart';
import 'package:simcrux/web/web_status_chip.dart';

/// Read-only inspector dialog shown when a row is clicked in the web
/// dashboard.
///
/// Mirrors the desktop inspector pane's shape — status / runtime /
/// suite / simulator / exit code / failure message / metrics — but
/// drops the log viewer (the web build does not have access to the
/// stdout / stderr paths, which only live next to the simulator
/// process).
class WebInspectorDialog extends StatelessWidget {
  /// Creates a [WebInspectorDialog].
  const WebInspectorDialog({required this.row, super.key});

  /// The row whose detail is being shown.
  final WebResultRow row;

  @override
  Widget build(BuildContext context) {
    final l10n = L10N.of(context);
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(l10n.webInspectorTitle(row.testId)),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _FieldRow(
                label: l10n.webInspectorFieldStatus,
                value: WebStatusChip(row.status),
              ),
              _FieldRow(
                label: l10n.webInspectorFieldRuntime,
                value: Text(
                  _formatDuration(row.runtime),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              _FieldRow(
                label: l10n.webInspectorFieldSuite,
                value: Text(row.suiteName, style: theme.textTheme.bodyMedium),
              ),
              _FieldRow(
                label: l10n.webInspectorFieldSimulator,
                value: Text(row.simulatorId, style: theme.textTheme.bodyMedium),
              ),
              if (row.exitCode != null)
                _FieldRow(
                  label: l10n.webInspectorFieldExitCode,
                  value: Text(
                    '${row.exitCode}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              if (row.failureMessage != null && row.failureMessage!.isNotEmpty)
                _FieldRow(
                  label: l10n.webInspectorFieldFailureMessage,
                  value: SelectableText(
                    row.failureMessage!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              if (row.metrics.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  l10n.webInspectorFieldMetrics,
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                ...row.metrics.entries.map(
                  (e) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1),
                    child: Text(
                      '${e.key} = ${e.value}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.webInspectorClose),
        ),
      ],
    );
  }

  String _formatDuration(Duration d) {
    if (d.inMilliseconds < 1000) {
      return '${d.inMilliseconds} ms';
    }
    final seconds = d.inMilliseconds / 1000.0;
    if (seconds < 60) {
      return '${seconds.toStringAsFixed(2)} s';
    }
    final minutes = seconds ~/ 60;
    final rem = (seconds - minutes * 60).toStringAsFixed(1);
    return '${minutes}m ${rem}s';
  }
}

class _FieldRow extends StatelessWidget {
  const _FieldRow({required this.label, required this.value});

  final String label;
  final Widget value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: value),
        ],
      ),
    );
  }
}
