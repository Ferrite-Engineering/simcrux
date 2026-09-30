// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:collection';

import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/result_store.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_run.dart';
import 'package:simcrux/services/result_store/log_buffer_store.dart';

/// In-memory implementation of [ResultStore].
///
/// Holds the currently-active [TestRun] in a broadcast stream and
/// maintains four indexes for fast lookups:
///
/// - by `runId` → list of results in that run
/// - by `testId` → list of results across runs (chronological by
///   completion time)
/// - by `TestStatus` → list of results across runs
/// - by `simulatorId` and `suiteName` → likewise
///
/// Index maintenance is incremental: each [recordResult] call appends
/// to the current run and bumps the four index maps in O(1) amortized.
/// Queries return only matches and run in O(matches) without
/// rescanning the full result set.
///
/// **Persistence:** none. This implementation lives entirely in
/// memory and is reset when the process exits. The SQLite
/// `TrendStore` is the persistence layer; the [JobScheduler] is
/// expected to fan results out to both surfaces so the hot path
/// (this store) never blocks on disk I/O.
class InMemoryResultStore implements ResultStore {
  /// Creates an [InMemoryResultStore] for the given run. The run is
  /// immediately published to [currentRun] subscribers.
  ///
  /// While the run is in flight, published [TestRun]s are a single
  /// **live view** ([TestRun.view]) whose `results` is a read-only
  /// window over the store's growing list — recording a result is
  /// O(1) amortized instead of O(n) per result (which would make a
  /// full run O(n²)). The completed run published by
  /// [recordRunCompletion] is a proper immutable snapshot again.
  InMemoryResultStore.forRun(TestRun run, {int logBufferMaxLines = 5000})
    : logBufferStore = LogBufferStore(maxLinesPerTest: logBufferMaxLines) {
    _results.addAll(run.results);
    run.results.forEach(_indexResult);
    _run = TestRun.view(
      id: run.id,
      startedAt: run.startedAt,
      testIds: run.testIds,
      finishedAt: run.finishedAt,
      results: UnmodifiableListView<TestResult>(_results),
    );
    _currentRunController = StreamController<TestRun>.broadcast();
  }

  late TestRun _run;
  late final StreamController<TestRun> _currentRunController;
  bool _closed = false;
  RunSummary? _summary;

  /// Per-test log buffers populated by the scheduler. The inspector
  /// pane and the full log viewer subscribe to entries in this store
  /// keyed by `TestResult.testId`.
  final LogBufferStore logBufferStore;

  // ── primary store (the run's results, in completion order) ──────────
  final List<TestResult> _results = <TestResult>[];

  // ── indexes ─────────────────────────────────────────────────────────
  final Map<String, List<TestResult>> _byTestId = <String, List<TestResult>>{};
  final Map<TestStatus, List<TestResult>> _byStatus =
      <TestStatus, List<TestResult>>{};
  final Map<String, List<TestResult>> _bySuite = <String, List<TestResult>>{};
  final Map<String, List<TestResult>> _bySimulator =
      <String, List<TestResult>>{};

  // Membership mirrors of the two index maps above, kept for O(1)
  // "is this result in that suite / from that simulator" probes in
  // [queryResults]. Identity sets: `TestResult` has value equality, so
  // a hash set keyed on it would collapse genuinely distinct results
  // that happen to compare equal (same test, same status, same runtime
  // across two runs) into one entry and drop rows from filtered
  // queries. Identity is the correct relation here — the lists hold the
  // very instances we probe with.
  final Map<String, Set<TestResult>> _suiteMembers =
      <String, Set<TestResult>>{};
  final Map<String, Set<TestResult>> _simulatorMembers =
      <String, Set<TestResult>>{};

  // Forward lookups, so a consumer holding a result can name its suite and
  // simulator without inverting the reverse indexes above. Identity-keyed —
  // see `suiteOf`.
  final Map<TestResult, String> _suiteOfResult =
      Map<TestResult, String>.identity();
  final Map<TestResult, String> _simulatorOfResult =
      Map<TestResult, String>.identity();

  /// Read-only view of every recorded result, in completion order.
  ///
  /// Exposed for post-run consumers that need the whole set at once and
  /// have no filter to push down — `RegressionRunner`'s completion hooks
  /// (which hand it to the PR-annotation builder) are the motivating
  /// case. Prefer [queryResults] when a filter exists; it uses the
  /// indexes instead of scanning.
  List<TestResult> get results => List<TestResult>.unmodifiable(_results);

