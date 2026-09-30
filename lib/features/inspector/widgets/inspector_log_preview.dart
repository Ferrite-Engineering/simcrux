// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/features/inspector/providers/inspector_log_provider.dart';
import 'package:simcrux/features/inspector/providers/log_preview_settings_provider.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// Tail-of-log preview in the inspector. Default 50 lines (override
/// via Settings → General → "Log preview lines"). Each line is
/// monospace and severity-colored by simple prefix heuristics.
class InspectorLogPreview extends ConsumerWidget {
  /// Creates an [InspectorLogPreview].
  const InspectorLogPreview({required this.selection, super.key});

  /// The currently-selected test snapshot.
  final SelectedTest selection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10N.of(context);
    final theme = Theme.of(context);
    final tailCount = ref.watch(logPreviewLineCountProvider);
    final snapshot = ref.watch(
      inspectorLogSnapshotProvider(
        InspectorLogArgs(
          testId: selection.testId,
          tailLineCount: tailCount,
        ),
      ),
    );

    if (snapshot.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.inspectorSectionLog,
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border.all(color: theme.colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              l10n.inspectorLogPreviewEmpty,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              l10n.inspectorSectionLog,
              style: theme.textTheme.titleSmall,
            ),
            Text(
              l10n.inspectorLogPreviewLineCount(snapshot.tailLines.length),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLowest,
            border: Border.all(color: theme.colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (snapshot.droppedCount > 0) ...[
                Text(
                  l10n.inspectorLogPreviewDropped(snapshot.droppedCount),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontStyle: FontStyle.italic,
                  ),
                ),
                const SizedBox(height: 4),
              ],
              for (final line in snapshot.tailLines)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: Text(
                    line.line,
                    softWrap: true,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      color:
                          _severityColor(line.line, theme) ??
                          theme.textTheme.bodySmall?.color,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  static Color? _severityColor(String line, ThemeData theme) {
    final lower = line.toLowerCase();
    if (lower.contains('error') ||
        lower.contains('fatal') ||
        lower.startsWith('uvm_error') ||
        lower.startsWith('uvm_fatal') ||
        lower.startsWith('%e')) {
      return theme.colorScheme.error;
    }
    if (lower.contains('warning') ||
        lower.startsWith('uvm_warning') ||
        lower.startsWith('%w')) {
      return Colors.amber;
    }
    if (lower.contains('info') ||
        lower.startsWith('uvm_info') ||
        lower.startsWith('%i')) {
      return theme.colorScheme.primary;
    }
    return null;
  }
}
