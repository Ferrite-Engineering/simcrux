// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:crux_cxp/crux_cxp.dart';
import 'package:crux_license/crux_license.dart';
import 'package:crux_telemetry/crux_telemetry.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/core/policy/simcrux_policy_keys.dart';
import 'package:simcrux/domain/enums/regression_trigger.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/job_scheduler.dart';
import 'package:simcrux/domain/interfaces/result_store.dart';
import 'package:simcrux/domain/interfaces/trend_store.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/regression_request.dart';
import 'package:simcrux/domain/models/retention_policy.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_run.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/features/config/providers/config_loader_provider.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/remote/services/cxp_workspace_link.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/settings/providers/retention_policy_provider.dart';
import 'package:simcrux/features/statistics/providers/job_scheduler_stats_provider.dart';
import 'package:simcrux/services/ci/ci_runner.dart' show CiRunResult;
import 'package:simcrux/services/job_scheduler/job_scheduler_provider.dart';
import 'package:simcrux/services/lifecycle/active_run_registry.dart';
import 'package:simcrux/services/lifecycle/app_exit_provider.dart';
import 'package:simcrux/services/lifecycle/run_completion_hooks.dart';
import 'package:simcrux/services/pass_fail_detector/pass_fail_detector_registry.dart';
import 'package:simcrux/services/re_run_query/re_run_query_service_provider.dart';
import 'package:simcrux/services/result_store/in_memory_result_store.dart';
import 'package:simcrux/services/result_store/result_store_provider.dart';
import 'package:simcrux/services/telemetry/simulator_telemetry_token.dart';
import 'package:simcrux/services/telemetry/telemetry_event_catalog.dart';
import 'package:simcrux/services/trend_store/trend_store_provider.dart';
import 'package:simcrux/services/trend_store/waveform_retention_sweeper.dart';

/// Max buffered trend points before [_TrendPointBuffer] flushes early.
/// Tuned so a fast burst of finishing tests amortizes to one SQLite
/// transaction (one fsync, one `dataChanged` tick) per
/// [kTrendFlushBatchSize] results instead of one per result.
const int kTrendFlushBatchSize = 25;

/// Max time a buffered trend point waits before [_TrendPointBuffer]
/// flushes, so a slow trickle of results still lands in the store (and
/// on the inspector sparkline) promptly.
const Duration kTrendFlushInterval = Duration(milliseconds: 250);

/// What a finished run's housekeeping needs from `ref`, resolved before the
/// awaits it comes after. See `RegressionRunner._resolveCompletionHousekeeping`.
typedef _CompletionHousekeeping = ({
  RetentionPolicy policy,
  WaveformRetentionSweeper sweeper,
  List<RunCompletionHook> hooks,
});

/// Buffers per-result [TrendPoint]s and flushes them through
/// [TrendStore.recordTrendPoints] every [kTrendFlushBatchSize] points
/// or [kTrendFlushInterval], whichever comes first.
///
/// Why: the per-result `recordTrendPoint` path wraps every insert in
/// its own SQLite transaction (its own fsync) and fires one
/// `dataChanged` event per finished test — mid-run, every open
/// sparkline / delta strip re-ran its full query per result. Batching
/// turns that into one transaction + one tick per flush.
///
/// Flushes are best-effort like the per-point inserts were: a failed
/// batch is dropped rather than tearing down the in-memory regression.
class _TrendPointBuffer {
  _TrendPointBuffer(this._store);

  final TrendStore _store;
  final List<TrendPoint> _pending = <TrendPoint>[];
  Timer? _timer;

  /// Queues [point]; flushes when the batch threshold is reached,
  /// otherwise arms the flush timer.
  void add(TrendPoint point) {
    _pending.add(point);
    if (_pending.length >= kTrendFlushBatchSize) {
      unawaited(flush());
    } else {
      _timer ??= Timer(kTrendFlushInterval, () {
        _timer = null;
        unawaited(flush());
      });
    }
  }

  /// Drains the pending batch into the store. Safe to call
  /// concurrently / repeatedly: the batch is claimed synchronously, so
  /// overlapping flushes operate on disjoint points, and sqflite's
  /// FIFO transaction queue preserves insertion order across batches.
  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    if (_pending.isEmpty) return;
    final batch = List<TrendPoint>.of(_pending);
    _pending.clear();
    try {
      await _store.recordTrendPoints(batch);
    } on Object {
      // Best-effort persistence; a failed batch must not tear down
      // the in-memory regression. Refresh of the inspector's "Recent
      // runs" sparkline and the dashboard's recently-changed-status
      // section is driven by the [trendStoreChangeTickProvider] which
      // listens to [TrendStore.dataChanged] — no explicit
      // ref.invalidate needed. (Earlier wiring tried to invalidate
      // from the per-tab notifier, but the trend providers
      // materialize in the root container under the Pro per-project
      // provider scope, so a child-container invalidate was a no-op.)
    }
  }
}

/// State of the active regression run.
///
/// Carries the [TestRun] so the UI can read its id / startedAt /
/// totals without subscribing to the result store.
class RegressionRunState {
  /// Creates a [RegressionRunState].
  const RegressionRunState({
    required this.run,
    required this.isFinished,
    this.cancelled = false,
  });

  /// The active or just-completed [TestRun].
  final TestRun run;

  /// True when every test has reported a terminal status.
  final bool isFinished;

  /// True when the run was user-cancelled.
  final bool cancelled;
}

