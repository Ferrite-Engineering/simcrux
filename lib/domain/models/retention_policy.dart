// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';

/// Strategy the trend store uses when pruning data points to keep
/// the row count under [RetentionPolicy.maxDataPoints].
enum RetentionPruneStrategy {
  /// Delete the oldest rows first. Preserves recent history at the
  /// expense of long-term trend visibility.
  oldestFirst,

  /// Keep recent points densely and older points sparsely. Used by
  /// long-history charts that need samples across years without
  /// paying per-run storage cost. Implementations select rows by
  /// time-bucket sampling — within each bucket they retain a
  /// representative sample and discard the rest.
  lowestValueFirst,
}

/// Configurable retention rules applied to the trend store.
///
/// Pruning is triggered by `TrendStore.applyRetention(policy)`. Each
/// field can be independently `null` for "no limit". When both
/// limits are set, both are enforced (an entry must satisfy *both*
/// to be retained).
///
/// **Defaults** (used by `retentionPolicyProvider`): 30-day age
/// limit, 50 000 data point cap, oldest-first pruning. These work
/// well for individual engineers running ~100 regressions/day —
/// roughly one quarter of history without runaway storage.
@immutable
class RetentionPolicy {
  /// Creates a [RetentionPolicy].
  const RetentionPolicy({
    this.maxAgeDays,
    this.maxDataPoints,
    this.maxWaveformRuns,
    this.pruneStrategy = RetentionPruneStrategy.oldestFirst,
  });

  /// Deserializes from the JSON-natural map produced by [toJson].
  /// Unknown / missing fields fall back to the default policy's
  /// values so old settings keep loading after a schema bump.
  factory RetentionPolicy.fromJson(Map<String, Object?> json) {
    final age = json['maxAgeDays'];
    final cap = json['maxDataPoints'];
    final waveRuns = json['maxWaveformRuns'];
    final stratName = json['pruneStrategy'] as String?;
    var strategy = RetentionPruneStrategy.oldestFirst;
    for (final s in RetentionPruneStrategy.values) {
      if (s.name == stratName) {
        strategy = s;
        break;
      }
    }
    return RetentionPolicy(
      maxAgeDays: age is int
          ? age
          : (age == null ? null : (age as num).toInt()),
      maxDataPoints: cap is int
          ? cap
          : (cap == null ? null : (cap as num).toInt()),
      maxWaveformRuns: waveRuns is int
          ? waveRuns
          : (waveRuns == null ? null : (waveRuns as num).toInt()),
      pruneStrategy: strategy,
    );
  }

  /// Built-in default: 30 days, 50 000 points, 10 runs of waveforms,
  /// oldest-first.
  static const RetentionPolicy defaultPolicy = RetentionPolicy(
    maxAgeDays: 30,
    maxDataPoints: 50000,
    maxWaveformRuns: 10,
  );

  /// Unlimited retention. Useful for tests that want to ingest large
  /// hand-crafted fixtures without surprise pruning.
  static const RetentionPolicy unlimited = RetentionPolicy();

  /// Maximum age (in days) of retained data points. Null = unlimited.
  /// Points older than `now - maxAgeDays` are eligible for deletion
  /// on the next `applyRetention` call.
  final int? maxAgeDays;

  /// Maximum number of data points retained in the store. Null =
  /// unlimited. When the count exceeds this cap, [pruneStrategy]
  /// decides which points to drop.
  final int? maxDataPoints;

  /// How many runs' waveform artifacts to keep on disk. Null = keep
  /// everything.
  ///
  /// Separate from [maxDataPoints] because the two bound different
  /// resources by orders of magnitude: a trend point is tens of bytes in
  /// SQLite, a VCD/FST dump is routinely hundreds of megabytes. A user who
  /// wants a quarter of *history* almost never wants a quarter of
  /// *waveforms*, and tying them to one number would force them to give up
  /// one to control the other.
  ///
  /// Counted in runs rather than days or bytes because that is the unit the
  /// question arrives in — "let me diff against the last few runs".
  final int? maxWaveformRuns;

  /// Strategy used when [maxDataPoints] is exceeded. Ignored when
  /// [maxDataPoints] is null.
  final RetentionPruneStrategy pruneStrategy;

  /// Whether this policy enforces any constraint at all.
  bool get isUnlimited =>
      maxAgeDays == null && maxDataPoints == null && maxWaveformRuns == null;

  /// Returns a copy with the given fields replaced.
  RetentionPolicy copyWith({
    int? maxAgeDays,
    int? maxDataPoints,
    int? maxWaveformRuns,
    RetentionPruneStrategy? pruneStrategy,
    bool clearMaxAge = false,
    bool clearMaxPoints = false,
    bool clearMaxWaveformRuns = false,
  }) {
    return RetentionPolicy(
      maxAgeDays: clearMaxAge ? null : (maxAgeDays ?? this.maxAgeDays),
      maxDataPoints: clearMaxPoints
          ? null
          : (maxDataPoints ?? this.maxDataPoints),
      maxWaveformRuns: clearMaxWaveformRuns
          ? null
          : (maxWaveformRuns ?? this.maxWaveformRuns),
      pruneStrategy: pruneStrategy ?? this.pruneStrategy,
    );
  }

  /// Serializes to a JSON-natural map for AppSettings persistence.
  Map<String, Object?> toJson() => <String, Object?>{
    'maxAgeDays': maxAgeDays,
    'maxDataPoints': maxDataPoints,
    'maxWaveformRuns': maxWaveformRuns,
    'pruneStrategy': pruneStrategy.name,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RetentionPolicy &&
          other.maxAgeDays == maxAgeDays &&
          other.maxDataPoints == maxDataPoints &&
          other.maxWaveformRuns == maxWaveformRuns &&
          other.pruneStrategy == pruneStrategy;

  @override
  int get hashCode =>
      Object.hash(maxAgeDays, maxDataPoints, maxWaveformRuns, pruneStrategy);

  @override
  String toString() =>
      'RetentionPolicy('
      'maxAgeDays: $maxAgeDays, '
      'maxDataPoints: $maxDataPoints, '
      'maxWaveformRuns: $maxWaveformRuns, '
      'pruneStrategy: ${pruneStrategy.name})';
}
