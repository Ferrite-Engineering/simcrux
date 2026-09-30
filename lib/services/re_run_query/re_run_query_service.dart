// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/result_store.dart';
import 'package:simcrux/domain/models/test_spec.dart';

/// Re-run-query surface consumed by Pro "Re-run failures only" / "Re-run
/// with seed N" / "Re-run all in this parameter group" workflows.
///
/// **Why a separate service.** `ResultStore` already owns the
/// historical-results surface but does not hold [TestSpec] instances —
/// only [TestResult]s, which carry the spec id but not the spec
/// itself. The Pro re-run UI needs the actual [TestSpec] so it can
/// resubmit to `JobScheduler.submit`, optionally with a seed swap. We
/// keep the spec lookup out of `ResultStore` to avoid bloating its
/// hot-path surface with re-run-only concerns.
///
/// **How the spec lookup is populated.** Whoever submits to the
/// scheduler (the CI runner / dashboard / replay path) is expected to
/// register every submitted [TestSpec] into the implementation's
/// lookup table via [trackSubmittedSpecs] before submission. The
/// default in-memory impl maintains a simple `Map<String, TestSpec>`
/// keyed by [TestSpec.id]. Tests inject their own implementation when
/// they want to control the spec inventory directly.
abstract class ReRunQueryService {
  /// Registers the given [specs] in the service's spec inventory so
  /// future [queryFailedSpecsFrom] / [queryGroupSpecsFor] lookups can
  /// resolve them. Idempotent — re-registering a spec under the same
  /// id overwrites the prior entry.
  void trackSubmittedSpecs(Iterable<TestSpec> specs);

  /// Returns the [TestSpec]s for every failed result in [runId].
  ///
  /// A result is considered failed if its status is
  /// [TestStatus.fail], [TestStatus.timeout], or
  /// [TestStatus.unknown]. Pass / cover / vacuous / cancelled /
  /// skipped statuses are excluded — the Pro UI surface labels this
  /// "Re-run failures only".
  ///
  /// Results whose corresponding [TestSpec] is no longer in the
  /// service's spec inventory (e.g. because the project was reloaded
  /// since submission) are silently skipped. The caller can detect
  /// this by comparing the returned list's length against the number
  /// of failing rows in the dashboard.
  Future<List<TestSpec>> queryFailedSpecsFrom(String runId);

  /// Returns every [TestSpec] in [runId] whose
  /// [TestSpec.parentSpecId] matches [parentSpecId] — i.e. every
  /// cartesian-product expansion of the parameterized template
  /// identified by [parentSpecId].
  ///
  /// Used by the Pro "Re-run all in this parameter group" workflow
  /// to re-issue an entire sweep from a single dashboard row.
  /// Returns an empty list when the supplied [parentSpecId] does not
  /// match any tracked spec — typically because the row's spec was
  /// not part of a sweep.
  Future<List<TestSpec>> queryGroupSpecsFor({
    required String parentSpecId,
    required String runId,
  });
}

/// Default in-memory [ReRunQueryService].
///
/// Holds a `Map<String, TestSpec>` keyed by [TestSpec.id] and queries
/// the supplied [ResultStore]'s results stream to filter the
/// inventory. Sufficient for the dashboard's in-process workflows;
/// a persistence-aware impl can layer on top later.
///
/// The [resultStoreResolver] is a function rather than a captured
/// reference because the open-core `resultStoreProvider` is a
/// `NotifierProvider<…, ResultStore?>` that starts null and emits the
/// real store once the first regression run is submitted. Calling
/// [queryFailedSpecsFrom] before the store exists returns an empty
/// list (no run → no failures).
///
/// **Project scoping.** [TestSpec.id] is suite/name-derived, not
/// project-scoped, so two projects with identically named suites/tests
/// (two checkouts of one repo) collide in a single flat inventory — a
/// re-run in one project would resolve the other's spec. The optional
/// [projectScopeResolver] partitions the inventory by its return value
/// (the active project id), so each project tracks and queries its own
/// specs. Open-core is single-project and leaves it null (one shared
/// scope, unchanged behaviour); the Pro overlay wires it to the active
/// project id.
class DefaultReRunQueryService implements ReRunQueryService {
  /// Creates the default service. [resultStoreResolver] is invoked
  /// on every query so the service stays in sync with the active
  /// store without being torn down across runs. [projectScopeResolver],
  /// when supplied, partitions the spec inventory by project id.
  DefaultReRunQueryService({
    required this.resultStoreResolver,
    this.projectScopeResolver,
  });

  /// Returns the active [ResultStore] (or null when no run is in
  /// flight). Invoked on each query.
  final ResultStore? Function() resultStoreResolver;

  /// Returns the project id the current track/query belongs to, or null
  /// for a single global scope. Invoked on every tracking and query
  /// call so the partition follows the active project.
  final String? Function()? projectScopeResolver;

  /// Spec inventory partitioned by project scope. A null scope key holds
  /// the single-project (open-core) inventory.
  final Map<String?, Map<String, TestSpec>> _specsByScope =
      <String?, Map<String, TestSpec>>{};

  /// The inventory map for the current project scope, created on demand.
  Map<String, TestSpec> get _specsById =>
      _specsByScope.putIfAbsent(projectScopeResolver?.call(), () {
        return <String, TestSpec>{};
      });

  @override
  void trackSubmittedSpecs(Iterable<TestSpec> specs) {
    final scope = _specsById;
    for (final spec in specs) {
      scope[spec.id] = spec;
    }
  }

  /// Read-only view of the spec inventory for the current project scope.
  /// Tests rely on this to assert tracking behavior.
  Map<String, TestSpec> get trackedSpecs =>
      Map<String, TestSpec>.unmodifiable(_specsById);

  static const Set<TestStatus> _failureStatuses = <TestStatus>{
    TestStatus.fail,
    TestStatus.timeout,
    TestStatus.unknown,
  };

  @override
  Future<List<TestSpec>> queryFailedSpecsFrom(String runId) async {
    final store = resultStoreResolver();
    if (store == null) return const <TestSpec>[];
    final stream = store.queryResults(
      ResultQuery(runId: runId, status: _failureStatuses),
    );
    // Capture the current project scope once so a scope change mid-query
    // cannot split the lookup across two inventories.
    final scope = _specsById;
    final specs = <TestSpec>[];
    final seen = <String>{};
    await for (final result in stream) {
      if (!seen.add(result.testId)) continue;
      final spec = scope[result.testId];
      if (spec != null) specs.add(spec);
    }
    return specs;
  }

  @override
  Future<List<TestSpec>> queryGroupSpecsFor({
    required String parentSpecId,
    required String runId,
  }) async {
    // We don't need to consult the result store — the entire
    // expansion lives in the current scope's inventory; the parent id is
    // the join key.
    return _specsById.values
        .where((s) => s.parentSpecId == parentSpecId)
        .toList(growable: false);
  }
}