  /// Read-only view of the indexed-by-status results, exposed for
  /// tests and the dashboard's filter-chip counters.
  Map<TestStatus, List<TestResult>> get indexByStatus =>
      Map<TestStatus, List<TestResult>>.unmodifiable(
        _byStatus.map(
          (k, v) => MapEntry(k, List<TestResult>.unmodifiable(v)),
        ),
      );

  /// Read-only view of the indexed-by-test-id results, in completion
  /// order. Used by the trend view's "this test's history" surface
  /// before it queries the persistent [TrendStore] for older runs.
  Map<String, List<TestResult>> get indexByTestId =>
      Map<String, List<TestResult>>.unmodifiable(
        _byTestId.map(
          (k, v) => MapEntry(k, List<TestResult>.unmodifiable(v)),
        ),
      );

  /// Read-only view of the indexed-by-suite results.
  Map<String, List<TestResult>> get indexBySuite =>
      Map<String, List<TestResult>>.unmodifiable(
        _bySuite.map(
          (k, v) => MapEntry(k, List<TestResult>.unmodifiable(v)),
        ),
      );

  /// Read-only view of the indexed-by-simulator results.
  Map<String, List<TestResult>> get indexBySimulator =>
      Map<String, List<TestResult>>.unmodifiable(
        _bySimulator.map(
          (k, v) => MapEntry(k, List<TestResult>.unmodifiable(v)),
        ),
      );

  /// Every subscriber first receives the run as it stands, then each update.
  ///
  /// The snapshot is per subscriber. A broadcast controller's `onListen`
  /// fires only when the listener count goes from zero to one, so replaying
  /// from there reached the first subscriber alone: with the status bar's
  /// totals already listening, the rows table subscribing second — or
  /// re-subscribing because a filter or sort changed mid-run — got nothing
  /// until the next result landed, and sat on "Loading results…" through
  /// however long the running test took.
  ///
  /// After [recordRunCompletion] the broadcast controller is closed (its
  /// `done` is the terminal signal pre-completion subscribers key off); a
  /// late subscriber still gets the final snapshot, then `done`.
  @override
  Stream<TestRun> get currentRun => Stream<TestRun>.multi((controller) {
    controller.add(_run);
    if (_closed) {
      unawaited(controller.close());
      return;
    }
    final subscription = _currentRunController.stream.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    controller
      ..onPause = subscription.pause
      ..onResume = subscription.resume
      ..onCancel = subscription.cancel;
  });

  @override
  TestRun get latestRun => _run;

  @override
  Future<void> recordResult(TestResult result) async {
    if (_closed) {
      throw StateError('Cannot record result on a closed ResultStore.');
    }
    if (result.runId != _run.id) {
      throw ArgumentError(
        'TestResult.runId (${result.runId}) does not match the current '
        'run (${_run.id}). Use a fresh InMemoryResultStore per run.',
      );
    }
    _results.add(result);
    _indexResult(result);
    // Suite and simulator are looked up by indexing the corresponding
    // `TestSpec` upstream of this store; the `TestResult`
    // does not carry them, so we cache them through the public
    // [recordResult] entry point only when [recordResultWithMetadata]
    // is used. The bare [recordResult] entry still updates the
    // status / testId / runId indexes (most common case).
    //
    // `_run` is a live view over `_results` — the append above is
    // already visible through it, so re-emitting the same instance
    // is the whole notification (no per-result run copy; see the
    // constructor doc + TestRun.view).
    _currentRunController.add(_run);
  }

  /// Appends [result] to the testId / status indexes (O(1) amortized).
  void _indexResult(TestResult result) {
    _byTestId.putIfAbsent(result.testId, () => <TestResult>[]).add(result);
    _byStatus.putIfAbsent(result.status, () => <TestResult>[]).add(result);
  }

