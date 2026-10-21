// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_table/crux_table.dart';
import 'package:simcrux/features/dashboard/models/dashboard_sort.dart';

/// The results table's resizable columns, in display order, with the weights
/// they share the width by until the user drags a divider.
///
/// The check-box column is fixed and not part of this. The layout model, its
/// persistence, the header and the dividers are `crux_table`'s; this is the
/// one place that says which columns SimCrux has and how wide they start.
/// The minimum column width is the package's 56 px.
const CruxTableColumns<DashboardSortColumn> dashboardColumns =
    CruxTableColumns<DashboardSortColumn>(
      columns: [
        DashboardSortColumn.status,
        DashboardSortColumn.verdict,
        DashboardSortColumn.suite,
        DashboardSortColumn.testName,
        DashboardSortColumn.simulator,
        DashboardSortColumn.duration,
        DashboardSortColumn.startedAt,
      ],
      defaultWeights: {
        DashboardSortColumn.status: 1.2,
        DashboardSortColumn.verdict: 1.8,
        DashboardSortColumn.suite: 2,
        DashboardSortColumn.testName: 3,
        DashboardSortColumn.simulator: 1.4,
        DashboardSortColumn.duration: 1.2,
        DashboardSortColumn.startedAt: 1.6,
      },
    );

/// The results table's column weights: `crux_table`'s layout over
/// [dashboardColumns]. `dashboardColumns.defaults` is the untouched layout.
typedef DashboardColumnLayout = CruxColumnLayout<DashboardSortColumn>;
