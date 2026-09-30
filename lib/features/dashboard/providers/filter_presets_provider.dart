// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/features/dashboard/models/dashboard_filter.dart';

/// A named [DashboardFilter] snapshot, recalled by tapping its chip in
/// the dashboard's preset row.
///
/// Only the two built-in presets exist today. [FilterPresetsNotifier.save]
/// and [FilterPresetsNotifier.remove] keep an in-memory list, but no UI
/// calls them and nothing persists it, so users cannot save their own.
@immutable
class FilterPreset {
  /// Creates a [FilterPreset].
  const FilterPreset({required this.name, required this.filter});

  /// Human-readable preset name (shown on the chip).
  final String name;

  /// Snapshot of the filter state the chip restores.
  final DashboardFilter filter;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FilterPreset && other.name == name && other.filter == filter;

  @override
  int get hashCode => Object.hash(name, filter);
}

/// The filter presets the dashboard's chip row shows: the built-in
/// Failures and Passing presets. The row reads this provider; nothing
/// writes it outside tests.
final NotifierProvider<FilterPresetsNotifier, List<FilterPreset>>
filterPresetsProvider =
    NotifierProvider<FilterPresetsNotifier, List<FilterPreset>>(
      FilterPresetsNotifier.new,
    );

/// Notifier backing [filterPresetsProvider].
class FilterPresetsNotifier extends Notifier<List<FilterPreset>> {
  @override
  List<FilterPreset> build() => _defaultPresets();

  /// Save (or replace) a preset under [name].
  void save(String name, DashboardFilter filter) {
    final next = <FilterPreset>[
      for (final existing in state)
        if (existing.name != name) existing,
      FilterPreset(name: name, filter: filter),
    ];
    state = List<FilterPreset>.unmodifiable(next);
  }

  /// Remove the preset named [name], if present.
  void remove(String name) {
    state = List<FilterPreset>.unmodifiable(
      state.where((p) => p.name != name),
    );
  }

  /// Replace the entire preset list (test convenience).
  void replaceAll(List<FilterPreset> presets) {
    state = List<FilterPreset>.unmodifiable(presets);
  }

  static List<FilterPreset> _defaultPresets() =>
      List<FilterPreset>.unmodifiable(
        <FilterPreset>[
          FilterPreset(
            name: 'Failures',
            filter: DashboardFilter(
              statuses: const {
                TestStatus.fail,
                TestStatus.timeout,
                TestStatus.unknown,
              },
            ),
          ),
          FilterPreset(
            name: 'Passing',
            filter: DashboardFilter(
              statuses: const {
                TestStatus.pass,
                TestStatus.vacuous,
              },
            ),
          ),
        ],
      );
}