  /// Variant of [recordResult] that lets the caller (typically the
  /// [JobScheduler], which knows the originating [TestSpec]) attach
  /// suite and simulator metadata for indexing. Without this, the
  /// suite / simulator indexes stay empty because [TestResult] does
  /// not carry that information.
  Future<void> recordResultWithMetadata(
    TestResult result, {
    required String suiteName,
    required String simulatorId,
  }) async {
    await recordResult(result);
    _bySuite.putIfAbsent(suiteName, () => <TestResult>[]).add(result);
    _bySimulator.putIfAbsent(simulatorId, () => <TestResult>[]).add(result);
    _suiteMembers.putIfAbsent(suiteName, Set<TestResult>.identity).add(result);
    _simulatorMembers
        .putIfAbsent(simulatorId, Set<TestResult>.identity)
        .add(result);
    _suiteOfResult[result] = suiteName;
    _simulatorOfResult[result] = simulatorId;
  }

  /// The suite [result] was recorded under, or null when it was recorded
  /// through the bare [recordResult] entry point.
  ///
  /// **Identity-keyed, like the membership sets above and for the same
  /// reason**: `TestResult` has value equality, so a hash map keyed on it
  /// would collapse two genuinely distinct results that happen to compare
  /// equal — the same test, the same status and the same runtime in two runs
  /// — and hand back the wrong suite for one of them.
  String? suiteOf(TestResult result) => _suiteOfResult[result];

  /// The simulator [result] was recorded under. See [suiteOf].
  String? simulatorOf(TestResult result) => _simulatorOfResult[result];

  @override
  Future<void> recordRunCompletion(RunSummary summary) async {
    if (_closed) return;
    _summary = summary;
    // copyWith routes through the copying default constructor, so the
    // completed run is a true immutable snapshot (one O(n) copy at
    // run end) rather than the in-flight live view.
    _run = _run.copyWith(finishedAt: summary.finishedAt);
    _currentRunController.add(_run);
    _closed = true;
    await _currentRunController.close();
  }

  /// The recorded [RunSummary] after [recordRunCompletion] fires.
  /// Null until the run finishes.
  RunSummary? get summary => _summary;

  /// Number of results recorded so far.
  int get recordedCount => _results.length;

  /// True once [recordRunCompletion] has been called.
  bool get isFinished => _closed;

  // ── historical queries ──────────────────────────────────────────────
  //
  // An in-memory store of the current run only. Cross-run queries
  // (`queryRuns`, `queryResults` outside the current run) are serviced by
  // the SQLite-backed [TrendStore].
  // These stream methods filter the active run; the dashboard's
  // multi-run views ride on top of the [TrendStore] surface.

  @override
  Stream<TestRun> queryRuns(RunQuery query) async* {
    if (_summary == null && _run.testIds.isEmpty) return;
    if (query.since != null && _run.startedAt.isBefore(query.since!)) return;
    if (query.until != null && !_run.startedAt.isBefore(query.until!)) return;
    yield _run;
  }

  @override
  Stream<TestResult> queryResults(ResultQuery query) async* {
    Iterable<TestResult> source;
    if (query.runId != null && query.runId != _run.id) {
      return;
    }
    if (query.status != null && query.status!.length == 1) {
      source = _byStatus[query.status!.single] ?? const <TestResult>[];
    } else if (query.suiteName != null) {
      source = _bySuite[query.suiteName!] ?? const <TestResult>[];
    } else if (query.simulatorId != null) {
      source = _bySimulator[query.simulatorId!] ?? const <TestResult>[];
    } else {
      source = _results;
    }
    var emitted = 0;
    for (final result in source) {
      if (query.status != null &&
          query.status!.length != 1 &&
          !query.status!.contains(result.status)) {
        continue;
      }
      // Membership is tested against identity sets, not the index
      // lists. `List.contains` is a linear scan using `TestResult`'s
      // (deep) equality, so combining a suite or simulator filter with
      // any other filter was O(n·m) over the run — seconds on a 10k
      // -result run. The sets are maintained alongside the lists in
      // [_indexResult] and are O(1) to probe.
      if (query.suiteName != null &&
          !(_suiteMembers[query.suiteName!]?.contains(result) ?? false)) {
        continue;
      }
      if (query.simulatorId != null &&
          !(_simulatorMembers[query.simulatorId!]?.contains(result) ?? false)) {
        continue;
      }
      if (query.testIdSubstring != null &&
          !result.testId.contains(query.testIdSubstring!)) {
        continue;
      }
      if (query.minRuntime != null && result.runtime < query.minRuntime!) {
        continue;
      }
      if (query.maxRuntime != null && result.runtime > query.maxRuntime!) {
        continue;
      }
      yield result;
      emitted++;
      if (query.limit != null && emitted >= query.limit!) return;
    }
  }
}
