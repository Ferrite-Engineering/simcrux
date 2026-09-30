// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/interfaces/job_scheduler.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/regression_request.dart';
import 'package:simcrux/domain/models/resource_lock.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/suite.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/job_scheduler/job_scheduler_provider.dart';

class _StubScheduler implements JobScheduler {
  @override
  Map<String, ResourceLock> get heldLocks => const {};

  @override
  RegressionStatus statusOf(String runId) => RegressionStatus(
    runId: runId,
    totalTests: 0,
    completedTests: 0,
    runningTests: 0,
    isFinished: true,
  );

  @override
  Stream<RegressionEvent> submit(RegressionRequest request) =>
      const Stream<RegressionEvent>.empty();

  @override
  Future<void> cancel(String runId) async {}
}

RegressionConfig _config({
  Map<String, SimulatorBinaryConfig> binaries = const {},
  List<TestSpec> tests = const <TestSpec>[],
}) => RegressionConfig(
  projectFilePath: '/p/simcrux.yaml',
  schemaVersion: '1',
  suites: <Suite>[Suite(name: 'unit', tests: tests)],
  simulatorBinaries: binaries,
);

TestSpec _spec(String name) => TestSpec(
  id: 'unit/$name',
  name: name,
  suiteName: 'unit',
  simulatorId: 'icarus',
  top: name,
);

void main() {
  group('JobSchedulerCache', () {
    test('returns the same scheduler for the same simulator config', () {
      var builds = 0;
      final cache = JobSchedulerCache((_) {
        builds++;
        return _StubScheduler();
      });

      final first = cache.schedulerFor(_config());
      final second = cache.schedulerFor(_config());

      expect(identical(first, second), isTrue);
      expect(builds, 1);
    });

    test(
      'editing tests (not simulators) reuses the scheduler, so an '
      'in-flight run stays cancellable',
      () {
        // The old Provider.family keyed on the whole RegressionConfig:
        // every keystroke in the config editor minted a new, permanently
        // retained scheduler — and routed `cancel(runId)` to a fresh
        // instance that had never heard of the run.
        var builds = 0;
        final cache = JobSchedulerCache((_) {
          builds++;
          return _StubScheduler();
        });

        final before = cache.schedulerFor(_config(tests: [_spec('a')]));
        final after = cache.schedulerFor(
          _config(tests: [_spec('a'), _spec('b')]),
        );

        expect(identical(before, after), isTrue);
        expect(builds, 1);
        expect(cache.size, 1);
      },
    );

    test('a changed simulator binary config yields a new scheduler', () {
      final cache = JobSchedulerCache((_) => _StubScheduler());

      final system = cache.schedulerFor(
        _config(
          binaries: {
            'icarus': const SimulatorBinaryConfig(simulatorId: 'icarus'),
          },
        ),
      );
      final custom = cache.schedulerFor(
        _config(
          binaries: {
            'icarus': const SimulatorBinaryConfig(
              simulatorId: 'icarus',
              customPath: '/opt/iverilog/bin/vvp',
            ),
          },
        ),
      );

      expect(identical(system, custom), isFalse);
      expect(cache.size, 2);
    });

    test('retention is bounded by kJobSchedulerCacheSize', () {
      final cache = JobSchedulerCache((_) => _StubScheduler());

      for (var i = 0; i < kJobSchedulerCacheSize + 3; i++) {
        cache.schedulerFor(
          _config(
            binaries: {
              'icarus': SimulatorBinaryConfig(
                simulatorId: 'icarus',
                customPath: '/opt/build-$i/vvp',
              ),
            },
          ),
        );
      }

      expect(cache.size, kJobSchedulerCacheSize);
    });

    test('reuse refreshes LRU position so the hot entry survives', () {
      final cache = JobSchedulerCache((_) => _StubScheduler());
      RegressionConfig configFor(int i) => _config(
        binaries: {
          'icarus': SimulatorBinaryConfig(
            simulatorId: 'icarus',
            customPath: '/opt/build-$i/vvp',
          ),
        },
      );

      final hot = cache.schedulerFor(configFor(0));
      for (var i = 1; i < kJobSchedulerCacheSize; i++) {
        cache
          ..schedulerFor(configFor(i))
          // Touch the hot entry so it is never the least-recently-used.
          ..schedulerFor(configFor(0));
      }
      cache.schedulerFor(configFor(99));

      expect(
        identical(cache.schedulerFor(configFor(0)), hot),
        isTrue,
        reason: 'the repeatedly-used scheduler must not be evicted',
      );
      expect(cache.size, kJobSchedulerCacheSize);
    });
  });
}
