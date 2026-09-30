// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/web/web_results_document.dart';

/// Filter state for the read-only web dashboard.
///
/// Reduced from the full desktop `DashboardFilter` to what the web
/// build needs: free-text substring against testId/suite/simulator,
/// and a status multi-select. Suite / simulator multi-selects are
/// folded into the free-text path because the web table is smaller
/// and a single search box is plenty.
@immutable
class WebFilter {
  /// Creates a [WebFilter].
  const WebFilter({
    this.query = '',
    this.statuses = const <TestStatus>{},
  });

  /// Substring matched (case-insensitive) against [WebResultRow.testId],
  /// [WebResultRow.suiteName], and [WebResultRow.simulatorId].
  final String query;

  /// When non-empty, only rows whose status is in this set pass the
  /// filter. Empty set means "any status".
  final Set<TestStatus> statuses;

  /// Returns true when the filter has no active terms.
  bool get isEmpty => query.isEmpty && statuses.isEmpty;

  /// Applies this filter to [rows].
  List<WebResultRow> apply(List<WebResultRow> rows) {
    if (isEmpty) return rows;
    final q = query.toLowerCase();
    return rows
        .where((row) {
          if (statuses.isNotEmpty && !statuses.contains(row.status)) {
            return false;
          }
          if (q.isEmpty) return true;
          return row.testId.toLowerCase().contains(q) ||
              row.suiteName.toLowerCase().contains(q) ||
              row.simulatorId.toLowerCase().contains(q) ||
              row.testName.toLowerCase().contains(q);
        })
        .toList(growable: false);
  }

  /// Returns a copy with the given fields replaced.
  WebFilter copyWith({String? query, Set<TestStatus>? statuses}) {
    return WebFilter(
      query: query ?? this.query,
      statuses: statuses ?? this.statuses,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WebFilter &&
          other.query == query &&
          other.statuses.length == statuses.length &&
          other.statuses.containsAll(statuses);

  @override
  int get hashCode => Object.hash(query, Object.hashAllUnordered(statuses));
}
