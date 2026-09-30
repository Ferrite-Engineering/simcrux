// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_license/crux_license_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/cli/cli_args.dart';
import 'package:simcrux/domain/models/test_run.dart';
import 'package:simcrux/services/ci/fail_on_regression_policy.dart';

class _AlwaysFailPolicy implements FailOnRegressionPolicy {
  const _AlwaysFailPolicy({this.exitCode = 1});
  final int exitCode;
  @override
  Future<FailOnRegressionDecision> shouldFailWithExitCode({
    required TestRun candidate,
    required CliArgs args,
    required LicenseTier licenseTier,
  }) async {
    return FailOnRegressionDecision(failed: true, exitCode: exitCode);
  }
}

void main() {
  group('FailOnRegressionDecision', () {
    test('pass constant is (false, 0)', () {
      const decision = FailOnRegressionDecision.pass;
      expect(decision.failed, isFalse);
      expect(decision.exitCode, 0);
    });

    test('value-equal on (failed, exitCode)', () {
      const a = FailOnRegressionDecision(failed: true, exitCode: 1);
      const b = FailOnRegressionDecision(failed: true, exitCode: 1);
      const c = FailOnRegressionDecision(failed: true, exitCode: 2);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
    });
  });

  group('NoopFailOnRegressionPolicy', () {
    test('always returns pass regardless of args / candidate', () async {
      const policy = NoopFailOnRegressionPolicy();
      final run = TestRun(
        id: 'r1',
        startedAt: DateTime.utc(2026, 5),
        testIds: const ['unit/alu'],
      );
      const args = CliArgs(failOnRegression: true);
      final decision = await policy.shouldFailWithExitCode(
        candidate: run,
        args: args,
        licenseTier: LicenseTier.enterprise,
      );
      expect(decision, FailOnRegressionDecision.pass);
    });
  });

  group('failOnRegressionPolicyProvider', () {
    test('open-core default is NoopFailOnRegressionPolicy', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final policy = container.read(failOnRegressionPolicyProvider);
      expect(policy, isA<NoopFailOnRegressionPolicy>());
    });

    test('override surfaces the supplied policy', () async {
      final container = ProviderContainer(
        overrides: [
          failOnRegressionPolicyProvider.overrideWithValue(
            const _AlwaysFailPolicy(exitCode: 7),
          ),
        ],
      );
      addTearDown(container.dispose);
      final policy = container.read(failOnRegressionPolicyProvider);
      expect(policy, isA<_AlwaysFailPolicy>());
      final decision = await policy.shouldFailWithExitCode(
        candidate: TestRun(
          id: 'r1',
          startedAt: DateTime.utc(2026, 5),
          testIds: const [],
        ),
        args: const CliArgs(),
        licenseTier: LicenseTier.openCore,
      );
      expect(decision.failed, isTrue);
      expect(decision.exitCode, 7);
    });
  });
}