/// Starts a regression for a loaded [RegressionConfig], threads
/// results through both the in-memory [ResultStore] and the
/// persistent [TrendStore], and exposes the run state to the
/// dashboard UI.
///
/// Wired by the CLI bootstrap (when the user passes a project file)
/// and by the File → Open Project menu action.
final AsyncNotifierProvider<RegressionRunner, RegressionRunState?>
regressionRunnerProvider =
    AsyncNotifierProvider<RegressionRunner, RegressionRunState?>(
      RegressionRunner.new,
    );

/// Notifier backing [regressionRunnerProvider].
class RegressionRunner extends AsyncNotifier<RegressionRunState?> {
  StreamSubscription<RegressionEvent>? _subscription;
  String? _activeRunId;

  /// The scheduler instance the in-flight run was submitted to.
  ///
  /// Run teardown itself rides [_subscription]: `submit`'s stream
  /// `onCancel` closes over the owning run state, so cancelling the
  /// subscription always reaches the right instance. The explicit
  /// [JobScheduler.cancel] below is the belt-and-braces half, and it
  /// looks the run up in the receiving instance's own table — so
  /// re-resolving `schedulerFor(activeConfig)` at cancel time would
  /// silently no-op whenever the cache had handed back a different
  /// instance (the LRU evicts past `kJobSchedulerCacheSize` distinct
  /// simulator signatures, and editing the `simulators:` block changes
  /// the key outright). Pinning the instance keeps both halves aimed at
  /// the same scheduler.
  JobScheduler? _activeScheduler;
  _TrendPointBuffer? _trendBuffer;

  /// The in-flight run's result and trend stores, held so [cancel] can close
  /// the run out: its own bookkeeping otherwise rides [RegressionFinished],
  /// which a cancelled subscription never delivers.
  InMemoryResultStore? _activeStore;
  TrendStore? _activeTrendStore;

  /// Bumped by every [start] and [submitSpecs]. A call that finds it moved on
  /// across one of its awaits has been superseded and stops there: with
  /// auto-reload on, saving two source files at once fires two reruns, and
  /// both used to get past their `cancel()` and submit a regression each.
  int _startGeneration = 0;

  bool _superseded(int generation) =>
      generation != _startGeneration || !ref.mounted;
  ActiveRunToken? _activeRunToken;
  ActiveRunRegistry? _runRegistry;

  /// The seam for the terminal counters, resolved **per event**.
  ///
  /// It was resolved in [build] for the same reason [_runRegistry] is: these
  /// counters fire from paths that may run after this notifier is disposed,
  /// where `Ref.read` throws. That is handled by the `ref.mounted` guard at the
  /// one call site instead, because holding the service had a cost the registry
  /// does not: `telemetryServiceProvider` is not constant for the life of a
  /// session. The consent store publishes `unset` synchronously and reads the
  /// persisted value back asynchronously, so at the moment this notifier builds
  /// — a cold start — the gate has not seen the user's stored answer yet and
  /// resolves the no-op. Caching that froze the first frame's verdict for the
  /// whole session, which for a long regression run is every counter it has.
  TelemetryService? get _telemetry =>
      ref.mounted ? ref.read(telemetryServiceProvider) : null;

  /// The trigger of the in-flight run, so the terminal counter can report
  /// what started it long after the caller that said so has returned.
  RegressionTrigger _activeTrigger = RegressionTrigger.manual;

  /// The `simulator` token of the in-flight run, derived once from the
  /// submitted specs.
  String? _activeSimulator;

  /// How many specs the in-flight run submitted.
  int _activeTestCount = 0;

  /// The detector `kind` tokens the in-flight run's specs will dispatch.
  Set<String> _activeDetectorKinds = const <String>{};

  /// Engine tokens the in-flight run could not launch at all.
  ///
  /// A `Set` for the same reason `detector.matched` is emitted per run rather
  /// than per test: a 500-test suite pointed at an uninstalled `iverilog`
  /// fails 500 times for one reason, and 500 identical events would evict
  /// every other counter from a queue capped at 2000.
  final Set<String> _missingEngines = <String>{};

  /// The run id whose terminal counter (`regression.completed` /
  /// `regression.cancelled`) has already been recorded.
  ///
  /// A run has exactly one ending, but it has two paths to one: an explicit
  /// [cancel] tears the subscription down before `RegressionFinished` can
  /// arrive, while the app-exit registry cancels the *scheduler* directly and
  /// the event does arrive. Both must record, and neither may record twice, so
  /// the guard is on the run id rather than on the path.
  String? _terminalRecordedRunId;

  /// Source of the run id. Tests can override to get deterministic
  /// ids; production uses millisecond timestamps which are unique
  /// enough for a single-user, local-process run.
  String Function() runIdFactory = () =>
      DateTime.now().toUtc().millisecondsSinceEpoch.toString();

  @override
  Future<RegressionRunState?> build() async {
    // Resolved eagerly because `_releaseActiveRunToken` runs from
    // `onDispose`, where `Ref.read` is forbidden. Reading it there
    // throws, and the throw aborts the rest of the hook — the
    // subscription cancel and the buffered-trend flush below it — so a
    // tab closed with a run still in flight would skip its own cleanup.
    _runRegistry = ref.read(activeRunRegistryProvider);
    ref.onDispose(() async {
      // Drop this run from the app-exit registry first: a disposed
      // notifier must not leave a canceller behind that the quit path
      // would later invoke against torn-down state.
      _releaseActiveRunToken();
      await _subscription?.cancel();
      // Land any buffered trend points; a flush against an
      // already-closed store degrades to a dropped batch inside
      // _TrendPointBuffer.flush's best-effort guard.
      await _trendBuffer?.flush();
    });
    return null;
  }

