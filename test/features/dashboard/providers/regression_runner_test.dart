// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/hdl_language.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/interfaces/trend_store.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/retention_policy.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/suite.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/domain/models/trend_aggregate.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/dashboard/providers/regression_runner.dart';
import 'package:simcrux/features/inspector/providers/test_trend_provider.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/settings/providers/retention_policy_provider.dart';
import 'package:simcrux/services/job_scheduler/job_scheduler_provider.dart';
import 'package:simcrux/services/lifecycle/app_exit_provider.dart';
import 'package:simcrux/services/lifecycle/run_completion_hooks.dart';
import 'package:simcrux/services/re_run_query/re_run_query_service.dart';
import 'package:simcrux/services/re_run_query/re_run_query_service_provider.dart';
import 'package:simcrux/services/result_store/in_memory_result_store.dart';
import 'package:simcrux/services/result_store/result_store_provider.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';
import 'package:simcrux/services/trend_store/trend_store_provider.dart';

import '../../../support/answered_telemetry.dart';
import '../../../support/poll_until.dart';

/// Tiny fake driver — every test exits 0 unless its id ends in `/fail`.
class _FakeDriver implements SimulatorDriver {
  @override
  String get id => 'icarus';

  @override
  String get displayName => 'Fake';

  @override
  SimulatorCapabilities get capabilities => SimulatorCapabilities(
    supportedLanguages: const {HdlLanguage.verilog},
    supportsVcd: false,
    supportsFst: false,
    supportsCocotb: false,
    requiresSeparateCompileStep: false,
    emitsStructuredOutput: false,
  );

  @override
  Future<String?> detectVersion(SimulatorBinaryConfig config) async => 'fake';

  @override
  Future<CompileResult> compile(CompileRequest request) async {
    return const CompileResult(
      success: true,
      artifactPath: 'noop',
      stdout: '',
      stderr: '',
    );
  }

  @override
  Stream<TestExecutionEvent> execute(ExecuteRequest request) async* {
    final started = DateTime.now().toUtc();
    final exitCode = request.test.id.endsWith('/fail') ? 1 : 0;
    yield TestExecutionFinished(
      status: exitCode == 0 ? TestStatus.pass : TestStatus.fail,
      exitCode: exitCode,
      startedAt: started,
      finishedAt: DateTime.now().toUtc(),
    );
  }

  @override
  void cancel(String testId) {}
}

TestSpec _spec(String id) {
  return TestSpec(
    id: id,
    name: id.split('/').last,
    suiteName: id.split('/').first,
    simulatorId: 'icarus',
    top: 'tb',
  );
}

RegressionConfig _config(List<TestSpec> tests) {
  final byId = <String, List<TestSpec>>{};
  for (final t in tests) {
    byId.putIfAbsent(t.suiteName, () => <TestSpec>[]).add(t);
  }
  return RegressionConfig(
    projectFilePath: '/proj/simcrux.yaml',
    schemaVersion: '1',
    suites: [
      for (final entry in byId.entries)
        Suite(name: entry.key, tests: entry.value),
    ],
    simulatorBinaries: const {},
  );
}

/// Driver whose tests never finish on their own, so a run stays
/// in-flight until it is cancelled. Records the ids it was told to
/// cancel, which is how the test observes whether `cancel()` reached
/// the scheduler actually holding the run.
class _BlockingDriver implements SimulatorDriver {
  final List<String> cancelled = <String>[];
  final Map<String, Completer<void>> _gates = <String, Completer<void>>{};

  @override
  String get id => 'icarus';

  @override
  String get displayName => 'Blocking';

  @override
  SimulatorCapabilities get capabilities => SimulatorCapabilities(
    supportedLanguages: const {HdlLanguage.verilog},
    supportsVcd: false,
    supportsFst: false,
    supportsCocotb: false,
    requiresSeparateCompileStep: false,
    emitsStructuredOutput: false,
  );

  @override
  Future<String?> detectVersion(SimulatorBinaryConfig config) async => 'fake';

  @override
  Future<CompileResult> compile(CompileRequest request) async {
    return const CompileResult(
      success: true,
      artifactPath: 'noop',
      stdout: '',
      stderr: '',
    );
  }

