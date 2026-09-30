// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/domain/models/pr_annotation_target.dart';

/// Persistence seam for the user's configured [PrAnnotationTarget].
///
/// ### Split storage, on purpose
///
/// A target is two very different kinds of data wearing one type:
///
/// * **Configuration** — platform, `owner/repo`, PR number, webhook URL.
///   Boring, non-secret, belongs in ordinary settings.
/// * **A credential** — [PrAnnotationTarget.authToken]. A GitHub token
///   scoped to write check runs can mark any commit in the repository
///   green.
///
/// Implementations therefore split the write: configuration to
/// `shared_preferences`, the token to the OS keychain via
/// `crux_secrets`. That is the whole reason this feature waited — see
/// the Pro overlay's `SettingsPrAnnotationTargetStore`.
///
/// ### Open-core default
///
/// [NoopPrAnnotationTargetStore] persists nothing and always loads
/// `null`. No open-core code reads the store: in an open-core build the
/// PR-annotation actions dispatch through opener seams that default to
/// null. The real store ships in the Pro overlay alongside the
/// dispatchers it feeds and the settings section that edits it, matching
/// how `BaselineStore` / `JsonFileBaselineStore` are split.
abstract class PrAnnotationTargetStore {
  /// Loads the configured target, or `null` when the user has not set
  /// one up. Never throws for "absent" — that is a normal state.
  Future<PrAnnotationTarget?> load();

  /// Persists [target]. Configuration and credential go to different
  /// backing stores; see the class doc.
  Future<void> save(PrAnnotationTarget target);

  /// Forgets the target, including deleting the stored credential.
  Future<void> clear();
}

/// Open-core default: stores nothing, loads nothing.
class NoopPrAnnotationTargetStore implements PrAnnotationTargetStore {
  /// Const default.
  const NoopPrAnnotationTargetStore();

  @override
  Future<PrAnnotationTarget?> load() async => null;

  @override
  Future<void> save(PrAnnotationTarget target) async {}

  @override
  Future<void> clear() async {}
}

/// The active [PrAnnotationTargetStore].
///
/// Open-core default is [NoopPrAnnotationTargetStore]; the Pro overlay
/// registers the settings + keychain backed store in `proOverrides`.
final Provider<PrAnnotationTargetStore> prAnnotationTargetStoreProvider =
    Provider<PrAnnotationTargetStore>(
      (ref) => const NoopPrAnnotationTargetStore(),
    );

/// The currently configured target, or `null`.
///
/// Read by the Settings section (to populate its fields), by the
/// `dispatchPrAnnotations` action (to know whether there is anywhere to
/// send to), and by the run-completion auto-dispatch hook.
///
/// Invalidate after a save so every surface re-reads:
/// `ref.invalidate(activePrAnnotationTargetProvider)`.
final FutureProvider<PrAnnotationTarget?> activePrAnnotationTargetProvider =
    FutureProvider<PrAnnotationTarget?>(
      (ref) => ref.watch(prAnnotationTargetStoreProvider).load(),
    );