  /// Submit a regression run for [config].
  ///
  /// Steps:
  ///
  /// 1. Cancel any in-flight run.
  /// 2. Publish [config] to [activeConfigProvider] so the dashboard
  ///    can render suite / simulator filter chips.
  /// 3. Flatten every suite's tests into a [RegressionRequest].
  /// 4. Create a fresh [InMemoryResultStore] and publish it via
  ///    [resultStoreProvider] (the dashboard table consumes
  ///    `currentRun`).
  /// 5. Submit the request to the scheduler, listening to events:
  ///    record each [TestFinished] into both the in-memory store
  ///    (with suite/simulator metadata for the table's filter
  ///    indexes) and the [TrendStore] (for the trend view's
  ///    cross-run queries).
  /// 6. Mark `isFinished` on the final [RegressionFinished].
  ///
  /// [trigger] is telemetry-only: it names *what* asked for this run so
  /// `regression.completed` can answer whether auto-reload is used at all.
  /// Nothing in the scheduler reads it.
  Future<void> start(
    RegressionConfig config, {
    int concurrency = 4,
    RegressionTrigger trigger = RegressionTrigger.manual,
  }) async {
    final generation = ++_startGeneration;
    // Cancel any prior run before starting a new one.
    await cancel();
    if (_superseded(generation)) return;

    final tests = [
      for (final suite in config.suites) ...suite.tests,
    ];
    if (tests.isEmpty) {
      state = const AsyncData(null);
      return;
    }

    ref.read(activeConfigProvider.notifier).replace(config);
    // Register every spec we're about to submit with the
    // re-run-query inventory so Pro re-run dispatchers
    // (`Re-run failures` / `Re-run with seed N` / `Re-run group`)
    // can resolve specs by id without round-tripping through the
    // user's project file. Idempotent: re-submitting the same spec
    // overwrites the prior entry.
    ref.read(reRunQueryServiceProvider).trackSubmittedSpecs(tests);
    final runId = runIdFactory();
    _activeRunId = runId;
    final run = TestRun(
      id: runId,
      startedAt: DateTime.now().toUtc(),
      testIds: tests.map((t) => t.id).toList(),
    );
    final store = InMemoryResultStore.forRun(run);
    ref.read(resultStoreProvider.notifier).publish(store);
    state = AsyncData(
      RegressionRunState(run: run, isFinished: false),
    );

    // Resolve the trend store best-effort; the regression keeps
    // running even if SQLite fails to open (e.g. permission denied
    // in a sandboxed test) — trend persistence is a degraded but
    // non-fatal feature.
    TrendStore? trendStore;
    try {
      trendStore = await ref.read(trendStoreProvider.future);
    } on Object {
      trendStore = null;
    }
    if (_superseded(generation)) return;

    final scheduler = ref
        .read(jobSchedulerProvider)
        .schedulerFor(_withBinaryOverrides(config));
    _activeScheduler = scheduler;
    final specsById = <String, TestSpec>{
      for (final t in tests) t.id: t,
    };
    final request = RegressionRequest(
      runId: runId,
      tests: tests,
      concurrency: concurrency,
    );
    // Seed the statistics strip's job segments. The runner already sees
    // every scheduler event, so the strip observes rather than polls.
    ref
        .read(jobSchedulerStatsProvider.notifier)
        .runStarted(totalTests: tests.length, maxConcurrency: concurrency);
    _armTelemetryForRun(tests, trigger);

    _listenToRun(
      scheduler: scheduler,
      events: scheduler.submit(request),
      store: store,
      run: run,
      specsById: specsById,
      trendStore: trendStore,
    );
  }

  /// Folds the user's Settings → Simulators per-simulator binary-path
  /// overrides into [config] so a run actually honors them. Precedence:
  /// a project `simulators:` entry that names a binary (`source: custom`
  /// with a `path`) wins; otherwise a non-empty settings override is applied
  /// as a `custom`-source binary, keeping any `options:` and `env:` the
  /// project entry declares; otherwise the bare default the scheduler falls
  /// back to. Mirrors the mapping `simulatorVersionsProvider` uses for the
  /// diagnostics probe.
  ///
  /// An entry that only sets `options` (for example cocotb's `sim`) or
  /// `env` used to suppress the Settings path entirely, because any entry
  /// for the simulator counted as the project choosing its binary.
  RegressionConfig _withBinaryOverrides(RegressionConfig config) {
    final overrides =
        ref.read(appSettingsProvider).value?.simulatorBinaryOverrides ??
        const <String, String>{};
    if (overrides.isEmpty) return config;
    final merged = Map<String, SimulatorBinaryConfig>.of(
      config.simulatorBinaries,
    );
    var changed = false;
    overrides.forEach((id, path) {
      // An empty override is "no override".
      if (path.isEmpty) return;
      final declared = merged[id];
      // The project names its own binary: it wins.
      if (declared != null && declared.source == SimulatorBinarySource.custom) {
        return;
      }
      merged[id] = (declared ?? SimulatorBinaryConfig(simulatorId: id))
          .copyWith(source: SimulatorBinarySource.custom, customPath: path);
      changed = true;
    });
    return changed ? config.copyWith(simulatorBinaries: merged) : config;
  }

