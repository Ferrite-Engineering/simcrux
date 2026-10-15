// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// What the results table and the heatmap show when they have no rows.
///
/// Two different situations look the same from the rows alone, and the user
/// needs to be told which one they are in:
///
/// - No result has arrived yet (no project open, or a run just started): the
///   prompt to open a project and begin a regression.
/// - Results exist, and the active filters exclude every one of them: the
///   results are not missing, the filter is hiding them, so the view says that
///   and offers Clear filters, which resets the whole filter (text, chips,
///   runtime bounds and a clicked delta counter alike).
class DashboardNoRows extends ConsumerWidget {
  /// Creates a [DashboardNoRows].
  const DashboardNoRows({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10N.of(context);
    final filter = ref.watch(dashboardFilterProvider);
    final totals = ref.watch(dashboardTotalsProvider).value;
    final hasResults =
        totals != null && totals.byStatus.values.any((count) => count > 0);
    if (filter.isUnset || !hasResults) {
      return CruxPanelEmptyState(message: l10n.dashboardEmpty);
    }
    return CruxPanelEmptyState(
      message: l10n.dashboardNoMatches,
      action: TextButton.icon(
        onPressed: () => ref.read(dashboardFilterProvider.notifier).reset(),
        icon: const Icon(Icons.clear, size: 18),
        label: Text(l10n.dashboardFilterClear),
      ),
    );
  }
}