  @override
  Stream<TestExecutionEvent> execute(ExecuteRequest request) async* {
    final gate = _gates.putIfAbsent(
      request.test.id,
      Completer<void>.new,
    );
    await gate.future;
    yield TestExecutionFinished(
      status: TestStatus.unknown,
      exitCode: -1,
      startedAt: DateTime.now().toUtc(),
      finishedAt: DateTime.now().toUtc(),
    );
  }

  @override
  void cancel(String testId) {
    cancelled.add(testId);
    _gates[testId]?.complete();
  }
}

/// A [_BlockingDriver] that counts every execution it was handed.
class _CountingBlockingDriver extends _BlockingDriver {
  int executions = 0;

  @override
  Stream<TestExecutionEvent> execute(ExecuteRequest request) {
    executions++;
    return super.execute(request);
  }

  /// Two overlapping starts can each cancel the same test.
  @override
  void cancel(String testId) {
    cancelled.add(testId);
    final gate = _gates[testId];
    if (gate != null && !gate.isCompleted) gate.complete();
  }
}

/// A trend store whose finish stamp waits for [releaseStamp], so a test can
/// hold a finished run's handler at its last await before the retention
/// prune. Records every prune it is asked for.
class _StampGatedTrendStore extends TrendStore {
  final Completer<void> stampEntered = Completer<void>();
  final Completer<void> releaseStamp = Completer<void>();
  final List<RetentionPolicy> retentionPolicies = <RetentionPolicy>[];

  @override
  Future<void> recordTrendPoint(TrendPoint point) async {}

  @override
  Future<void> markRunFinished(String runId, DateTime finishedAt) async {
    if (!stampEntered.isCompleted) stampEntered.complete();
    await releaseStamp.future;
  }

  @override
  Future<int> applyRetention(RetentionPolicy policy) async {
    retentionPolicies.add(policy);
    return 0;
  }

  @override
  Stream<TrendPoint> recentTrend(String testId, {int limit = 10}) =>
      const Stream<TrendPoint>.empty();

  @override
  Stream<TrendDelta> recentDeltas({int limit = 10}) =>
      const Stream<TrendDelta>.empty();
}

/// A config whose `simulators:` block carries [signature], so each
/// distinct value keys a distinct entry in the scheduler LRU cache.
RegressionConfig _configWithSignature(
  List<TestSpec> tests,
  String signature,
) {
  final base = _config(tests);
  return base.copyWith(
    simulatorBinaries: <String, SimulatorBinaryConfig>{
      'icarus': SimulatorBinaryConfig(
        simulatorId: 'icarus',
        source: SimulatorBinarySource.custom,
        customPath: signature,
      ),
    },
  );
}