  /// Subscribes to a submitted run's event stream and threads every
  /// event into the in-memory store, the log buffers, the buffered
  /// trend writer, and the runner state. The single handler shared by
  /// [start] and [submitSpecs] — the two paths differ only in how the
  /// request is assembled, never in how events are consumed.
  void _listenToRun({
    required Stream<RegressionEvent> events,
    required InMemoryResultStore store,
    required TestRun run,
    required Map<String, TestSpec> specsById,
    required TrendStore? trendStore,
    required JobScheduler scheduler,
  }) {
    // Publish this run to the app-scoped registry so the app-exit path
    // can reap it — runs live in per-tab containers, so quitting must
    // reach runs the active tab cannot see.
    _releaseActiveRunToken();
    _activeRunToken = ref
        .read(activeRunRegistryProvider)
        .register(() => scheduler.cancel(run.id));
    final trendBuffer = trendStore == null
        ? null
        : _TrendPointBuffer(trendStore);
    _trendBuffer = trendBuffer;
    _activeStore = store;
    _activeTrendStore = trendStore;
    _subscription = events.listen(
      (event) async {
        switch (event) {
          case TestFinished(:final result):
            await _onResult(
              result: result,
              specsById: specsById,
              store: store,
              trendBuffer: trendBuffer,
            );
            _publishSchedulerStats(
              store: store,
              runtimeSeconds:
                  result.finishedAt
                      .difference(result.startedAt)
                      .inMilliseconds /
                  1000.0,
            );
          case RegressionFinished(:final cancelled):
            // First, before any of the awaits below: each of them is a place
            // this notifier can be disposed, and the counter must not be lost
            // to a tab the user closed while the retention prune ran. The
            // `_terminalRecordedRunId` guard makes this safe alongside
            // [cancel]'s own call.
            _recordRunTerminal(
              cancelled: cancelled,
              failed: _failureCount(store),
            );
            // Also before the first await: everything the housekeeping below
            // needs from `ref`. Closing the tab disposes this notifier, and
            // a read after that throws, which skipped the retention prune
            // and the completion hooks (the PR annotation of a run that had
            // finished) and surfaced as an uncaught error.
            final housekeeping = _resolveCompletionHousekeeping();
            await store.recordRunCompletion(
              RunSummary(
                runId: run.id,
                startedAt: run.startedAt,
                finishedAt: DateTime.now().toUtc(),
                totalsByStatus: const {},
                cancelled: cancelled,
              ),
            );
            // Land every buffered trend point before retention runs
            // (so the policy prunes over the complete run) and before
            // isFinished is published (so a finished run's sparklines
            // read the full history).
            _releaseActiveRunToken();
            await trendBuffer?.flush();
            // Stamp the run's finished_at now that its rows are landed, so
            // crash reconciliation on the next open does not false-positive
            // this completed run as interrupted (the GUI ingest path creates
            // run rows with a null finished_at). Best-effort: a failed stamp
            // only risks a spurious interrupted marker, never the run's
            // completion.
            try {
              await trendStore?.markRunFinished(run.id, DateTime.now().toUtc());
            } on Object {
              // Swallow: persistence of the finish stamp must not tear down
              // the in-memory regression's completion.
            }
            // Flip the strip's job segments to idle. The tallies stay
            // visible — after a two-hour regression the last thing a user
            // wants is the numbers vanishing the instant it completes.
            try {
              ref.read(jobSchedulerStatsProvider.notifier).runFinished();
            } on Object {
              // Ignore: peripheral readout.
            }
            await _applyRetentionBestEffort(trendStore, housekeeping);
            // Post-run side effects (PR-annotation auto-dispatch) run
            // after the store is closed and the trend points are landed,
            // so a hook sees the complete result set — and before the
            // state publish, so a hook that wants to surface a snackbar
            // is not racing the UI's "finished" rebuild.
            await _runCompletionHooksBestEffort(
              hooks: housekeeping.hooks,
              runId: run.id,
              store: store,
              cancelled: cancelled,
            );
            // The flush and the retention prune are both awaited, so
            // the tab (and this notifier) can be disposed while they
            // run — closing a project mid-run is the common case.
            // Assigning `state` after disposal throws.
            if (!ref.mounted) return;
            state = AsyncData(
              RegressionRunState(
                run: store.summary != null
                    ? run.copyWith(finishedAt: store.summary!.finishedAt)
                    : run,
                isFinished: true,
                cancelled: cancelled,
              ),
            );
          case TestLog(:final testId, :final line, :final fromStderr):
            store.logBufferStore
                .bufferFor(testId)
                .append(
                  line: line,
                  fromStderr: fromStderr,
                );
          case TestStarted():
            // The dashboard table needs nothing here (it listens to
            // ResultStore.currentRun), but the statistics strip's
            // "running / max" segment does — that is the number that
            // answers "is the pool saturated?".
            _publishSchedulerStats(store: store);
          case TestProgress():
            // No state update needed; the dashboard table re-emits on
            // each recordResult call.
            break;
        }
      },
      onError: (Object error) {
        _releaseActiveRunToken();
        if (!ref.mounted) return;
        state = AsyncError(error, StackTrace.current);
      },
    );
  }

  /// Removes this runner's entry from [activeRunRegistryProvider], if
  /// it still holds one. Idempotent.
  void _releaseActiveRunToken() {
    final token = _activeRunToken;
    if (token == null) return;
    _activeRunToken = null;
    _runRegistry?.unregister(token);
  }

  /// Pushes a scheduler snapshot to the statistics strip.
  ///
  /// Derived from the store rather than tracked separately so the strip and
  /// the dashboard can never disagree about how many tests have finished.
  /// Best-effort: an ambient monitor must never be able to break a run.
  void _publishSchedulerStats({
    required InMemoryResultStore store,
    double? runtimeSeconds,
  }) {
    try {
      final completed = store.results.length;
      final stats = ref.read(jobSchedulerStatsProvider);
      ref
          .read(jobSchedulerStatsProvider.notifier)
          .progress(
            runningTests: (stats.totalTests - completed).clamp(
              0,
              stats.maxConcurrency,
            ),
            completedTests: completed,
            runtimeSeconds: runtimeSeconds,
          );
    } on Object {
      // Ignore: the strip is a peripheral readout, not part of the run.
    }
  }

