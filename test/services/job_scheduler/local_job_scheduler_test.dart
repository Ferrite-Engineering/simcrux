// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// The test-side fake-driver lifecycle is intentionally fire-and-forget:
// `script.start()` runs on a microtask while the scheduler consumes the
// stream it produces, and `controller.done.whenComplete(...)` is a
// completion callback (no result to await). The cascade_invocations
// suppression keeps the per-test fake-driver setup readable without
// rewriting onDone-then-start into a cascade across a nullable function
// type. Both lints are by design here.
// ignore_for_file: discarded_futures, cascade_invocations

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/hdl_language.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/job_scheduler.dart';
import 'package:simcrux/domain/interfaces/retry_policy.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/regression_request.dart';
import 'package:simcrux/domain/models/resource_lock.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/job_scheduler/local_job_scheduler.dart';
import 'package:simcrux/services/job_scheduler/simulator_budget.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';

import '../../support/poll_until.dart';

/// Scripted fake [SimulatorDriver] for scheduler tests. The fake's
/// per-test behavior is controlled by a [_DriverScript] returned from
/// a builder so each test can vary the timeline (lines, exit code,
/// hang-forever).
class _FakeDriver implements SimulatorDriver {
  _FakeDriver({
    required this.id,
    required this.scriptFor,
  });

  @override
  final String id;

  final _DriverScript Function(String testId) scriptFor;

  /// Running script controllers keyed by testId, so cancel() can
  /// terminate them.
  final Map<String, _DriverScript> live = <String, _DriverScript>{};

  /// Test ids that have been cancelled (for assertions).
  final Set<String> cancelled = <String>{};

  /// Optional probe invoked on every [execute] call. Used by the
  /// retry-policy tests to inspect the per-attempt [ExecuteRequest]
  /// (in particular `request.test.seed`) without mucking with the
  /// script construction path.
  void Function(ExecuteRequest)? spyOnRequest;

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
  Stream<TestExecutionEvent> execute(ExecuteRequest request) {
    spyOnRequest?.call(request);
    final script = scriptFor(request.test.id);
    live[request.test.id] = script;
    script.onDone = () => live.remove(request.test.id);
    script.start();
    return script.controller.stream;
  }

  @override
  void cancel(String testId) {
    cancelled.add(testId);
    live[testId]?.cancel();
  }
}

/// Controls one [_FakeDriver.execute] timeline.
class _DriverScript {
  _DriverScript({
    this.stdoutLines = const <String>[],
    this.stderrLines = const <String>[],
    this.exit = 0,
    this.startDelay = Duration.zero,
    this.hangForever = false,
  });

  final List<String> stdoutLines;
  final List<String> stderrLines;
  final int exit;
  final Duration startDelay;
  final bool hangForever;

  final StreamController<TestExecutionEvent> controller =
      StreamController<TestExecutionEvent>();

  bool _cancelled = false;
  void Function()? onDone;

