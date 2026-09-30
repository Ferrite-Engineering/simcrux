// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:simcrux/features/dashboard/widgets/dashboard_status_icon.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';

/// Status badge + test-id heading shown at the top of the inspector
/// pane.
class InspectorHeader extends StatelessWidget {
  /// Creates an [InspectorHeader].
  const InspectorHeader({required this.selection, super.key});

  /// The currently-selected test snapshot.
  final SelectedTest selection;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        DashboardStatusIcon(status: selection.result.status),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                selection.row.testName,
                style: theme.textTheme.titleLarge,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
              Text(
                selection.testId,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontFamily: 'monospace',
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