  /// Everything the completion housekeeping reads from `ref`, resolved
  /// while this notifier is still mounted.
  ///
  /// The [RegressionFinished] handler awaits the result store, the trend
  /// flush and the finish stamp before it prunes and runs the hooks, and the
  /// tab can be closed across any of those awaits. The run still finished,
  /// so its housekeeping still happens, on values read before the first one.
  _CompletionHousekeeping _resolveCompletionHousekeeping() => (
    policy: ref.read(retentionPolicyProvider),
    sweeper: ref.read(waveformRetentionSweeperProvider),
    hooks: ref.read(runCompletionHooksProvider),
  );

  /// Enforces the trend retention policy, then sweeps waveform artifacts,
  /// after a completed run, so trends.db stays bounded without an explicit
  /// user action.
  ///
  /// Best-effort like the per-result inserts in [_onResult]: a prune failure
  /// must never surface as a failed regression. The policy comes from
  /// [retentionPolicyProvider] (default 30 days / 50 000 points; the Pro
  /// Retention settings section edits the same notifier at runtime).
  ///
  /// Reads nothing from `ref`: [housekeeping] was resolved before the
  /// awaits that come ahead of this, any of which can outlive the tab.
  Future<void> _applyRetentionBestEffort(
    TrendStore? trendStore,
    _CompletionHousekeeping housekeeping,
  ) async {
    if (trendStore == null) return;
    final policy = housekeeping.policy;
    try {
      await trendStore.applyRetention(policy);
    } on Object {
      // Ignore: retention is housekeeping, not part of the run
      // contract.
    }
    // Waveform artifacts are swept separately and second. The row-count
    // policy bounds the database; the dumps are what actually fill a disk,
    // and sweeping after the prune means a run that just aged out of the
    // window takes its dump with it in the same pass.
    try {
      await housekeeping.sweeper.sweep(trendStore, policy);
    } on Object {
      // Ignore: same contract as above.
    }
  }

  /// Runs every registered [RunCompletionHook], isolating failures.
  ///
  /// Each hook is caught individually so one throwing hook cannot stop
  /// the rest, and the whole set is best-effort so none of them can tear
  /// down the run's completion. The results are the product; a
  /// PR-annotation post that 500s is not a reason to lose them.
  Future<void> _runCompletionHooksBestEffort({
    required List<RunCompletionHook> hooks,
    required String runId,
    required InMemoryResultStore store,
    required bool cancelled,
  }) async {
    if (hooks.isEmpty) return;
    final results = List<TestResult>.unmodifiable(store.results);
    final context = RunCompletionContext(
      runId: runId,
      results: results,
      // Paired with the spec metadata the result does not carry, so a hook
      // that writes a durable record of the run can name each test's suite
      // and simulator. Built here rather than left for a hook to invert the
      // store's reverse indexes, which would be the same work done less
      // safely in every hook that needs it.
      rows: <CompletedResult>[
        for (final result in results)
          CompletedResult(
            result: result,
            suiteName: store.suiteOf(result),
            simulatorId: store.simulatorOf(result),
          ),
      ],
      cancelled: cancelled,
    );
    for (final hook in hooks) {
      try {
        await hook(context);
      } on Object {
        // Ignore: a hook is an optional side effect, never part of the
        // run contract.
      }
    }
  }

  Future<void> _onResult({
    required TestResult result,
    required Map<String, TestSpec> specsById,
    required InMemoryResultStore store,
    required _TrendPointBuffer? trendBuffer,
  }) async {
    final spec = specsById[result.testId];
    if (spec != null) {
      await store.recordResultWithMetadata(
        result,
        suiteName: spec.suiteName,
        simulatorId: spec.simulatorId,
      );
      // `didExecute == false` is the *surfaced* form of
      // `SimulatorNotAvailableException` — see the field's own doc on
      // [TestResult], which names the exception. It also covers "no driver
      // registered for this simulator id", and both belong under
      // `engine.missing`: from the user's chair they are the same event ("the
      // engine I asked for is not usable on this machine"), and both are the
      // setup wall the counter exists to measure.
      //
      // Collected here, emitted once per engine at the run's end — see
      // [_missingEngines].
      if (!result.didExecute) {
        _missingEngines.add(simulatorTelemetryToken(spec.simulatorId));
      }
    } else {
      await store.recordResult(result);
    }
    // Shared-workspace producer: a run that captured a dump has
    // produced a `waveform` artifact — register it in the shared workspace,
    // keyed by the design its INPUT (`simcrux.yaml`) directory derives, so a
    // NetCrux → WaveCrux cross-probe naming the same design can resolve and
    // open this VCD even with nothing open. Keyed off the input dir, not the
    // VCD's output dir — that is the join key peers send. Best-effort and gated
    // on CXP running inside the helper.
    //
    // `ref.mounted` guard: `_onResult` runs across async gaps on the result
    // stream, and the per-tab runner may already have been disposed (tab
    // switch / rebuild) by the time a late result arrives. Reading a provider
    // off a disposed Ref throws — which would abort the whole result pipeline —
    // so skip the courtesy upsert once the notifier is gone.
    final waveformPath = result.waveformPath;
    if (ref.mounted && waveformPath != null && waveformPath.isNotEmpty) {
      final config = ref.read(activeConfigProvider);
      if (config != null) {
        unawaited(
          publishWaveformWorkspaceArtifact(
            ref,
            designId: cxpDesignIdForPath(config.projectFilePath),
            waveformPath: waveformPath,
            topModule: spec?.top,
          ),
        );
      }
    }
    // Queue (don't insert): the buffer flushes batches through
    // recordTrendPoints — one transaction / fsync / dataChanged tick
    // per batch instead of per finished test. See [_TrendPointBuffer].
    //
    // Runs that never launched the toolchain (binary not found / no driver
    // registered) are skipped: a "broken infra" outcome is not a data point
    // about the test's behavior, and recording it would pollute the
    // flakiness window (the Pro scorer counts a not-found `iverilog` as a
    // fail). The dashboard row still shows the failure — only the trend
    // store is spared.
    if (result.didExecute) {
      trendBuffer?.add(
        TrendPoint(
          runId: result.runId,
          testId: result.testId,
          status: result.status,
          runtime: result.runtime,
          startedAt: result.startedAt,
          // Carried so the waveform retention sweep can find this dump once
          // the run ages out; without it `maxWaveformRuns` sweeps nothing.
          waveformPath: waveformPath,
          // Carried so the per-suite trend view can find this result; the
          // store has no other source for the suite.
          suiteName: spec?.suiteName,
        ),
      );
    }
  }

