// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:crux_settings/crux_settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/features/dashboard/models/dashboard_column_layout.dart';
import 'package:simcrux/features/dashboard/models/dashboard_sort.dart';
import 'package:simcrux/features/dashboard/services/dashboard_column_layout_codec.dart';

/// The [SettingsService] that reads and writes the results table's column
/// widths.
///
/// Override in tests with a `SettingsService(codec, prefsOverride: prefs)`.
final Provider<SettingsService<DashboardColumnLayout>>
dashboardColumnLayoutSettingsServiceProvider =
    Provider<SettingsService<DashboardColumnLayout>>(
      (_) => const SettingsService<DashboardColumnLayout>(
        DashboardColumnLayoutCodec(),
      ),
      name: 'dashboardColumnLayoutSettingsServiceProvider',
    );

/// The column widths persisted when this launch started.
///
/// Read synchronously so the first frame of a restored tab draws its columns
/// at their saved widths rather than jumping to them a moment later.
/// `bootstrap` resolves [loadDashboardColumnLayout] before `runApp` and
/// overrides this; tests get the defaults with no storage call.
final Provider<DashboardColumnLayout> launchDashboardColumnLayoutProvider =
    Provider<DashboardColumnLayout>(
      (_) => DashboardColumnLayout.defaults,
      name: 'launchDashboardColumnLayoutProvider',
    );

/// Loads the persisted column widths, or the defaults on any failure.
///
/// [service] is injectable for tests; production passes nothing.
Future<DashboardColumnLayout> loadDashboardColumnLayout({
  SettingsService<DashboardColumnLayout>? service,
}) async {
  try {
    return await (service ??
            const SettingsService<DashboardColumnLayout>(
              DashboardColumnLayoutCodec(),
            ))
        .load();
  } on Object {
    return DashboardColumnLayout.defaults;
  }
}

/// The results table's column widths.
///
/// App-wide rather than per tab: every tab shows the same columns, and a
/// width the user dragged in one is the width they want in the next. Lives in
/// the root container, which every tab's container is parented to.
final NotifierProvider<DashboardColumnLayoutNotifier, DashboardColumnLayout>
dashboardColumnLayoutProvider =
    NotifierProvider<DashboardColumnLayoutNotifier, DashboardColumnLayout>(
      DashboardColumnLayoutNotifier.new,
      name: 'dashboardColumnLayoutProvider',
    );

/// Notifier backing [dashboardColumnLayoutProvider].
class DashboardColumnLayoutNotifier extends Notifier<DashboardColumnLayout> {
  @override
  DashboardColumnLayout build() =>
      ref.read(launchDashboardColumnLayoutProvider);

  /// Drags the divider after [column] by [dx] pixels in a table whose
  /// resizable columns span [tableWidth] pixels. Not saved until [commit].
  void resize(DashboardSortColumn column, double dx, double tableWidth) {
    state = state.resize(column, dx, tableWidth);
  }

  /// Saves the current widths. Called when a drag ends, so a drag writes
  /// once rather than on every pointer move.
  void commit() => unawaited(_save());

  /// Restores and saves the default widths.
  void reset() {
    state = DashboardColumnLayout.defaults;
    unawaited(_save());
  }

  Future<void> _save() async {
    try {
      await ref.read(dashboardColumnLayoutSettingsServiceProvider).save(state);
    } on Object {
      // No preferences backend: the widths still apply to this session.
    }
  }
}
