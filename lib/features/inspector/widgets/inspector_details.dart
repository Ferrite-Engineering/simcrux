// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// Key-value details section in the inspector — suite, simulator,
/// runtime, exit code, working directory, waveform path.
class InspectorDetails extends StatelessWidget {
  /// Creates an [InspectorDetails].
  const InspectorDetails({required this.selection, super.key});

  /// The currently-selected test snapshot.
  final SelectedTest selection;

  @override
  Widget build(BuildContext context) {
    final l10n = L10N.of(context);
    final theme = Theme.of(context);
    final result = selection.result;
    final rows = <_DetailRow>[
      _DetailRow(
        label: l10n.inspectorFieldSuite,
        value: selection.row.suiteName,
      ),
      _DetailRow(
        label: l10n.inspectorFieldSimulator,
        value: selection.row.simulatorId,
      ),
      _DetailRow(
        label: l10n.inspectorFieldDuration,
        value: _formatDuration(result.runtime),
      ),
      _DetailRow(
        label: l10n.inspectorFieldExitCode,
        value: result.exitCode?.toString() ?? '—',
      ),
      _DetailRow(
        label: l10n.inspectorFieldStartedAt,
        value: result.startedAt.toUtc().toIso8601String(),
      ),
      if (result.stdoutPath != null)
        _DetailRow(
          label: l10n.inspectorFieldWorkingDirectory,
          value: result.stdoutPath!.replaceAll('/sim_stdout.log', ''),
          monospace: true,
        ),
      if (result.waveformPath != null)
        _DetailRow(
          label: l10n.inspectorFieldWaveform,
          value: result.waveformPath!,
          monospace: true,
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.inspectorSectionDetails,
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 4),
        ...rows.map(
          (row) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 110,
                  child: Text(
                    row.label,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Expanded(
                  child: SelectableText(
                    row.value,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: row.monospace ? 'monospace' : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _formatDuration(Duration d) {
    if (d.inMilliseconds < 1000) return '${d.inMilliseconds} ms';
    if (d.inSeconds < 60) {
      final ms = d.inMilliseconds % 1000;
      return '${d.inSeconds}.${ms.toString().padLeft(3, '0').substring(0, 1)} s';
    }
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '${m}m ${s.toString().padLeft(2, '0')}s';
  }
}

class _DetailRow {
  const _DetailRow({
    required this.label,
    required this.value,
    this.monospace = false,
  });
  final String label;
  final String value;
  final bool monospace;
}