  /// Submit a partial regression consisting of [specs] only,
  /// reusing the active [RegressionConfig]'s scheduler and the
  /// active result store / trend store.
  ///
  /// This is the dashboard's submission path for Pro re-run
  /// dispatchers ("Re-run failures only", "Re-run with seed N",
  /// "Re-run all in this parameter group"). The active
  /// [RegressionConfig] (set by [start] when the user opened the
  /// project) provides the `simulators:` block and project file
  /// path that the scheduler needs; only the test list differs.
  ///
  /// Behavior parallels [start]:
  ///
  /// - cancels any in-flight run before submitting,
  /// - leaves [activeConfigProvider] unchanged (we are running a
  ///   subset of the active project's tests, not opening a new
  ///   project),
  /// - registers [specs] with the [reRunQueryServiceProvider]
  ///   inventory so subsequent re-runs of these specs resolve,
  /// - creates a fresh [InMemoryResultStore] for this re-run so
  ///   the dashboard shows only the targeted specs (a re-run of
  ///   3 failed tests should not look like a 1000-test run),
  /// - threads results into the [TrendStore] for cross-run
  ///   queries.
  ///
  /// Returns immediately when [specs] is empty (no run is
  /// dispatched and the runner state is left untouched) or when
  /// there is no active config (silent no-op — the caller is
  /// responsible for surfacing a "open a project first" message
  /// where applicable; in practice the Pro UI gates the re-run
  /// affordances on `activeConfigProvider != null` already).
  Future<void> submitSpecs(
    List<TestSpec> specs, {
    int concurrency = 4,
    RegressionTrigger trigger = RegressionTrigger.manual,
  }) async {
    if (specs.isEmpty) return;
    final config = ref.read(activeConfigProvider);
    if (config == null) return;

    final generation = ++_startGeneration;
    await cancel();
    if (_superseded(generation)) return;
    ref.read(reRunQueryServiceProvider).trackSubmittedSpecs(specs);

    final runId = runIdFactory();
    _activeRunId = runId;
    final run = TestRun(
      id: runId,
      startedAt: DateTime.now().toUtc(),
      testIds: specs.map((t) => t.id).toList(),
    );
    final store = InMemoryResultStore.forRun(run);
    ref.read(resultStoreProvider.notifier).publish(store);
    state = AsyncData(
      RegressionRunState(run: run, isFinished: false),
    );

    TrendStore? trendStore;
    try {
      trendStore = await ref.read(trendStoreProvider.future);
    } on Object {
      trendStore = null;
    }
    if (_superseded(generation)) return;

    final scheduler = ref
        .read(jobSchedulerProvider)
        .schedulerFor(_withBinaryOverrides(config));
    _activeScheduler = scheduler;
    final specsById = <String, TestSpec>{
      for (final t in specs) t.id: t,
    };
    final request = RegressionRequest(
      runId: runId,
      tests: specs,
      concurrency: concurrency,
    );
    _armTelemetryForRun(specs, trigger);

    _listenToRun(
      scheduler: scheduler,
      events: scheduler.submit(request),
      store: store,
      run: run,
      specsById: specsById,
      trendStore: trendStore,
    );
  }

  /// Publishes [config] without submitting anything — the tab is
  /// **armed**, not running.
  ///
  /// This is what opening a regression config does by default. The
  /// dashboard, test browser and file watcher all key off
  /// [activeConfigProvider], so arming lights up the whole tab; only
  /// the scheduler is left idle until the user presses Run.
  ///
  /// The distinction is a product decision, not an implementation
  /// detail: opening a file must not launch two hundred
  /// tests, because in a real setup that also checks out simulator
  /// licences on a misclick. [SimcruxSettingsCodec] persists the
  /// opt-in as `simcrux.autoRunOnOpen`, default off.
  void arm(RegressionConfig config) {
    ref.read(activeConfigProvider.notifier).replace(config);
    // No run, so no run state. `null` is the same state the tab is in
    // after a run is cleared, which is exactly what "armed" means to
    // every consumer of this notifier.
    state = const AsyncData(null);
  }

