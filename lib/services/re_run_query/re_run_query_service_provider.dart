// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/services/re_run_query/re_run_query_service.dart';
import 'package:simcrux/services/result_store/result_store_provider.dart';

/// Active [ReRunQueryService] used by Pro re-run workflows on the
/// dashboard.
///
/// Open-core ships [DefaultReRunQueryService] as the default
/// implementation. The Pro overlay does not override this — the same
/// in-memory implementation works for every tier. Tests override it
/// when they want to drive the service with a pre-populated spec
/// inventory.
///
/// **Tracking lifecycle.** The default impl's [trackSubmittedSpecs]
/// must be invoked by whoever submits to the scheduler so the
/// service's inventory mirrors what the dashboard sees.
/// `RegressionRunner.start` and `RegressionRunner.submitSpecs` call it
/// for every submission, so their callers do not need to.
///
/// **Result-store lifecycle.** The service holds a reference to the
/// active [ResultStore] for its lifetime. The provider rebuilds the
/// service whenever the store identity changes (new project loaded,
/// in-memory store reset for a fresh run) so the service always
/// queries against the current run.
///
/// **Scoping.** `resultStoreProvider` is per-tab in open-core mode, so
/// this provider is per-tab too (via `simcruxTabOverrides`) — a
/// root-materialized instance would query the dormant root store and
/// silently return no results. In Pro mode the per-tab entry is
/// dropped and the single root instance resolves the root per-project
/// store delegate.
final Provider<ReRunQueryService> reRunQueryServiceProvider =
    Provider<ReRunQueryService>(reRunQueryService);

/// Body of [reRunQueryServiceProvider]. Exposed as a top-level function
/// so `simcruxTabOverrides` can override the provider per-tab with the
/// same implementation.
ReRunQueryService reRunQueryService(Ref ref) {
  return DefaultReRunQueryService(
    resultStoreResolver: () => ref.read(resultStoreProvider),
  );
}
