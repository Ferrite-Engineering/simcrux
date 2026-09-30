// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/domain/models/retention_policy.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';

/// Active retention policy for the trend store and waveform artifacts.
///
/// Backed by [AppSettings.retentionPolicy], so a policy the user set
/// survives a restart. It previously lived only in this notifier's memory:
/// a user who dialled retention down to keep their disk under control got
/// the defaults back on next launch, and the sweep they had asked for
/// quietly stopped happening.
///
/// The open-core `RegressionRunner` reads this provider and applies both the
/// trend prune and the waveform sweep best-effort after every completed run,
/// so the policy is enforced continuously without an explicit user action.
/// The Pro Settings → Retention section edits it.
final NotifierProvider<RetentionPolicyNotifier, RetentionPolicy>
retentionPolicyProvider =
    NotifierProvider<RetentionPolicyNotifier, RetentionPolicy>(
      RetentionPolicyNotifier.new,
    );

/// Notifier backing [retentionPolicyProvider].
class RetentionPolicyNotifier extends Notifier<RetentionPolicy> {
  @override
  RetentionPolicy build() {
    // Settings load asynchronously. Until they land, report the default —
    // the same value the codec falls back to — and re-read when they
    // arrive, so a policy set in a previous session applies as soon as it
    // is known rather than only after the user visits Settings.
    return ref.watch(
      appSettingsProvider.select(
        (async) =>
            async.value?.retentionPolicy ?? RetentionPolicy.defaultPolicy,
      ),
    );
  }

  /// Replaces the active policy and persists it.
  ///
  /// The in-memory state is set first so the UI reflects the change even if
  /// the write fails; a retention policy the user can see but that did not
  /// persist is a smaller problem than a control that appears not to work.
  void replace(RetentionPolicy next) {
    state = next;
    unawaited(
      ref.read(appSettingsProvider.notifier).setRetentionPolicy(next),
    );
  }

  /// Convenience: update a single field.
  void update({
    int? maxAgeDays,
    int? maxDataPoints,
    int? maxWaveformRuns,
    RetentionPruneStrategy? pruneStrategy,
    bool clearMaxAge = false,
    bool clearMaxPoints = false,
    bool clearMaxWaveformRuns = false,
  }) {
    replace(
      state.copyWith(
        maxAgeDays: maxAgeDays,
        maxDataPoints: maxDataPoints,
        maxWaveformRuns: maxWaveformRuns,
        pruneStrategy: pruneStrategy,
        clearMaxAge: clearMaxAge,
        clearMaxPoints: clearMaxPoints,
        clearMaxWaveformRuns: clearMaxWaveformRuns,
      ),
    );
  }
}