  /// Convenience wrapper: load the config at [projectPath] via the
  /// active [configLoaderProvider], then either [start] the regression
  /// or merely [arm] the tab, per [autoStart].
  ///
  /// Used by both the CLI bootstrap (when the user passes a project
  /// file as a positional argument) and the File → Open Project menu
  /// action. Errors during config load are surfaced as
  /// [AsyncError] on this notifier's state either way — a config that
  /// will not parse is worth reporting whether or not a run was going
  /// to follow.
  ///
  /// [autoStart] defaults to `true` so the two explicit "run this"
  /// call sites keep reading plainly; the *open* path passes the user's
  /// `autoRunOnOpen` preference, which is off by default.
  Future<void> startFromConfigPath(
    String projectPath, {
    int concurrency = 4,
    bool autoStart = true,
    RegressionTrigger trigger = RegressionTrigger.manual,
  }) async {
    state = const AsyncLoading();
    try {
      final loader = ref.read(configLoaderProvider);
      final config = await loader.load(projectPath);
      // The load is awaited, so the tab (and this notifier) can be disposed
      // while it runs — closing the tab right after an auto-reload fired, or
      // during a slow load off a network share. Reading a provider or
      // assigning `state` after disposal throws (same guard as the run
      // subscription's completion path above).
      if (!ref.mounted) return;
      // Clear any prior load-error state so a re-open (or auto-reload
      // after the user fixed the YAML) wipes the diagnostic banner.
      ref.read(configLoadErrorProvider.notifier).clear();
      if (autoStart) {
        await start(config, concurrency: concurrency, trigger: trigger);
      } else {
        arm(config);
      }
    } on Object catch (e, st) {
      // A load that failed *because* the tab went away has nothing to report
      // to — and both the error record and the state assignment below would
      // throw on a disposed notifier.
      if (!ref.mounted) return;
      // Record the load failure so [regression_tab_content.dart] can
      // render a specific "Couldn't load <path>: <reason>" message
      // instead of falling through to the generic empty-state copy.
      ref
          .read(configLoadErrorProvider.notifier)
          .record(
            ConfigLoadError(path: projectPath, message: e.toString()),
          );
      state = AsyncError(e, st);
    }
  }

  /// Arms the per-run telemetry context for the specs about to be submitted.
  ///
  /// Everything the terminal counter needs is derived **here**, at submit
  /// time, and none of it survives past the run: the engine tokens, the spec
  /// count, the detector kinds, the trigger. Deriving them at the end instead
  /// would mean reaching for the spec list from a path that may run after the
  /// notifier is disposed.
  ///
  /// Note what is derived and what is not. `specs.length` is a count.
  /// `simulatorId` and the `pass_fail` variant are app vocabulary, folded to
  /// closed tokens by [regressionSimulatorToken] and
  /// [passFailDetectorKindTokens]. The test ids, suite names, source paths and
  /// seeds sitting in the same [TestSpec] objects are none of our business:
  /// telemetry never carries design data.
  void _armTelemetryForRun(List<TestSpec> specs, RegressionTrigger trigger) {
    _terminalRecordedRunId = null;
    _missingEngines.clear();
    _activeTrigger = trigger;
    _activeTestCount = specs.length;
    _activeSimulator = regressionSimulatorToken(
      specs.map((spec) => spec.simulatorId),
    );
    _activeDetectorKinds = <String>{
      for (final spec in specs) ...passFailDetectorKindTokens(spec.passFail),
    };
    // The AUDIT event for the start of a run, on the same seam the telemetry
    // arming uses. Unlike the telemetry counters this is not bucketed: an
    // administrator reconciling a night of CI wants the actual test count and
    // the run id, not a coarse band — `telemetryCount` exists to keep an
    // aggregate metric's cardinality down, and this is not an aggregate
    // metric, it is the organization's record of its own machine.
    ref
        .read(cruxAuditRecorderProvider)
        .record(
          SimCruxAuditKinds.regressionStarted,
          payload: <String, Object?>{
            'runId': _activeRunId,
            'trigger': trigger.name,
            'tests': specs.length,
            'simulator': _activeSimulator,
          },
        );
    // `simulator.invoked` is recorded here rather than per test. The runner
    // dispatches one simulator process per test, and a thousand-test suite
    // would put a thousand identical lines into a file an administrator reads
    // — the same volume argument that keeps `detector.matched` per run per
    // kind. What the registered kind is for is "which simulator ran against
    // our RTL", and that is answered once per run.
    if (_activeSimulator case final String simulator) {
      ref
          .read(cruxAuditRecorderProvider)
          .record(
            SimCruxAuditKinds.simulatorInvoked,
            payload: <String, Object?>{
              'runId': _activeRunId,
              'simulator': simulator,
              'tests': specs.length,
            },
          );
    }
  }