  Future<void> start() async {
    if (startDelay > Duration.zero) {
      await Future<void>.delayed(startDelay);
    }
    final started = DateTime.now().toUtc();
    for (final line in stdoutLines) {
      if (_cancelled) break;
      controller.add(
        TestLogLine(
          line: line,
          fromStderr: false,
          timestamp: DateTime.now().toUtc(),
        ),
      );
    }
    for (final line in stderrLines) {
      if (_cancelled) break;
      controller.add(
        TestLogLine(
          line: line,
          fromStderr: true,
          timestamp: DateTime.now().toUtc(),
        ),
      );
    }
    if (hangForever && !_cancelled) {
      // Wait until cancel() flips the flag.
      while (!_cancelled) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
    final status = _cancelled ? TestStatus.cancelled : _classify(exit);
    controller.add(
      TestExecutionFinished(
        status: status,
        exitCode: _cancelled ? -15 : exit,
        startedAt: started,
        finishedAt: DateTime.now().toUtc(),
      ),
    );
    await controller.close();
    onDone?.call();
  }

  void cancel() {
    _cancelled = true;
  }

  TestStatus _classify(int code) =>
      code == 0 ? TestStatus.pass : TestStatus.fail;
}

TestSpec spec(
  String id, {
  String simulatorId = 'fake',
  String top = 'tb',
  Duration timeout = const Duration(seconds: 30),
  List<ResourceLock> resources = const <ResourceLock>[],
}) {
  return TestSpec(
    id: id,
    name: id.split('/').last,
    suiteName: id.split('/').first,
    simulatorId: simulatorId,
    top: top,
    timeout: timeout,
    resources: resources,
  );
}

RegressionConfig _emptyConfig() => RegressionConfig(
  projectFilePath: '/fake/simcrux.yaml',
  schemaVersion: '1',
  suites: const [],
  simulatorBinaries: const {},
);

LocalJobScheduler _scheduler({
  required _FakeDriver driver,
  String? runRoot,
  SimulatorBudget? budget,
}) {
  return LocalJobScheduler(
    driverRegistry: SimulatorDriverRegistry({driver.id: driver}),
    config: _emptyConfig(),
    runRoot: runRoot,
    budget: budget,
  );
}

void main() {
  group('LocalJobScheduler — lifecycle', () {
    test('passes / fails are classified from driver exit codes', () async {
      final driver = _FakeDriver(
        id: 'fake',
        scriptFor: (id) => _DriverScript(exit: id.endsWith('a') ? 0 : 1),
      );
      final scheduler = _scheduler(driver: driver);
      final events = await scheduler
          .submit(
            RegressionRequest(
              runId: 'r1',
              tests: <TestSpec>[spec('s/a'), spec('s/b')],
            ),
          )
          .toList();

      final finished = events.whereType<TestFinished>().toList();
      expect(finished, hasLength(2));
      final byId = {for (final f in finished) f.result.testId: f.result};
      expect(byId['s/a']!.status, TestStatus.pass);
      expect(byId['s/b']!.status, TestStatus.fail);
      expect(events.last, isA<RegressionFinished>());
    });

    test('emits TestStarted / TestLog / TestFinished in order', () async {
      final driver = _FakeDriver(
        id: 'fake',
        scriptFor: (_) => _DriverScript(stdoutLines: const ['hello']),
      );
      final scheduler = _scheduler(driver: driver);
      final events = await scheduler
          .submit(
            RegressionRequest(runId: 'r1', tests: <TestSpec>[spec('s/a')]),
          )
          .toList();

      expect(events.first, isA<TestStarted>());
      expect(events.whereType<TestLog>(), isNotEmpty);
      expect(events.whereType<TestFinished>(), hasLength(1));
      expect(events.last, isA<RegressionFinished>());
    });

    test('reports stderr lines with fromStderr=true', () async {
      final driver = _FakeDriver(
        id: 'fake',
        scriptFor: (_) => _DriverScript(
          stderrLines: const ['boom'],
          exit: 1,
        ),
      );
      final scheduler = _scheduler(driver: driver);
      final events = await scheduler
          .submit(
            RegressionRequest(runId: 'r1', tests: <TestSpec>[spec('s/a')]),
          )
          .toList();
      final stderrLogs = events
          .whereType<TestLog>()
          .where((e) => e.fromStderr)
          .toList();
      expect(stderrLogs, isNotEmpty);
      expect(stderrLogs.first.line, equals('boom'));
    });

    test(
      'RegressionFinished marks cancelled=false on natural completion',
      () async {
        final driver = _FakeDriver(
          id: 'fake',
          scriptFor: (_) => _DriverScript(),
        );
        final scheduler = _scheduler(driver: driver);
        final events = await scheduler
            .submit(
              RegressionRequest(runId: 'r1', tests: <TestSpec>[spec('s/a')]),
            )
            .toList();
        final finished = events.last as RegressionFinished;
        expect(finished.cancelled, isFalse);
      },
    );

    test(
      'unknown simulatorId yields a failure-finished event without crashing',
      () async {
        final driver = _FakeDriver(
          id: 'fake',
          scriptFor: (_) => _DriverScript(),
        );
        final scheduler = _scheduler(driver: driver);
        final events = await scheduler
            .submit(
              RegressionRequest(
                runId: 'r1',
                tests: <TestSpec>[
                  spec('s/a', simulatorId: 'no-such-driver'),
                ],
              ),
            )
            .toList();
        final result = events.whereType<TestFinished>().single.result;
        expect(result.status, TestStatus.unknown);
        expect(result.failureMessage, contains('No simulator driver'));
      },
    );

    test(
      'propagates the expanded spec parentSpecId + boundParameters onto '
      'the result',
      () async {
        final driver = _FakeDriver(
          id: 'fake',
          scriptFor: (_) => _DriverScript(),
        );
        final scheduler = _scheduler(driver: driver);
        // A concrete child as the TestSpecExpander would emit it: a
        // synthesized id, the parent id in parentSpecId, one bound sweep
        // slice in parameters, and the pinned seed.
        final child = TestSpec(
          id: 's/alu+WIDTH=16+seed=7',
          name: 'alu',
          suiteName: 's',
          simulatorId: 'fake',
          top: 'tb',
          parameters: const {'WIDTH': '16'},
          seed: 7,
          parentSpecId: 's/alu',
        );
        final events = await scheduler
            .submit(
              RegressionRequest(runId: 'r1', tests: <TestSpec>[child]),
            )
            .toList();
        final result = events.whereType<TestFinished>().single.result;
        expect(result.parentSpecId, 's/alu');
        expect(result.boundParameters, {'WIDTH': '16'});
        expect(result.executionSeed, 7);
      },
    );

    test('non-parameterized spec yields a null parentSpecId / '
        'boundParameters', () async {
      final driver = _FakeDriver(
        id: 'fake',
        scriptFor: (_) => _DriverScript(),
      );
      final scheduler = _scheduler(driver: driver);
      final events = await scheduler
          .submit(
            RegressionRequest(runId: 'r1', tests: <TestSpec>[spec('s/a')]),
          )
          .toList();
      final result = events.whereType<TestFinished>().single.result;
      expect(result.parentSpecId, isNull);
      expect(result.boundParameters, isNull);
    });
  });

  group('LocalJobScheduler — what a failed test leaves behind', () {
    late Directory root;
    setUp(() {
      root = Directory.systemTemp.createTempSync('simcrux_sched_logs_');
    });
    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('a failing test keeps its captured output as files and the result '
        'points at them; a passing test keeps nothing', () async {
      final driver = _FakeDriver(
        id: 'fake',
        scriptFor: (id) => id.endsWith('bad')
            ? _DriverScript(
                stdoutLines: const ['starting', 'ERROR: tb.sv:12: bad parity'],
                stderrLines: const ['vvp: 1 error'],
                exit: 1,
              )
            : _DriverScript(stdoutLines: const ['TEST PASSED']),
      );
      final scheduler = _scheduler(driver: driver, runRoot: root.path);
      final events = await scheduler
          .submit(
            RegressionRequest(
              runId: 'r1',
              tests: <TestSpec>[spec('s/good'), spec('s/bad')],
            ),
          )
          .toList();
      final results = {
        for (final e in events.whereType<TestFinished>())
          e.result.testId: e.result,
      };

      final bad = results['s/bad']!;
      expect(bad.status, TestStatus.fail);
      expect(bad.stdoutPath, endsWith('sim_stdout.log'));
      expect(bad.stderrPath, endsWith('sim_stderr.log'));
      expect(
        File(bad.stdoutPath!).readAsStringSync(),
        contains('ERROR: tb.sv:12: bad parity'),
      );
      expect(File(bad.stderrPath!).readAsStringSync(), contains('1 error'));
      // The driver gave no message; the first line that says why is it.
      expect(bad.failureMessage, 'ERROR: tb.sv:12: bad parity');

      final good = results['s/good']!;
      expect(good.status, TestStatus.pass);
      expect(good.stdoutPath, isNull, reason: 'its work dir was swept');
      expect(good.stderrPath, isNull);
      expect(good.failureMessage, isNull);
    });

    test(
      'a failure with no recognisable reason keeps a null message',
      () async {
        final driver = _FakeDriver(
          id: 'fake',
          scriptFor: (_) => _DriverScript(
            stdoutLines: const ['ran 12 cycles', 'done'],
            exit: 3,
          ),
        );
        final scheduler = _scheduler(driver: driver, runRoot: root.path);
        final events = await scheduler
            .submit(
              RegressionRequest(runId: 'r1', tests: <TestSpec>[spec('s/t')]),
            )
            .toList();
        final result = events.whereType<TestFinished>().single.result;
        expect(result.status, TestStatus.fail);
        expect(result.failureMessage, isNull);
        expect(result.stdoutPath, isNotNull);
      },
    );
  });

  group('LocalJobScheduler — concurrency', () {
    test('bounds parallel runs by RegressionRequest.concurrency', () async {
      var inFlight = 0;
      var peak = 0;
      final driver = _FakeDriver(
        id: 'fake',
        scriptFor: (_) {
          // Each script bumps the in-flight gauge on start and
          // delays before completion so we can observe the peak.
          inFlight++;
          if (inFlight > peak) peak = inFlight;
          final script = _DriverScript(
            startDelay: const Duration(milliseconds: 10),
          );
          // Decrement when the script completes via onDone hook.
          // _FakeDriver.live tracks lifecycle; piggyback on close.
          script.controller.done.whenComplete(() => inFlight--);
          return script;
        },
      );
      final scheduler = _scheduler(driver: driver);
      final tests = List.generate(8, (i) => spec('s/t$i'));
      await scheduler
          .submit(
            RegressionRequest(
              runId: 'r1',
              tests: tests,
              concurrency: 2,
            ),
          )
          .toList();
      expect(peak, lessThanOrEqualTo(2));
    });

    test('two runs share the process-wide budget, each still under its own '
        'concurrency', () async {
      // Two tabs, each a regression with concurrency 4, used to mean eight
      // simulators at once. With a budget of 3 shared between them the sum
      // never passes 3, and nothing is lost: every test still runs.
      var inFlight = 0;
      var peak = 0;
      _FakeDriver driverFor(String id) => _FakeDriver(
        id: id,
        scriptFor: (_) {
          inFlight++;
          if (inFlight > peak) peak = inFlight;
          final script = _DriverScript(
            startDelay: const Duration(milliseconds: 10),
          );
          script.controller.done.whenComplete(() => inFlight--);
          return script;
        },
      );
      final budget = SimulatorBudget(limit: 3);
      final a = _scheduler(driver: driverFor('fake'), budget: budget);
      final b = _scheduler(driver: driverFor('fake'), budget: budget);
      final runs = await Future.wait([
        a
            .submit(
              RegressionRequest(
                runId: 'tab-a',
                tests: List.generate(8, (i) => spec('a/t$i')),
                concurrency: 4,
              ),
            )
            .toList(),
        b
            .submit(
              RegressionRequest(
                runId: 'tab-b',
                tests: List.generate(8, (i) => spec('b/t$i')),
                concurrency: 4,
              ),
            )
            .toList(),
      ]);
      expect(peak, lessThanOrEqualTo(3));
      expect(peak, greaterThan(1), reason: 'the budget is shared, not serial');
      for (final events in runs) {
        expect(events.whereType<TestFinished>(), hasLength(8));
      }
      expect(budget.inUse, 0, reason: 'every permit returned');
    });

    test(
      'a run under the budget still cannot exceed its own concurrency',
      () async {
        var inFlight = 0;
        var peak = 0;
        final driver = _FakeDriver(
          id: 'fake',
          scriptFor: (_) {
            inFlight++;
            if (inFlight > peak) peak = inFlight;
            final script = _DriverScript(
              startDelay: const Duration(milliseconds: 10),
            );
            script.controller.done.whenComplete(() => inFlight--);
            return script;
          },
        );
        final scheduler = _scheduler(
          driver: driver,
          budget: SimulatorBudget(limit: 16),
        );
        await scheduler
            .submit(
              RegressionRequest(
                runId: 'r1',
                tests: List.generate(8, (i) => spec('s/t$i')),
                concurrency: 2,
              ),
            )
            .toList();
        expect(peak, lessThanOrEqualTo(2));
      },
    );
  });

  group('LocalJobScheduler — cancel', () {
    test('cancel() drives driver.cancel and finishes the run', () async {
      final driver = _FakeDriver(
        id: 'fake',
        scriptFor: (_) => _DriverScript(hangForever: true),
      );
      final scheduler = _scheduler(driver: driver);
      final events = <RegressionEvent>[];
      final completer = Completer<void>();
      final subscription = scheduler
          .submit(
            RegressionRequest(
              runId: 'r1',
              tests: <TestSpec>[spec('s/a')],
            ),
          )
          .listen(events.add, onDone: completer.complete);
      final started = await pollUntil(
        () => events.whereType<TestStarted>().isNotEmpty,
      );
      expect(started, isTrue, reason: 'expected the test to start');
      await scheduler.cancel('r1');
      await completer.future;
      await subscription.cancel();
      final finished = events.last as RegressionFinished;
      expect(finished.cancelled, isTrue);
      expect(driver.cancelled, contains('s/a'));
    });
  });

  group('LocalJobScheduler — timeout', () {
    test('hung test is cancelled at timeout and reported as timeout', () async {
      final driver = _FakeDriver(
        id: 'fake',
        scriptFor: (_) => _DriverScript(hangForever: true),
      );
      final scheduler = _scheduler(driver: driver);
      final events = await scheduler
          .submit(
            RegressionRequest(
              runId: 'r1',
              tests: <TestSpec>[
                spec('s/a', timeout: const Duration(milliseconds: 50)),
              ],
            ),
          )
          .toList();
      final result = events.whereType<TestFinished>().single.result;
      expect(result.status, TestStatus.timeout);
      expect(driver.cancelled, contains('s/a'));
    });
  });

  group('LocalJobScheduler — resource locks', () {
    test('tests sharing a lock run strictly serially', () async {
      var concurrent = 0;
      var peak = 0;
      final driver = _FakeDriver(
        id: 'fake',
        scriptFor: (_) {
          concurrent++;
          if (concurrent > peak) peak = concurrent;
          final script = _DriverScript(
            startDelay: const Duration(milliseconds: 20),
          );
          script.controller.done.whenComplete(() => concurrent--);
          return script;
        },
      );
      final scheduler = _scheduler(driver: driver);
      const lock = ResourceLock(name: 'fpga_board_0');
      final tests = List.generate(
        4,
        (i) => spec('s/t$i', resources: const <ResourceLock>[lock]),
      );
      await scheduler
          .submit(
            RegressionRequest(
              runId: 'r1',
              tests: tests,
              concurrency: 4,
            ),
          )
          .toList();
      expect(peak, equals(1));
    });
  });

  group('LocalJobScheduler — status snapshot', () {
    test('statusOf returns finished snapshot for unknown runId', () {
      final driver = _FakeDriver(
        id: 'fake',
        scriptFor: (_) => _DriverScript(),
      );
      final scheduler = _scheduler(driver: driver);
      final s = scheduler.statusOf('nonexistent');
      expect(s.isFinished, isTrue);
      expect(s.totalTests, equals(0));
    });
  });

  group('LocalJobScheduler — RetryPolicy', () {
    test('default NoopRetryPolicy emits no retries on failure', () async {
      var attempts = 0;
      final driver = _FakeDriver(
        id: 'fake',
        scriptFor: (_) {
          attempts++;
          return _DriverScript(exit: 1);
        },
      );
      final scheduler = _scheduler(driver: driver);
      final events = await scheduler
          .submit(
            RegressionRequest(runId: 'r1', tests: <TestSpec>[spec('s/a')]),
          )
          .toList();
      // Only one TestFinished — the original — and the script was
      // invoked exactly once.
      expect(events.whereType<TestFinished>(), hasLength(1));
      expect(attempts, 1);
    });

    test('policy returning true reruns until first pass', () async {
      // Fake driver: first invocation fails (exit 1), second passes
      // (exit 0). The retry policy returns true for any failure within
      // the attempt cap.
      var attempts = 0;
      final driver = _FakeDriver(
        id: 'fake',
        scriptFor: (_) {
          attempts++;
          return _DriverScript(exit: attempts == 1 ? 1 : 0);
        },
      );
      final scheduler = LocalJobScheduler(
        driverRegistry: SimulatorDriverRegistry({driver.id: driver}),
        config: _emptyConfig(),
        retryPolicy: _AlwaysRetry(),
      );
      final events = await scheduler
          .submit(
            RegressionRequest(runId: 'r1', tests: <TestSpec>[spec('s/a')]),
          )
          .toList();
      final finished = events.whereType<TestFinished>().toList();
      // Final emission is the passing retry, not the original failure.
      expect(finished, hasLength(1));
      expect(finished.single.result.status, TestStatus.pass);
      expect(attempts, 2);
    });

    test('scheduler-side ceiling caps runaway policies', () async {
      var attempts = 0;
      final driver = _FakeDriver(
        id: 'fake',
        scriptFor: (_) {
          attempts++;
          return _DriverScript(exit: 1);
        },
      );
      final scheduler = LocalJobScheduler(
        driverRegistry: SimulatorDriverRegistry({driver.id: driver}),
        config: _emptyConfig(),
        retryPolicy: _AlwaysRetry(), // policy never gives up
        maxRetryCeiling: 3,
      );
      await scheduler
          .submit(
            RegressionRequest(runId: 'r1', tests: <TestSpec>[spec('s/a')]),
          )
          .toList();
      expect(attempts, 3);
    });

    test(
      'nextSeedFor result is propagated to the next attempt via spec.seed',
      () async {
        final seenSeeds = <int?>[];
        final driver = _FakeDriver(
          id: 'fake',
          scriptFor: (_) => _DriverScript(exit: 1),
        );
        driver.spyOnRequest = (req) => seenSeeds.add(req.test.seed);
        final scheduler = LocalJobScheduler(
          driverRegistry: SimulatorDriverRegistry({driver.id: driver}),
          config: _emptyConfig(),
          retryPolicy: _SeedSpoofingRetry(seeds: const [111, 222]),
        );
        await scheduler
            .submit(
              RegressionRequest(runId: 'r1', tests: <TestSpec>[spec('s/a')]),
            )
            .toList();
        // Original attempt sees null (spec didn't pin a seed); first
        // retry sees 111; second retry sees 222. After that the policy
        // returns false (it ran out of seeds) and the loop stops.
        expect(seenSeeds, equals(<int?>[null, 111, 222]));
      },
    );

    test('passing tests do not consult the policy', () async {
      var consultations = 0;
      final driver = _FakeDriver(
        id: 'fake',
        scriptFor: (_) => _DriverScript(),
      );
      final scheduler = LocalJobScheduler(
        driverRegistry: SimulatorDriverRegistry({driver.id: driver}),
        config: _emptyConfig(),
        retryPolicy: _CountingRetry(onCall: () => consultations++),
      );
      await scheduler
          .submit(
            RegressionRequest(runId: 'r1', tests: <TestSpec>[spec('s/a')]),
          )
          .toList();
      expect(consultations, 0);
    });
  });
}

/// Test [RetryPolicy] that always returns true and never pins a seed.
class _AlwaysRetry implements RetryPolicy {
  @override
  bool shouldRetry({
    required TestSpec spec,
    required TestResult lastResult,
    required int attemptsSoFar,
    required int maxAttempts,
  }) => true;

