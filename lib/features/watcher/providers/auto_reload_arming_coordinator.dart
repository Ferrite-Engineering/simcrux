// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Root-scoped coordinator that grants exactly one active auto-reload
/// armer per project.
///
/// [AutoReloadNotifier] is a per-tab provider, so N tabs viewing the same
/// project each build their own notifier and, without coordination, each
/// arm their own [SuiteSourceWatcher] against the same config. A single
/// source edit then fires N watchers → N `rerun()` calls → N duplicate
/// runs of one project into the shared per-project store slot. This
/// coordinator keeps a single armer per project key (the config path), so
/// the edit produces exactly one rerun regardless of tab count.
///
/// Standby tabs register but do not arm. When the active armer releases
/// (its tab closes or switches project), the next standby is promoted and
/// its [onActive] callback fires so watching hands over without a gap.
///
/// Materialized once at the root container (never in a per-tab override
/// list), so every per-tab notifier reads the same instance.
class AutoReloadArmingCoordinator {
  /// Armers registered per project key, in registration order. The head
  /// of each list is the active armer; the rest are standbys.
  final Map<String, List<_Armer>> _byKey = <String, List<_Armer>>{};

  /// Registers [token] for [key] with an [onActive] promotion callback.
  ///
  /// Returns true when [token] is the active armer (the first registered
  /// for [key], or already active). A false return means another tab is
  /// already watching this project and this caller should stay a standby.
  /// Idempotent: re-registering an existing token does not reorder it.
  bool register(String key, Object token, void Function() onActive) {
    final armers = _byKey.putIfAbsent(key, () => <_Armer>[]);
    if (!armers.any((a) => identical(a.token, token))) {
      armers.add(_Armer(token, onActive));
    }
    return identical(armers.first.token, token);
  }

  /// Unregisters [token] from [key]. If it was the active armer, the next
  /// standby is promoted and its [onActive] callback is invoked so it arms
  /// its watcher.
  void unregister(String key, Object token) {
    final armers = _byKey[key];
    if (armers == null) return;
    final wasActive = armers.isNotEmpty && identical(armers.first.token, token);
    armers.removeWhere((a) => identical(a.token, token));
    if (armers.isEmpty) {
      _byKey.remove(key);
      return;
    }
    if (wasActive) armers.first.onActive();
  }

  /// Whether [token] is currently the active armer for [key].
  bool isActive(String key, Object token) {
    final armers = _byKey[key];
    return armers != null &&
        armers.isNotEmpty &&
        identical(armers.first.token, token);
  }
}

class _Armer {
  _Armer(this.token, this.onActive);

  final Object token;
  final void Function() onActive;
}

/// Root-scoped [AutoReloadArmingCoordinator]. Deliberately absent from
/// every per-tab override list so per-tab notifiers resolve the single
/// root instance and share one armer election per project.
final Provider<AutoReloadArmingCoordinator>
autoReloadArmingCoordinatorProvider = Provider<AutoReloadArmingCoordinator>(
  (_) => AutoReloadArmingCoordinator(),
);