void main() {
  late Directory tmp;
  late ProviderContainer container;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('simcrux_runner_test_');
    container = ProviderContainer(
      overrides: [
        ...answeredTelemetryOverrides(),
        simulatorDriverRegistryProvider.overrideWithValue(
          SimulatorDriverRegistry({'icarus': _FakeDriver()}),
        ),
        trendStoreDirectoryOverrideProvider.overrideWithValue(tmp.path),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    if (tmp.existsSync()) {
      try {
        tmp.deleteSync(recursive: true);
      } on Object {
        // Best-effort cleanup.
      }
    }
  });

  Future<RegressionRunState?> waitForFinish() async {
    final completer = Completer<RegressionRunState?>();
    container.listen<AsyncValue<RegressionRunState?>>(
      regressionRunnerProvider,
      (_, next) {
        final value = next.value;
        if (value != null && value.isFinished && !completer.isCompleted) {
          completer.complete(value);
        }
      },
    );
    return await completer.future;
  }

  group('RegressionRunner.start', () {
    test(
      'drives a happy-path config to TestFinished + RegressionFinished',
      () async {
        final config = _config([_spec('unit/alu'), _spec('unit/regfile')]);
        final runner = container.read(regressionRunnerProvider.notifier);
        await runner.start(config);
        final finished = await waitForFinish();
        expect(finished, isNotNull);
        expect(finished!.isFinished, isTrue);
        expect(finished.cancelled, isFalse);
        expect(finished.run.testIds, ['unit/alu', 'unit/regfile']);
      },
    );

    test(
      'registers the run with activeRunRegistryProvider and releases it '
      'on completion',
      () async {
        // The app-exit path reaps runs through this registry. A run that
        // never registers is a run that quitting silently orphans.
        final registry = container.read(activeRunRegistryProvider);
        expect(registry.hasActiveRuns, isFalse);

        final config = _config([_spec('unit/alu')]);
        final runner = container.read(regressionRunnerProvider.notifier);
        await runner.start(config);

        expect(
          registry.activeCount,
          1,
          reason: 'an in-flight run must be visible to the exit path',
        );

        await waitForFinish();

        expect(
          registry.hasActiveRuns,
          isFalse,
          reason: 'a finished run must not leave a stale canceller behind',
        );
      },
    );

    test('publishes the config to activeConfigProvider', () async {
      final config = _config([_spec('unit/alu')]);
      final runner = container.read(regressionRunnerProvider.notifier);
      await runner.start(config);
      await waitForFinish();
      expect(
        container.read(activeConfigProvider)?.projectFilePath,
        '/proj/simcrux.yaml',
      );
    });

    test('no tests → state becomes AsyncData(null)', () async {
      final config = _config(const []);
      final runner = container.read(regressionRunnerProvider.notifier);
      await runner.start(config);
      expect(container.read(regressionRunnerProvider).value, isNull);
    });

    test('registers submitted specs with reRunQueryServiceProvider', () async {
      final config = _config([_spec('unit/alu'), _spec('unit/regfile')]);
      final runner = container.read(regressionRunnerProvider.notifier);
      await runner.start(config);
      await waitForFinish();
      final service =
          container.read(reRunQueryServiceProvider) as DefaultReRunQueryService;
      expect(
        service.trackedSpecs.keys,
        containsAll(['unit/alu', 'unit/regfile']),
      );
    });

    test(
      'trend persistence is batched: a run of many tests lands every '
      'point but emits far fewer dataChanged events than tests',
      () async {
        const testCount = 30;
        // Subscribe to dataChanged before the run so every emission is
        // observed. The store must be resolved first for that.
        final store = await container.read(trendStoreProvider.future);
        var dataChangedEvents = 0;
        final sub = store.dataChanged.listen((_) => dataChangedEvents++);
        addTearDown(sub.cancel);

        final config = _config([
          for (var i = 0; i < testCount; i++) _spec('unit/t$i'),
        ]);
        final runner = container.read(regressionRunnerProvider.notifier);
        await runner.start(config);
        await waitForFinish();
        await Future<void>.delayed(Duration.zero);

        // Every point persisted…
        final stats = await store.storageStats();
        expect(stats.dataPointCount, testCount);
        // …but through batched recordTrendPoints flushes (threshold /
        // timer / run-final), not one transaction + notification per
        // finished test. Reverting to per-result recordTrendPoint makes
        // this ≥ testCount.
        expect(
          dataChangedEvents,
          allOf(greaterThan(0), lessThan(10)),
          reason:
              '$testCount tests must coalesce into a handful of batched '
              'flushes; saw $dataChangedEvents dataChanged events',
        );
      },
    );

    test(
      'each trend point carries its suite, so the per-suite view of the '
      'local store finds the run with no team database configured',
      () async {
        // The runner is one of the store's two producers. It used to record
        // every point with an empty suite, which left the per-suite trend
        // view empty on every seat whose history lives in the local store.
        final config = _config([
          _spec('unit/alu'),
          _spec('unit/regfile'),
          _spec('soc/boot'),
        ]);
        final runner = container.read(regressionRunnerProvider.notifier);
        await runner.start(config);
        await waitForFinish();
        await Future<void>.delayed(Duration.zero);
        final store = await container.read(trendStoreProvider.future);
        expect((await store.storageStats()).dataPointCount, 3);

        Future<int> runsIn(String suite) async {
          final buckets = await store.queryAggregates(
            key: TrendAggregateKey.perSuite(suite),
            bucketSize: const Duration(days: 1),
          );
          return buckets.fold<int>(0, (sum, b) => sum + b.totalRuns);
        }

        expect(await runsIn('unit'), 2);
        expect(await runsIn('soc'), 1);
      },
    );

    test(
      're-running the same test records a fresh trend point and '
      'invalidates testTrendProvider so the inspector sees the new point',
      () async {
        final config = _config([_spec('unit/alu')]);
        final runner = container.read(regressionRunnerProvider.notifier);

        // First run.
        await runner.start(config);
        await waitForFinish();

        // Verify a trend point landed in the store. Read directly
        // rather than via testTrendProvider so the assertion does
        // not interact with the provider's own caching semantics.
        final store = await container.read(trendStoreProvider.future);
        final pointsAfterFirst = <TestStatus>[];
        await for (final p in store.recentTrend('unit/alu')) {
          pointsAfterFirst.add(p.status);
        }
        expect(pointsAfterFirst, hasLength(1));

        // Spy on `testTrendProvider('unit/alu')` so we can observe
        // the invalidation triggered by the second run's _onResult.
        // The provider is a FutureProvider.family — without the
        // invalidation in _onResult, subsequent reads return the
        // cached single-entry list.
        final emitted = <int>[];
        final sub = container.listen<AsyncValue<List<TestStatus>>>(
          testTrendProvider('unit/alu'),
          (_, next) {
            if (next.hasValue) emitted.add(next.value!.length);
          },
          fireImmediately: true,
        );
        addTearDown(sub.close);

        // Second run.
        await runner.start(config);
        await waitForFinish();
        // Wait for the post-_onResult invalidation to re-fetch and
        // re-emit to the listener.
        await pollUntil(() => emitted.contains(2));

        // We must have seen at least one emission with the new
        // 2-entry list — proves the provider was invalidated after
        // the trend point landed.
        expect(
          emitted.contains(2),
          isTrue,
          reason: 'Saw emissions $emitted; expected one of length 2',
        );

        // And the underlying store should have both points.
        final pointsAfterSecond = <TestStatus>[];
        await for (final p in store.recentTrend('unit/alu')) {
          pointsAfterSecond.add(p.status);
        }
        expect(pointsAfterSecond, hasLength(2));
      },
    );
  });

  group('Settings > Simulators binary path', () {
    /// Runs one icarus test under [yamlBinaries] with a Settings override
    /// of `/opt/settings/iverilog`, returning the binary config the driver
    /// was handed.
    Future<SimulatorBinaryConfig> binaryUsed(
      Map<String, SimulatorBinaryConfig> yamlBinaries,
    ) async {
      final driver = _BinaryRecordingDriver();
      final local = ProviderContainer(
        overrides: [
          ...answeredTelemetryOverrides(),
          simulatorDriverRegistryProvider.overrideWithValue(
            SimulatorDriverRegistry({'icarus': driver}),
          ),
          trendStoreDirectoryOverrideProvider.overrideWithValue(tmp.path),
          appSettingsProvider.overrideWith(
            () => _FixedSettingsNotifier(
              const AppSettings(
                simulatorBinaryOverrides: {'icarus': '/opt/settings/iverilog'},
              ),
            ),
          ),
        ],
      );
      addTearDown(local.dispose);
      await local.read(appSettingsProvider.future);
      final config = _config([
        _spec('unit/alu'),
      ]).copyWith(simulatorBinaries: yamlBinaries);
      final finished = Completer<void>();
      local.listen<AsyncValue<RegressionRunState?>>(
        regressionRunnerProvider,
        (_, next) {
          if ((next.value?.isFinished ?? false) && !finished.isCompleted) {
            finished.complete();
          }
        },
      );
      await local.read(regressionRunnerProvider.notifier).start(config);
      await finished.future;
      return driver.seen.single;
    }

    test('applies when the project has no entry for the simulator', () async {
      final used = await binaryUsed(const {});
      expect(used.source, SimulatorBinarySource.custom);
      expect(used.customPath, '/opt/settings/iverilog');
    });

    test('still applies when the project entry only sets options or env, and '
        'keeps them', () async {
      final used = await binaryUsed(const {
        'icarus': SimulatorBinaryConfig(
          simulatorId: 'icarus',
          options: {'sim': 'x'},
          extraEnv: {'LM_LICENSE_FILE': '2100@lic'},
        ),
      });
      expect(used.source, SimulatorBinarySource.custom);
      expect(used.customPath, '/opt/settings/iverilog');
      expect(used.options, {'sim': 'x'});
      expect(used.extraEnv, {'LM_LICENSE_FILE': '2100@lic'});
    });

    test('loses to a project entry that names its own binary', () async {
      final used = await binaryUsed(const {
        'icarus': SimulatorBinaryConfig(
          simulatorId: 'icarus',
          source: SimulatorBinarySource.custom,
          customPath: '/opt/project/iverilog',
        ),
      });
      expect(used.customPath, '/opt/project/iverilog');
    });
  });

  group('RegressionRunner.submitSpecs', () {
    test('no-op when specs list is empty (state untouched)', () async {
      final runner = container.read(regressionRunnerProvider.notifier);
      await runner.submitSpecs(const []);
      expect(container.read(regressionRunnerProvider).value, isNull);
    });

    test('no-op when no active config (no project open)', () async {
      final runner = container.read(regressionRunnerProvider.notifier);
      await runner.submitSpecs([_spec('unit/alu')]);
      expect(container.read(regressionRunnerProvider).value, isNull);
    });

    test(
      'submits subset against active config, leaves activeConfig unchanged',
      () async {
        final config = _config([_spec('unit/alu'), _spec('unit/fail')]);
        final runner = container.read(regressionRunnerProvider.notifier);
        await runner.start(config);
        await waitForFinish();
        // Now re-submit just the one failing spec.
        await runner.submitSpecs([_spec('unit/fail')]);
        // Wait for the re-run to finish; reuse waitForFinish which
        // resets via container.listen.
        final finished = await waitForFinish();
        expect(finished, isNotNull);
        expect(finished!.run.testIds, ['unit/fail']);
        // activeConfig retains the original 2-test project.
        final active = container.read(activeConfigProvider)!;
        expect(active.suites.expand((s) => s.tests).length, 2);
      },
    );

    test('tracks re-submitted specs in reRunQueryServiceProvider', () async {
      final config = _config([_spec('unit/alu')]);
      final runner = container.read(regressionRunnerProvider.notifier);
      await runner.start(config);
      await waitForFinish();
      // Re-submit a different spec id; the service inventory should grow.
      await runner.submitSpecs([_spec('unit/beta')]);
      await waitForFinish();
      final service =
          container.read(reRunQueryServiceProvider) as DefaultReRunQueryService;
      expect(service.trackedSpecs.keys, containsAll(['unit/alu', 'unit/beta']));
    });
  });

  group('RegressionRunner retention enforcement', () {
    test(
      'applies retentionPolicyProvider against the trend store after '
      'every completed run — ingestion past the policy horizon prunes',
      () async {
        // Policy retains a single data point. The 3-test run ingests 3
        // points; the post-run retention pass must prune down to 1.
        container
            .read(retentionPolicyProvider.notifier)
            .replace(const RetentionPolicy(maxDataPoints: 1));
        final config = _config([
          _spec('unit/alu'),
          _spec('unit/regfile'),
          _spec('unit/decoder'),
        ]);
        final runner = container.read(regressionRunnerProvider.notifier);
        await runner.start(config);
        await waitForFinish();
        final store = await container.read(trendStoreProvider.future);
        final stats = await store.storageStats();
        expect(stats.dataPointCount, 1);
      },
    );

    test('unlimited policy leaves every ingested point in place', () async {
      container
          .read(retentionPolicyProvider.notifier)
          .replace(RetentionPolicy.unlimited);
      final config = _config([_spec('unit/alu'), _spec('unit/regfile')]);
      final runner = container.read(regressionRunnerProvider.notifier);
      await runner.start(config);
      await waitForFinish();
      final store = await container.read(trendStoreProvider.future);
      final stats = await store.storageStats();
      expect(stats.dataPointCount, 2);
      // storageStats reflects reality: both points came from one run.
      expect(stats.runCount, 1);
    });
  });

  group('cancel reaches the scheduler holding the run', () {
    test(
      'an LRU eviction between start and cancel does not strand the run',
      () async {
        final driver = _BlockingDriver();
        final local = ProviderContainer(
          overrides: [
            ...answeredTelemetryOverrides(),
            simulatorDriverRegistryProvider.overrideWithValue(
              SimulatorDriverRegistry({'icarus': driver}),
            ),
            trendStoreDirectoryOverrideProvider.overrideWithValue(tmp.path),
          ],
        );
        addTearDown(local.dispose);

        final config = _configWithSignature([_spec('unit/alu')], '/bin/sim0');
        local.read(activeConfigProvider.notifier).replace(config);
        unawaited(local.read(regressionRunnerProvider.notifier).start(config));

        // Let the run reach the driver.
        await pollUntil(() => driver._gates.containsKey('unit/alu'));

        // Evict this run's scheduler: the cache holds
        // `kJobSchedulerCacheSize` entries, so resolving that many
        // further DISTINCT simulator signatures pushes it out.
        final cache = local.read(jobSchedulerProvider);
        for (var i = 1; i <= kJobSchedulerCacheSize; i++) {
          cache.schedulerFor(
            _configWithSignature([_spec('unit/alu')], '/bin/sim$i'),
          );
        }

        expect(
          cache.size,
          kJobSchedulerCacheSize,
          reason: "the run's scheduler must actually have been evicted",
        );

        await local.read(regressionRunnerProvider.notifier).cancel();

        expect(
          driver.cancelled,
          contains('unit/alu'),
          reason:
              'Cancelling a run must tear down its simulator processes '
              "even after the LRU cache has evicted that run's "
              'scheduler. Teardown rides the event-stream subscription, '
              'whose onCancel closes over the owning _RunState, so it is '
              'instance-correct regardless of eviction; the explicit '
              'JobScheduler.cancel is belt-and-braces and reaches the '
              'pinned instance rather than a rebuilt, empty one.',
        );
      },
    );

    test(
      'cancel releases the ActiveRunToken (release does not ride '
      'RegressionFinished, which a cancelled sub never delivers)',
      () async {
        final driver = _BlockingDriver();
        final local = ProviderContainer(
          overrides: [
            ...answeredTelemetryOverrides(),
            simulatorDriverRegistryProvider.overrideWithValue(
              SimulatorDriverRegistry({'icarus': driver}),
            ),
            trendStoreDirectoryOverrideProvider.overrideWithValue(tmp.path),
          ],
        );
        addTearDown(local.dispose);
        final registry = local.read(activeRunRegistryProvider);

        final config = _configWithSignature([_spec('unit/alu')], '/bin/sim0');
        local.read(activeConfigProvider.notifier).replace(config);
        unawaited(local.read(regressionRunnerProvider.notifier).start(config));
        await pollUntil(() => driver._gates.containsKey('unit/alu'));
        expect(
          registry.activeCount,
          1,
          reason: 'the in-flight run is registered for the exit path',
        );

        await local.read(regressionRunnerProvider.notifier).cancel();

        expect(
          registry.hasActiveRuns,
          isFalse,
          reason:
              'cancel must release the token — otherwise a stale canceller '
              'lingers and the exit path invokes it against a dead run',
        );
      },
    );

    test('two starts that overlap run one regression, not two', () async {
      // Auto-reload reruns once per changed file, so saving two sources at
      // once fires two starts. Each cancelled the run in flight, and both
      // then went on to submit a regression of their own.
      final driver = _CountingBlockingDriver();
      final local = ProviderContainer(
        overrides: [
          ...answeredTelemetryOverrides(),
          simulatorDriverRegistryProvider.overrideWithValue(
            SimulatorDriverRegistry({'icarus': driver}),
          ),
          trendStoreDirectoryOverrideProvider.overrideWithValue(tmp.path),
        ],
      );
      addTearDown(local.dispose);
      final config = _configWithSignature([_spec('unit/alu')], '/bin/sim0');
      local.read(activeConfigProvider.notifier).replace(config);
      final runner = local.read(regressionRunnerProvider.notifier);
      var runs = 0;
      runner.runIdFactory = () => 'run-${++runs}';
      unawaited(runner.start(config));
      await pollUntil(() => driver.executions == 1);

      await Future.wait([runner.start(config), runner.start(config)]);
      await pollUntil(() => driver.executions >= 2);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(driver.executions, 2, reason: 'the first run, then one rerun');
      expect(runs, 2, reason: 'the superseded start never minted a run');
      // The first run's cancel already opened the shared gate, so the rerun
      // runs to its end by itself. Wait for its completion handler to
      // publish, which is its last step, so teardown never disposes the
      // runner under it. Cancelling here instead raced that handler.
      await pollUntil(() {
        final state = local.read(regressionRunnerProvider).value;
        return state?.run.id == 'run-2' && state!.isFinished;
      });
    });

    test('a cancelled run is finished, not left in flight', () async {
      // The run's terminal state rode RegressionFinished, which the
      // subscription cancel() tears down never delivers. The tab then read
      // the run as in flight for good: Run and Re-run stayed disabled and
      // the status bar spun.
      final driver = _BlockingDriver();
      final local = ProviderContainer(
        overrides: [
          ...answeredTelemetryOverrides(),
          simulatorDriverRegistryProvider.overrideWithValue(
            SimulatorDriverRegistry({'icarus': driver}),
          ),
          trendStoreDirectoryOverrideProvider.overrideWithValue(tmp.path),
        ],
      );
      addTearDown(local.dispose);

      final config = _configWithSignature([_spec('unit/alu')], '/bin/sim0');
      local.read(activeConfigProvider.notifier).replace(config);
      unawaited(local.read(regressionRunnerProvider.notifier).start(config));
      await pollUntil(() => driver._gates.containsKey('unit/alu'));
      final store = local.read(resultStoreProvider)! as InMemoryResultStore;

      await local.read(regressionRunnerProvider.notifier).cancel();

      final state = local.read(regressionRunnerProvider).value!;
      expect(state.isFinished, isTrue);
      expect(state.cancelled, isTrue);
      expect(state.run.finishedAt, isNotNull);
      expect(store.summary?.cancelled, isTrue);
    });
  });

  group('a tab closed while its finished run is tidying up', () {
    // The RegressionFinished handler awaits the result store, the trend
    // flush and the finish stamp before it prunes and runs the completion
    // hooks, and closing the tab disposes the runner across any of them. The
    // prune then read the retention policy from the disposed ref and threw:
    // no prune, no completion hooks (the PR annotation of a run that had
    // finished), and an uncaught error. The trend store holds the handler at
    // its finish stamp, so the tab always closes exactly there.
    test('still prunes and runs the hooks, and throws nothing', () async {
      final trends = _StampGatedTrendStore();
      final hookRuns = <String>[];
      final local = ProviderContainer(
        overrides: [
          ...answeredTelemetryOverrides(),
          simulatorDriverRegistryProvider.overrideWithValue(
            SimulatorDriverRegistry({'icarus': _FakeDriver()}),
          ),
          trendStoreProvider.overrideWith((ref) async => trends),
          runCompletionHooksProvider.overrideWithValue(<RunCompletionHook>[
            (context) async => hookRuns.add(context.runId),
          ]),
        ],
      );
      final config = _config([_spec('unit/alu')]);
      local.read(activeConfigProvider.notifier).replace(config);
      final runner = local.read(regressionRunnerProvider.notifier)
        ..runIdFactory = () => 'run-1';
      await runner.start(config);
      await trends.stampEntered.future;

      // The tab closes while the finished run is inside its finish stamp.
      local.dispose();
      trends.releaseStamp.complete();
      await pumpEventQueue();

      expect(
        trends.retentionPolicies,
        hasLength(1),
        reason: 'the run finished, so its retention prune still happens',
      );
      expect(
        hookRuns,
        ['run-1'],
        reason: 'a completed run still gets its completion hooks',
      );
    });
  });
}

/// Driver that records the binary config each execute was handed.
class _BinaryRecordingDriver extends _FakeDriver {
  final List<SimulatorBinaryConfig> seen = <SimulatorBinaryConfig>[];

  @override
  Stream<TestExecutionEvent> execute(ExecuteRequest request) {
    seen.add(request.binaryConfig);
    return super.execute(request);
  }
}

/// Settings notifier that resolves to fixed [AppSettings].
class _FixedSettingsNotifier extends AppSettingsNotifier {
  _FixedSettingsNotifier(this._settings);

  final AppSettings _settings;

  @override
  Future<AppSettings> build() async => _settings;
}
