// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/hdl_language.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/pass_fail_config.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/formal/formal_org_policy.dart';
import 'package:simcrux/services/formal/formal_policy_provider.dart';
import 'package:simcrux/services/job_scheduler/job_scheduler_provider.dart';
import 'package:simcrux/services/job_scheduler/local_job_scheduler.dart';
import 'package:simcrux/services/simulator/sby_driver.dart';

/// The organization's formal policy refuses results, never verdicts: the
/// expectations below come from the rule each key states, applied to the
/// metrics an `sby` result carries.
Map<String, String> _sby({
  String mode = 'bmc',
  String? depth = '20',
  String? engine = 'smtbmc',
  String? solver = 'yices',
  String? assertionsDisabled,
  String verdict = 'PASS',
}) => <String, String>{
  'formal.tool': 'sby',
  'formal.verdict': verdict,
  'formal.mode': mode,
  'formal.depth_configured': ?depth,
  'formal.engine': ?engine,
  'formal.solver': ?solver,
  'formal.assertions_disabled': ?assertionsDisabled,
};

class _ScriptedDriver implements SimulatorDriver {
  _ScriptedDriver(this.metrics);

  final Map<String, String> metrics;
  final List<String> cancelled = <String>[];

  @override
  String get id => 'sby';

  @override
  String get displayName => 'SymbiYosys';

  @override
  SimulatorCapabilities get capabilities => SimulatorCapabilities(
    supportedLanguages: const {HdlLanguage.verilog},
    supportsVcd: true,
    supportsFst: false,
    supportsCocotb: false,
    requiresSeparateCompileStep: false,
    emitsStructuredOutput: false,
  );

  @override
  Future<String?> detectVersion(SimulatorBinaryConfig config) async => 'v';

  @override
  Future<CompileResult> compile(CompileRequest request) async =>
      const CompileResult(
        success: true,
        artifactPath: null,
        stdout: '',
        stderr: '',
      );

  @override
  Stream<TestExecutionEvent> execute(ExecuteRequest request) async* {
    yield TestLogLine(
      line: 'SBY DONE (PASS, rc=0)',
      fromStderr: false,
      timestamp: DateTime.utc(2026),
    );
    yield TestExecutionFinished(
      status: TestStatus.pass,
      exitCode: 0,
      startedAt: DateTime.utc(2026),
      finishedAt: DateTime.utc(2026),
      metrics: metrics,
    );
  }

  @override
  void cancel(String testId) => cancelled.add(testId);
}

