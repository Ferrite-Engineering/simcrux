// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/dashboard/providers/filter_presets_provider.dart';

/// Row of filter preset chips above the dashboard filter bar.
///
/// Renders the presets from [filterPresetsProvider] (the built-in
/// "Failures" and "Passing") and applies one on tap; the chip matching the
/// current filter is selected. There is no way to save a preset from here.
class DashboardFilterPresetsBar extends ConsumerWidget {
  /// Creates a [DashboardFilterPresetsBar].
  const DashboardFilterPresetsBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final presets = ref.watch(filterPresetsProvider);
    final activeFilter = ref.watch(dashboardFilterProvider);
    final notifier = ref.read(dashboardFilterProvider.notifier);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final preset in presets)
            ChoiceChip(
              label: Text(preset.name),
              selected: preset.filter == activeFilter,
              onSelected: (_) => notifier.setAll(preset.filter),
            ),
        ],
      ),
    );
  }
}
