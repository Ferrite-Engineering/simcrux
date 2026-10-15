// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/domain/enums/run_delta_bucket.dart';
import 'package:simcrux/features/dashboard/models/dashboard_filter.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/inspector/providers/run_delta_provider.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';

/// Compact "what changed vs. last run" strip suitable for the
/// dashboard's bottom or top region. Shows four counters: new
/// failures, fixed, new tests, other changes.
///
/// Each counter is a toggle: clicking it narrows the results table to the
/// tests it counted, scrolls the first of them to the top of the table and
/// opens it in the inspector. Clicking it again (or Clear in the filter bar)
/// shows every row again. The active counter is drawn filled.
///
/// Silently renders nothing when no prior history exists (the
/// underlying provider returns an all-zero [RunDelta] in that case).
class RunDeltaStrip extends ConsumerWidget {
  /// Creates a [RunDeltaStrip].
  const RunDeltaStrip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncDelta = ref.watch(runDeltaProvider);
    final active = ref.watch(dashboardFilterProvider).deltaBucket;
    // A counter that has emptied is no longer drawn, so the narrowing it set
    // would have no control left to switch it off. Drop it with the counter.
    ref.listen(runDeltaProvider, (_, next) {
      final delta = next.value;
      final bucket = ref.read(dashboardFilterProvider).deltaBucket;
      if (delta == null || bucket == null || delta.idsOf(bucket).isNotEmpty) {
        return;
      }
      _setFilter(ref, (f) => f.copyWith(clearDeltaBucket: true));
    });
    void toggle(RunDeltaBucket bucket, RunDelta delta) {
      final on = ref.read(dashboardFilterProvider).deltaBucket != bucket;
      if (on) {
        // A counter that covers the whole table narrows nothing, so also take
        // the user to the first test behind it: scroll it into view and open
        // it in the inspector.
        final ids = delta.idsOf(bucket);
        final rows = ref.read(dashboardRowsProvider).value;
        final first = rows?.where((r) => ids.contains(r.testId)).firstOrNull;
        if (first != null) {
          ref.read(dashboardRevealProvider.notifier).request(first.testId);
          ref.read(selectedTestIdProvider.notifier).select(first.testId);
        }
      }
      _setFilter(
        ref,
        (f) => on
            ? f.copyWith(deltaBucket: bucket)
            : f.copyWith(clearDeltaBucket: true),
      );
    }

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
                  active: active == RunDeltaBucket.newFailures,
                  onTap: () => toggle(RunDeltaBucket.newFailures, delta),
                ),
              if (delta.fixed > 0)
                _DeltaCounter(
                  label: '↗ ${delta.fixed} fixed',
                  color: Colors.green,
                  active: active == RunDeltaBucket.fixed,
                  onTap: () => toggle(RunDeltaBucket.fixed, delta),
                ),
              if (delta.newTests > 0)
                _DeltaCounter(
                  label: '+ ${delta.newTests} new',
                  color: theme.colorScheme.primary,
                  active: active == RunDeltaBucket.newTests,
                  onTap: () => toggle(RunDeltaBucket.newTests, delta),
                ),
              if (delta.otherChanges > 0)
                _DeltaCounter(
                  label: '~ ${delta.otherChanges} changed',
                  color: theme.colorScheme.onSurfaceVariant,
                  active: active == RunDeltaBucket.otherChanges,
                  onTap: () => toggle(RunDeltaBucket.otherChanges, delta),
                ),
            ],
          ),
        );
      },
      orElse: SizedBox.shrink.call,
    );
  }
}

/// Writes the dashboard filter through `setAll`, the one write every filter
/// notifier honours, including the per-project one.
void _setFilter(WidgetRef ref, DashboardFilter Function(DashboardFilter) edit) {
  ref
      .read(dashboardFilterProvider.notifier)
      .setAll(edit(ref.read(dashboardFilterProvider)));
}

class _DeltaCounter extends StatelessWidget {
  const _DeltaCounter({
    required this.label,
    required this.color,
    required this.active,
    required this.onTap,
  });

  final String label;
  final Color color;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shape = BorderRadius.circular(10);
    return Semantics(
      button: true,
      selected: active,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: shape,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              borderRadius: shape,
              color: color.withValues(alpha: active ? 0.35 : 0.15),
              border: Border.all(
                color: color.withValues(alpha: active ? 0.9 : 0.4),
              ),
            ),
            child: Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(color: color),
            ),
          ),
        ),
      ),
    );
  }
}