  @override
  int? nextSeedFor({
    required TestSpec spec,
    required TestResult lastResult,
    required int attemptsSoFar,
  }) => null;
}

/// Test [RetryPolicy] that emits a deterministic seed sequence.
///
/// `nextSeedFor` returns `seeds[attemptsSoFar - 1]` (first retry uses
/// `seeds[0]`, second retry uses `seeds[1]`, …) and `shouldRetry`
/// stops once the seed sequence is exhausted.
class _SeedSpoofingRetry implements RetryPolicy {
  _SeedSpoofingRetry({required this.seeds});

  final List<int> seeds;

  @override
  bool shouldRetry({
    required TestSpec spec,
    required TestResult lastResult,
    required int attemptsSoFar,
    required int maxAttempts,
  }) => attemptsSoFar <= seeds.length;

  @override
  int? nextSeedFor({
    required TestSpec spec,
    required TestResult lastResult,
    required int attemptsSoFar,
  }) => attemptsSoFar <= seeds.length ? seeds[attemptsSoFar - 1] : null;
}

class _CountingRetry implements RetryPolicy {
  _CountingRetry({required this.onCall});

  final void Function() onCall;

  @override
  bool shouldRetry({
    required TestSpec spec,
    required TestResult lastResult,
    required int attemptsSoFar,
    required int maxAttempts,
  }) {
    onCall();
    return false;
  }

  @override
  int? nextSeedFor({
    required TestSpec spec,
    required TestResult lastResult,
    required int attemptsSoFar,
  }) => null;
}