void main() {
  group('violationsOf', () {
    test('an empty policy refuses nothing', () {
      expect(
        const FormalOrgPolicy().violationsOf(_sby(assertionsDisabled: 'x')),
        isEmpty,
      );
    });

    test(
      'assertions turned off break the opt-out rule only when forbidden',
      () {
        const policy = FormalOrgPolicy(forbidAssertionOptOut: true);
        expect(policy.violationsOf(_sby(assertionsDisabled: 'noassert')), [
          FormalPolicyRule.assertionOptOut,
        ]);
        expect(policy.violationsOf(_sby()), isEmpty);
      },
    );

    test('the allowed engines are engine lines; an engine alone allows every '
        'solver under it', () {
      const lines = FormalOrgPolicy(requiredSolvers: {'smtbmc yices'});
      expect(lines.violationsOf(_sby()), isEmpty);
      expect(lines.violationsOf(_sby(solver: 'boolector')), [
        FormalPolicyRule.solverNotAllowed,
      ]);
      const engine = FormalOrgPolicy(requiredSolvers: {'SMTBMC'});
      expect(engine.violationsOf(_sby(solver: 'boolector')), isEmpty);
      expect(engine.violationsOf(_sby(engine: 'abc', solver: 'pdr')), [
        FormalPolicyRule.solverNotAllowed,
      ]);
      expect(engine.violationsOf(_sby(engine: null, solver: null)), [
        FormalPolicyRule.solverUnknown,
      ]);
    });

    test('the depth floor binds bounded proofs and covers, not unbounded '
        'ones', () {
      const policy = FormalOrgPolicy(minDepth: 30);
      expect(policy.violationsOf(_sby()), [FormalPolicyRule.depthBelowFloor]);
      expect(policy.violationsOf(_sby(depth: '30')), isEmpty);
      expect(policy.violationsOf(_sby(mode: 'cover', depth: '10')), [
        FormalPolicyRule.depthBelowFloor,
      ]);
      expect(policy.violationsOf(_sby(mode: 'prove', depth: '5')), isEmpty);
      expect(policy.violationsOf(_sby(depth: null)), [
        FormalPolicyRule.depthUnknown,
      ]);
    });

    test('a row that is not formal, or never reached its tool, is never '
        'refused', () {
      const policy = FormalOrgPolicy(minDepth: 30, forbidAssertionOptOut: true);
      expect(policy.violationsOf(const {'flow.verdict': 'met'}), isEmpty);
      expect(
        policy.violationsOf(<String, String>{
          ..._sby(depth: '1'),
          'formal.not_run_reason': 'sva_unsupported',
        }),
        isEmpty,
      );
    });
  });

  group('apply', () {
    test('a refused pass fails with the reason; the verdict is untouched', () {
      const policy = FormalOrgPolicy(minDepth: 30);
      final (refused, rules) = policy.apply(
        TestExecutionFinished(
          status: TestStatus.pass,
          exitCode: 0,
          startedAt: DateTime.utc(2026),
          finishedAt: DateTime.utc(2026),
          metrics: _sby(),
        ),
      );
      expect(rules, [FormalPolicyRule.depthBelowFloor]);
      expect(refused.status, TestStatus.fail);
      expect(refused.metrics['formal.verdict'], 'PASS');
      expect(
        refused.metrics[kFormalPolicyViolationMetric],
        'depth_below_floor',
      );
      expect(refused.failureMessage, contains('Refused by the organization'));
      expect(refused.failureMessage, contains('floor of 30'));
    });

    test('an accepted result is returned unchanged', () {
      final finished = TestExecutionFinished(
        status: TestStatus.pass,
        exitCode: 0,
        startedAt: DateTime.utc(2026),
        finishedAt: DateTime.utc(2026),
        metrics: _sby(depth: '40'),
      );
      final (same, rules) = const FormalOrgPolicy(minDepth: 30).apply(finished);
      expect(rules, isEmpty);
      expect(identical(same, finished), isTrue);
    });
  });

  group('FormalPolicyEnforcingDriver', () {
    TestSpec spec() => TestSpec(
      id: 'formal/fifo',
      name: 'fifo',
      suiteName: 'formal',
      simulatorId: 'sby',
      top: 'fifo',
    );

    test('forwards everything, refuses the terminal event, and calls the '
        'hook once', () async {
      final calls =
          <({String testId, String tool, List<FormalPolicyRule> rules})>[];
      final inner = _ScriptedDriver(_sby(assertionsDisabled: 'noassert'));
      final driver = FormalPolicyEnforcingDriver(
        inner,
        FormalPolicyEnforcement(
          policy: const FormalOrgPolicy(forbidAssertionOptOut: true),
          onRefused: ({required testId, required tool, required rules}) =>
              calls.add((testId: testId, tool: tool, rules: rules)),
        ),
      );
      expect(driver.id, 'sby');
      expect(
        await driver.detectVersion(
          const SimulatorBinaryConfig(simulatorId: 'sby'),
        ),
        'v',
      );
      final events = await driver
          .execute(
            ExecuteRequest(
              test: spec(),
              workingDirectory: '/w',
              compileResult: null,
              binaryConfig: const SimulatorBinaryConfig(simulatorId: 'sby'),
            ),
          )
          .toList();
      expect(events.first, isA<TestLogLine>());
      final finished = events.last as TestExecutionFinished;
      expect(finished.status, TestStatus.fail);
      expect(calls.single.testId, 'formal/fifo');
      expect(calls.single.tool, 'sby');
      expect(calls.single.rules, [FormalPolicyRule.assertionOptOut]);
      driver.cancel('formal/fifo');
      expect(inner.cancelled, ['formal/fifo']);
    });
  });

  test('no detector turns a refused result back into a pass', () {
    expect(
      LocalJobScheduler.resolveFinalStatus(
        classified: TestStatus.pass,
        driverStatus: TestStatus.fail,
        config: const StringMatchPassFailConfig(passString: 'DONE (PASS'),
        driverMetrics: <String, String>{
          ..._sby(),
          kFormalPolicyViolationMetric: 'depth_below_floor',
        },
      ),
      TestStatus.fail,
    );
  });

  group('the registry seam', () {
    test('open core binds no policy: `sby` is the plain driver', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(formalPolicyEnforcementProvider), isNull);
      final driver = container
          .read(simulatorDriverRegistryProvider)
          .driverFor(SbyDriver.kId);
      expect(driver, isA<SbyDriver>());
    });

    test('a bound policy wraps `sby` and only `sby`', () {
      final container = ProviderContainer(
        overrides: [
          formalPolicyEnforcementProvider.overrideWithValue(
            const FormalPolicyEnforcement(
              policy: FormalOrgPolicy(minDepth: 10),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final registry = container.read(simulatorDriverRegistryProvider);
      final sby = registry.driverFor(SbyDriver.kId);
      expect(sby, isA<FormalPolicyEnforcingDriver>());
      expect((sby! as FormalPolicyEnforcingDriver).inner, isA<SbyDriver>());
    });

    test('an empty bound policy leaves the plain driver', () {
      final container = ProviderContainer(
        overrides: [
          formalPolicyEnforcementProvider.overrideWithValue(
            const FormalPolicyEnforcement(policy: FormalOrgPolicy()),
          ),
        ],
      );
      addTearDown(container.dispose);
      expect(
        container
            .read(simulatorDriverRegistryProvider)
            .driverFor(SbyDriver.kId),
        isA<SbyDriver>(),
      );
    });
  });
}
