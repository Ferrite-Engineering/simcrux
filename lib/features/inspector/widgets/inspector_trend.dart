// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/features/inspector/providers/test_trend_provider.dart';
import 'package:simcrux/features/inspector/widgets/test_trend_sparkline.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// Per-test trend section in the inspector — the last N runs drawn
/// as a colored sparkline. Backed by the persistent SQLite trend
/// store. Empty state when this test has no history.
class InspectorTrend extends ConsumerWidget {
  /// Creates an [InspectorTrend].
  const InspectorTrend({required this.selection, super.key});

  /// The currently-selected test snapshot.
  final SelectedTest selection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10N.of(context);
    final theme = Theme.of(context);
    final asyncTrend = ref.watch(testTrendProvider(selection.testId));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.inspectorTrendHeading,
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        asyncTrend.when(
          loading: () => const SizedBox(
            height: 24,
            child: Center(
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
          error: (_, _) => Text(
            l10n.inspectorTrendEmpty,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          data: (statuses) {
            if (statuses.isEmpty) {
              return Text(
                l10n.inspectorTrendEmpty,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              );
            }
            return TestTrendSparkline(statuses: statuses);
          },
        ),
      ],
    );
  }
}
