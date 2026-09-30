// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/features/inspector/providers/run_delta_provider.dart';

/// Compact "what changed vs. last run" strip suitable for the
/// dashboard's bottom or top region. Shows four counters: new
/// failures, fixed, new tests, other changes.
///
/// Silently renders nothing when no prior history exists (the
/// underlying provider returns an all-zero [RunDelta] in that case).
class RunDeltaStrip extends ConsumerWidget {
  /// Creates a [RunDeltaStrip].
  const RunDeltaStrip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncDelta = ref.watch(runDeltaProvider);
    return asyncDelta.maybeWhen(
      data: (delta) {
        if (delta.totalChanges == 0) return const SizedBox.shrink();
        final theme = Theme.of(context);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Wrap(
            spacing: 12,
            children: [
              if (delta.newFailures > 0)
                _DeltaCounter(
                  label: '↘ ${delta.newFailures} new',
                  color: theme.colorScheme.error,
                ),
              if (delta.fixed > 0)
                _DeltaCounter(
                  label: '↗ ${delta.fixed} fixed',
                  color: Colors.green,
                ),
              if (delta.newTests > 0)
                _DeltaCounter(
                  label: '+ ${delta.newTests} new',
                  color: theme.colorScheme.primary,
                ),
              if (delta.otherChanges > 0)
                _DeltaCounter(
                  label: '~ ${delta.otherChanges} changed',
                  color: theme.colorScheme.onSurfaceVariant,
                ),
            ],
          ),
        );
      },
      orElse: SizedBox.shrink.call,
    );
  }
}

class _DeltaCounter extends StatelessWidget {
  const _DeltaCounter({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: color.withValues(alpha: 0.15),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}
