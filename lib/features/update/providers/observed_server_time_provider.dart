// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async' show unawaited;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences key holding the ISO-8601 observed server time.
const String kObservedServerTimePrefsKey = 'update.observedServerTime';

/// Persisted, **monotonic** store of the most recently observed authoritative
/// server time — the update manifest's `server_time`, delivered on every
/// successful fetch by `crux_updates`' `observedServerTimeSinkProvider`.
///
/// Feeds `crux_license`'s `observedServerTimeProvider`, which is what makes
/// the beta-expiry clock resistant to a device-clock rollback:
/// `trustedBetaExpiryNow` takes the *later* of the device clock and this
/// watermark, so winding the clock back can never defer expiry below the last
/// server time the app has seen.
///
/// Two properties carry the contract:
///
/// - **Monotonic.** [record] only ever advances the value. A stale cached
///   manifest, a CDN replay, or a server blip can never roll the trusted clock
///   backward.
/// - **Persisted.** The value survives relaunch, so a later *offline* start
///   still benefits from the last server time the app ever observed.
///
/// [build] returns `null` synchronously and kicks off the async load; once the
/// persisted value arrives the state advances and every watcher (the
/// beta-expiry providers, via the root override) re-evaluates.
///
/// Deliberately *not* absorbed into `crux_updates` — the package emits the
/// observation through a sink and leaves persistence to the host, which
/// already owns a preferences layer. This is the SimCrux half of that seam,
/// ported from the shipped WaveCrux implementation (which used Riverpod
/// codegen; SimCrux declares every provider by hand).
class ObservedServerTimeStore extends Notifier<DateTime?> {
  @override
  DateTime? build() {
    unawaited(_load());
    return null;
  }

  Future<void> _load() async {
    final SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } on Object {
      // No preferences backend (bare test scope, plugin-less host): the
      // trusted clock simply falls back to the device clock.
      return;
    }
    final iso = prefs.getString(kObservedServerTimePrefsKey);
    final parsed = iso == null ? null : DateTime.tryParse(iso);
    if (parsed != null) _advanceTo(parsed);
  }

  /// Records an observed server time, advancing the store (and persisting it)
  /// only when [serverTime] is strictly later than the current value.
  Future<void> record(DateTime serverTime) async {
    if (!_advanceTo(serverTime)) return;
    // Capture the just-advanced value synchronously (still mounted) so the
    // persist path never reads `state` after the getInstance() gap — a
    // container teardown mid-fetch disposes this notifier.
    final toPersist = state;
    if (toPersist == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        kObservedServerTimePrefsKey,
        toPersist.toIso8601String(),
      );
    } on Object {
      // Best-effort persistence. The in-memory watermark still hardens this
      // session; only the cross-launch benefit is lost.
    }
  }

  /// Sets [state] to [candidate] when it is strictly later than the current
  /// value (or the store is empty). Returns whether the state advanced.
  ///
  /// Both callers reach here after an async gap ([_load] after the prefs read,
  /// [record] from the post-fetch update callback), so a disposed ref must not
  /// touch `state` — bail first.
  bool _advanceTo(DateTime candidate) {
    if (!ref.mounted) return false;
    final current = state;
    if (current != null && !candidate.isAfter(current)) return false;
    state = candidate;
    return true;
  }
}

/// The persisted observed-server-time watermark. Keep-alive by construction:
/// `app.dart` wires it into the root container and `crux_license`'s
/// `observedServerTimeProvider` watches it for the lifetime of the app.
final NotifierProvider<ObservedServerTimeStore, DateTime?>
observedServerTimeStoreProvider =
    NotifierProvider<ObservedServerTimeStore, DateTime?>(
      ObservedServerTimeStore.new,
      name: 'observedServerTimeStoreProvider',
    );
