// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/features/inspector/services/editor_launcher_provider.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/simulator/dart_test_metrics.dart';

/// The most log lines one row shows; the full log is in the run's log.
const int kInspectorMaxDartTestLogLines = 3;

/// One Dart test case: status, name, the first line of its error, the first
/// ROHD-VF severe log lines, and a Go to Source button.
///
/// One named node per row for a screen reader (status, name, duration, then
/// the error), with the button its own Tab stop.
class InspectorDartTestRow extends ConsumerWidget {
  /// Creates a row for [row].
  const InspectorDartTestRow({required this.row, super.key});

  /// The case.
  final DartTestRow row;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10N.of(context);
    final theme = Theme.of(context);
    final status = _statusLabel(l10n, row.status);
    final duration = row.durationMs;
    final spoken = StringBuffer('$status: ${row.name}');
    if (duration != null) {
      spoken.write(', ${l10n.inspectorDartTestsDuration(duration)}');
    }
    final message = row.message;
    if (row.failing && message != null) spoken.write('. $message');
    final severe = row.logs
        .where((l) => l.severity == 'SEVERE' || l.severity == 'SHOUT')
        .take(kInspectorMaxDartTestLogLines)
        .toList(growable: false);
    final target = row.goToFile;
    final line = row.goToLine;
    final failingColor = theme.colorScheme.error;
    return Padding(
      key: ValueKey<String>('dartTestRow:${row.name}'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Semantics(
              container: true,
              label: spoken.toString(),
              child: ExcludeSemantics(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: status,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: row.failing ? failingColor : null,
                            ),
                          ),
                          TextSpan(text: '  ${row.name}'),
                          if (duration != null)
                            TextSpan(
                              text:
                                  '  ${l10n.inspectorDartTestsDuration(duration)}',
                              style: theme.textTheme.labelSmall,
                            ),
                        ],
                      ),
                      style: theme.textTheme.bodySmall,
                    ),
                    if (row.failing && message != null)
                      SelectableText(
                        message,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                        ),
                      ),
                    for (final log in severe)
                      SelectableText(
                        l10n.inspectorDartTestsLogEntry(
                          log.severity ?? '',
                          log.simTime ?? 0,
                          log.logger ?? '',
                          log.message,
                        ),
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (target != null && line != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Tooltip(
                message: l10n.inspectorDartTestsGoToSourceTooltip(
                  '${_basename(target)}:$line',
                ),
                child: OutlinedButton(
                  key: ValueKey<String>('dartTestGoToSource:${row.name}'),
                  onPressed: () => _goToSource(context, ref),
                  child: Text(l10n.inspectorDartTestsGoToSource),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _goToSource(BuildContext context, WidgetRef ref) async {
    final file = row.goToFile;
    if (file == null) return;
    final launcher = ref.read(editorLauncherProvider);
    final ok = await launcher.openSource(
      filePath: file,
      line: row.goToLine ?? 1,
      column: row.goToColumn ?? 1,
    );
    if (!ok && context.mounted) {
      final command = launcher.template.trim().split(RegExp(r'\s+')).first;
      showCruxErrorSnack(
        context,
        L10N.of(context).inspectorOpenSourceFailed(command),
      );
    }
  }

  static String _basename(String path) => path.split(RegExp(r'[\\/]')).last;

  static String _statusLabel(L10N l10n, String status) => switch (status) {
    'PASS' => l10n.inspectorDartTestsStatusPass,
    'FAIL' => l10n.inspectorDartTestsStatusFail,
    'SKIP' => l10n.inspectorDartTestsStatusSkip,
    _ => l10n.inspectorDartTestsStatusError,
  };
}