  /// Records the one terminal counter this run gets, and the detector kinds
  /// that ran alongside it.
  ///
  /// **`detector.matched` is emitted once per run per distinct kind, not once
  /// per test.** The registry dispatches per test, and a thousand-test suite
  /// would put a thousand identical events into a queue capped at two thousand
  /// — evicting every other counter the session recorded before any of them
  /// reached a flush. Per run per kind answers the question the counter
  /// exists for ("is anyone using the UVM detector?") at a thousandth of the volume,
  /// and the vocabulary still comes from the registry's own dispatch switch.
  ///
  /// Idempotent per run id: [cancel] and the `RegressionFinished` event are
  /// two paths to one ending, and a race between them must not double-count.
  void _recordRunTerminal({required bool cancelled, int failed = 0}) {
    final runId = _activeRunId;
    if (runId == null || runId == _terminalRecordedRunId) return;
    _terminalRecordedRunId = runId;
    // Recorded before the telemetry early-return below: telemetry can be
    // absent (unconsented, or a headless host that never armed it) and the
    // audit trail must not inherit that gate. They are different services with
    // different consent stories — telemetry is ours and needs permission,
    // the audit log is the organization's own record of its own machine.
    ref
        .read(cruxAuditRecorderProvider)
        .record(
          SimCruxAuditKinds.regressionFinished,
          payload: <String, Object?>{
            'runId': runId,
            'outcome': cancelled ? 'cancelled' : 'completed',
            'tests': _activeTestCount,
            'failed': cancelled ? null : failed,
            'simulator': _activeSimulator,
          },
        );

    final telemetry = _telemetry;
    if (telemetry == null) return;

    if (cancelled) {
      // No properties: "how often do people kill a runaway run" is a rate, and
      // the size / engine of the run they killed is not part of the question.
      telemetry.record(TelemetryEvent('regression.cancelled'));
    } else {
      telemetry.record(
        TelemetryEvent(
          'regression.completed',
          properties: <String, Object?>{
            'simulator': ?_activeSimulator,
            'trigger': telemetryEnumToken(_activeTrigger),
            'tests': telemetryCount(_activeTestCount),
            'failed': telemetryCount(failed),
          },
        ),
      );
    }
    for (final kind in _activeDetectorKinds) {
      telemetry.record(
        TelemetryEvent(
          'detector.matched',
          properties: <String, Object?>{'kind': kind},
        ),
      );
    }
    for (final simulator in _missingEngines) {
      telemetry.record(
        TelemetryEvent(
          'engine.missing',
          properties: <String, Object?>{'simulator': simulator},
        ),
      );
    }
  }

  /// The `failed` count for `regression.completed`.
  ///
  /// Deliberately the **same** tally the `--fail-threshold` gate uses under
  /// its default policy ([CiRunResult.failuresIn]) — `fail` + `timeout` +
  /// `unknown` — so "how red is this run" means the same thing in the counter
  /// as it does in the exit code. `vacuous` is excluded here for the same
  /// reason it is opt-in there: a vacuous pass is a coverage question, not a
  /// failure.
  int _failureCount(InMemoryResultStore store) {
    final totals = <TestStatus, int>{};
    for (final result in store.results) {
      totals[result.status] = (totals[result.status] ?? 0) + 1;
    }
    return CiRunResult.failuresIn(totals, failOnVacuous: false);
  }

  /// Cancel the in-flight run, if any.
  Future<void> cancel() async {
    final runId = _activeRunId;
    if (runId == null) return;
    // Before the teardown below, which cancels the subscription and so
    // guarantees this notifier will never see the scheduler's own
    // `RegressionFinished(cancelled: true)`. The `_terminalRecordedRunId`
    // guard makes the two paths safe to both exist.
    _recordRunTerminal(cancelled: true);
    // Cancel on the exact instance the run was submitted to (pinned at
    // submit time), never a re-resolution through the LRU cache.
    final scheduler = _activeScheduler;
    if (scheduler != null) {
      await scheduler.cancel(runId);
    }
    await _subscription?.cancel();
    _subscription = null;
    _activeRunId = null;
    _activeScheduler = null;
    // Release the app-exit registry token here. Its other release sites
    // ride RegressionFinished, which a cancelled subscription may never
    // observe (the subscription is cancelled just above) — so without
    // this a cancelled run would leave a stale canceller in the registry
    // that the quit path later invokes against torn-down state, and the
    // registry would report an in-flight run when none exists.
    _releaseActiveRunToken();
    // A cancelled subscription may never observe RegressionFinished —
    // land whatever trend points were buffered so a cancelled run's
    // completed tests still show up in cross-run history.
    await _trendBuffer?.flush();
    _trendBuffer = null;
    await _closeOutCancelledRun(runId);
  }

  /// Does for a cancelled run what the [RegressionFinished] handler does for
  /// one that ran to the end.
  ///
  /// The scheduler emits `RegressionFinished(cancelled: true)` only after its
  /// retention prune, by which time [cancel] has cancelled the subscription.
  /// Nothing then marked the run finished: the tab read it as in flight for
  /// the rest of its life, so Run and Re-run stayed disabled, Cancel did
  /// nothing, the status bar kept spinning, the result store never received
  /// its summary, and the next open marked the run interrupted.
  Future<void> _closeOutCancelledRun(String runId) async {
    final store = _activeStore;
    final trendStore = _activeTrendStore;
    _activeStore = null;
    _activeTrendStore = null;
    final current = state.value;
    final run = current?.run;
    // Only a run still in flight. [start] cancels whatever came before it,
    // and a run that already finished must keep the finish its own
    // [RegressionFinished] recorded.
    if (current == null || run == null || run.id != runId) return;
    if (current.isFinished) return;
    final finishedAt = DateTime.now().toUtc();
    await store?.recordRunCompletion(
      RunSummary(
        runId: runId,
        startedAt: run.startedAt,
        finishedAt: finishedAt,
        totalsByStatus: const {},
        cancelled: true,
      ),
    );
    try {
      await trendStore?.markRunFinished(runId, finishedAt);
    } on Object {
      // Swallow, as the finished path does: a failed stamp only risks a
      // spurious interrupted marker on the next open.
    }
    if (!ref.mounted) return;
    try {
      ref.read(jobSchedulerStatsProvider.notifier).runFinished();
    } on Object {
      // Ignore: peripheral readout.
    }
    state = AsyncData(
      RegressionRunState(
        run: run.copyWith(finishedAt: finishedAt),
        isFinished: true,
        cancelled: true,
      ),
    );
  }
}
