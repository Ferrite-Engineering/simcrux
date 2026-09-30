// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/features/inspector/providers/inspector_log_provider.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/result_store/log_buffer_store.dart';

/// Bottom-pane log-stream panel.
///
/// Renders the captured stdout/stderr of the currently-selected test
/// from the inspector. Empty state until the user clicks a row in the
/// dashboard. Uses the same `fullInspectorLogProvider` source that
/// powers the inspector's "Open full log" dialog so both surfaces
/// agree on what's available.
///
/// The view is a live tail: `fullInspectorLogProvider` subscribes to
/// the selected test's `LogBuffer` stream and invalidates itself as
/// lines land, coalesced to at most one recompute per
/// `kLogInvalidationCoalesceWindow` (~80 ms) so a chatty testbench
/// refreshes the panel at ~12 Hz instead of once per line. It also
/// re-evaluates when the active result store changes (a new run).
class LogStreamPanel extends ConsumerWidget {
  /// Creates a [LogStreamPanel].
  const LogStreamPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10N.of(context);
    final theme = Theme.of(context);

    final selected = ref.watch(selectedTestProvider);
    if (selected == null) {
      return CruxPanelEmptyState(message: l10n.panelLogStreamPlaceholder);
    }

    final lines = ref.watch(fullInspectorLogProvider(selected.testId));
    if (lines.isEmpty) {
      return CruxPanelEmptyState(
        message: l10n.inspectorLogPreviewEmpty,
      );
    }

    return Container(
      color: theme.colorScheme.surface,
      padding: const EdgeInsets.all(8),
      child: Scrollbar(
        child: ListView.builder(
          // Performance: a long test can emit thousands of lines.
          // The lazy builder keeps the panel responsive even when
          // the buffer is large.
          itemCount: lines.length,
          itemBuilder: (context, index) {
            final line = lines[index];
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Text(
                line.line,
                softWrap: true,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  color:
                      _severityColor(line, theme) ??
                      theme.textTheme.bodySmall?.color,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// Severity coloring matches the inspector's tail preview so a line
  /// has the same color in both surfaces. Heuristic: stderr lines
  /// render in the error color; otherwise we fall back to a small set
  /// of substring/prefix rules (UVM macros, `%E` flags) that cover the
  /// common HDL log formats.
  static Color? _severityColor(LogLine line, ThemeData theme) {
    if (line.fromStderr) return theme.colorScheme.error;
    final lower = line.line.toLowerCase();
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
