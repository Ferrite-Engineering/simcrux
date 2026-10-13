// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_settings/crux_settings.dart';
import 'package:crux_table/crux_table.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/features/dashboard/models/dashboard_column_layout.dart';
import 'package:simcrux/features/dashboard/models/dashboard_sort.dart';

/// `crux_table`'s provider set for the results table's column widths: the
/// settings service, the widths persisted when this launch started, and the
/// notifier the header's dividers drag.
///
/// The preference key is the one SimCrux wrote before the lift, under the
/// same `{column: weight}` JSON, so widths saved by an earlier build survive.
final CruxColumnLayoutProviders<DashboardSortColumn>
dashboardColumnLayoutProviders = CruxColumnLayoutProviders<DashboardSortColumn>(
  columns: dashboardColumns,
  prefsKey: 'simcrux.dashboardColumnWeights',
  name: 'dashboardColumnLayout',
);

/// The [SettingsService] that reads and writes the results table's column
/// widths.
///
/// Override in tests with a `SettingsService(codec, prefsOverride: prefs)`
/// over [dashboardColumnLayoutProviders]'s codec.
final Provider<SettingsService<DashboardColumnLayout>>
dashboardColumnLayoutSettingsServiceProvider =
    dashboardColumnLayoutProviders.settingsService;

/// The column widths persisted when this launch started.
///
/// Read synchronously so the first frame of a restored tab draws its columns
/// at their saved widths rather than jumping to them a moment later.
/// `bootstrap` resolves [loadDashboardColumnLayout] before `runApp` and
/// overrides this; tests get the defaults with no storage call.
final Provider<DashboardColumnLayout> launchDashboardColumnLayoutProvider =
    dashboardColumnLayoutProviders.launch;

/// Loads the persisted column widths, or the defaults on any failure.
///
/// [service] is injectable for tests; production passes nothing.
Future<DashboardColumnLayout> loadDashboardColumnLayout({
  SettingsService<DashboardColumnLayout>? service,
}) => dashboardColumnLayoutProviders.load(service: service);

/// The results table's column widths.
///
/// App-wide rather than per tab: every tab shows the same columns, and a
/// width the user dragged in one is the width they want in the next. Lives in
/// the root container, which every tab's container is parented to. The
/// notifier is the header's [CruxColumnResizeController]: `resize` while a
/// divider drags, `commit` when it is released, `reset` on a double-click.
final NotifierProvider<
  CruxColumnLayoutNotifier<DashboardSortColumn>,
  DashboardColumnLayout
>
dashboardColumnLayoutProvider = dashboardColumnLayoutProviders.layout;
