// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';

/// Snapshot of the trend store's current storage utilization.
///
/// Returned from `TrendStore.storageStats`. Surfaces in the App
/// Diagnostics dialog's Memory tab and in the Settings →
/// Trend Tracking → Retention panel so users see what their current
/// retention policy is actually buying them.
@immutable
class TrendStorageStats {
  /// Creates a [TrendStorageStats].
  const TrendStorageStats({
    required this.dataPointCount,
    required this.runCount,
    this.oldestPointAt,
    this.newestPointAt,
    this.approximateBytes,
  });

  /// Empty / fresh-install snapshot. Used by tests and by the
  /// no-op default trend store.
  static const TrendStorageStats empty = TrendStorageStats(
    dataPointCount: 0,
    runCount: 0,
  );

  /// Total per-test data points retained.
  final int dataPointCount;

  /// Total distinct runs retained.
  final int runCount;

  /// Timestamp (UTC) of the oldest retained data point. Null when
  /// the store is empty.
  final DateTime? oldestPointAt;

  /// Timestamp (UTC) of the most recently ingested data point. Null
  /// when the store is empty.
  final DateTime? newestPointAt;

  /// Approximate on-disk size, in bytes. Implementations that can't
  /// estimate this surface null (rather than zero) so the UI can
  /// label the field "unknown".
  final int? approximateBytes;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TrendStorageStats &&
          other.dataPointCount == dataPointCount &&
          other.runCount == runCount &&
          other.oldestPointAt == oldestPointAt &&
          other.newestPointAt == newestPointAt &&
          other.approximateBytes == approximateBytes;

  @override
  int get hashCode => Object.hash(
    dataPointCount,
    runCount,
    oldestPointAt,
    newestPointAt,
    approximateBytes,
  );

  @override
  String toString() =>
      'TrendStorageStats('
      'dataPoints: $dataPointCount, runs: $runCount, '
      'span: $oldestPointAt → $newestPointAt, '
      '~bytes: $approximateBytes)';
}
