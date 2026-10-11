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

    test('value-equal on (failed, exitCode, reason)', () {
      const a = FailOnRegressionDecision(failed: true, exitCode: 1);
      const b = FailOnRegressionDecision(failed: true, exitCode: 1);
      const c = FailOnRegressionDecision(failed: true, exitCode: 2);
      const d = FailOnRegressionDecision(
        failed: true,
        exitCode: 1,
        reason: 'why',
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
      expect(a, isNot(equals(d)));
    });

    test('unavailable is a failed gate with exit 2 and its reason', () {
      const decision = FailOnRegressionDecision.unavailable('no engine');
      expect(decision.failed, isTrue);
      expect(decision.exitCode, 2);
      expect(decision.reason, 'no engine');
    });
  });

  group('UnavailableFailOnRegressionPolicy', () {
    test('refuses the gate at every tier: exit 2, names the desktop '
        'executable', () async {
      const policy = UnavailableFailOnRegressionPolicy();
      final run = TestRun(
        id: 'r1',
        startedAt: DateTime.utc(2026, 5),
        testIds: const ['unit/alu'],
      );
      const args = CliArgs(
        failOnRegression: true,
        baselineRunPath: '/b/baseline.ndjson',
      );
      for (final tier in LicenseTier.values) {
        final decision = await policy.shouldFailWithExitCode(
          candidate: run,
          args: args,
          licenseTier: tier,
        );
        expect(decision.failed, isTrue, reason: '$tier');
        expect(decision.exitCode, 2, reason: '$tier');
        expect(decision.reason, kRegressionGateUnavailableReason);
      }
      expect(
        kRegressionGateUnavailableReason,
        contains('SimCrux.app/Contents/MacOS/SimCrux'),
      );
    });
  });

  group('failOnRegressionPolicyProvider', () {
    test('open-core default is UnavailableFailOnRegressionPolicy', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final policy = container.read(failOnRegressionPolicyProvider);
      expect(policy, isA<UnavailableFailOnRegressionPolicy>());
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
