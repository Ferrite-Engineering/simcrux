// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/pass_fail_config.dart';
import 'package:simcrux/services/job_scheduler/local_job_scheduler.dart';

/// How the scheduler merges the detector's verdict with the driver's.
///
/// The one rule with teeth: under the default `exit_code` detector a driver
/// that saw its simulator fail (Icarus printing `ERROR:` and exiting 0)
/// outranks the exit code's `pass`. Everywhere else the detector decides,
/// and the driver's guess fills in only an `unknown`.
void main() {
  const exitCode = ExitCodePassFailConfig();
  const configured = StringMatchPassFailConfig(passString: 'TEST PASSED');

  test('the detector decides when it has a verdict', () {
    expect(
      LocalJobScheduler.resolveFinalStatus(
        classified: TestStatus.fail,
        driverStatus: TestStatus.pass,
        config: exitCode,
      ),
      TestStatus.fail,
    );
    expect(
      LocalJobScheduler.resolveFinalStatus(
        classified: TestStatus.pass,
        driverStatus: TestStatus.pass,
        config: exitCode,
      ),
      TestStatus.pass,
    );
  });

  test('an unknown verdict falls back to the driver', () {
    for (final driver in TestStatus.values) {
      expect(
        LocalJobScheduler.resolveFinalStatus(
          classified: TestStatus.unknown,
          driverStatus: driver,
          config: exitCode,
        ),
        driver,
      );
    }
  });

  test(r'exit_code: a driver that saw $error outranks exit 0', () {
    expect(
      LocalJobScheduler.resolveFinalStatus(
        classified: TestStatus.pass,
        driverStatus: TestStatus.fail,
        config: exitCode,
      ),
      TestStatus.fail,
      reason:
          r'Icarus exits 0 after $error + $finish and prints ERROR: instead; '
          'the driver read it, so the exit code alone must not say pass',
    );
  });

  test('a configured detector is not second-guessed by the driver', () {
    expect(
      LocalJobScheduler.resolveFinalStatus(
        classified: TestStatus.pass,
        driverStatus: TestStatus.fail,
        config: configured,
      ),
      TestStatus.pass,
      reason:
          'the user named a detector because the exit code was not the '
          'signal they wanted; its verdict stands on its own',
    );
  });

  group('a formal verdict that is not a proof', () {
    for (final token in ['FAIL', 'UNKNOWN', 'TIMEOUT', 'ERROR', 'NO_OUTCOME']) {
      test('$token is never turned into a pass by any detector', () {
        for (final config in [configured, const ExitCodePassFailConfig()]) {
          expect(
            LocalJobScheduler.resolveFinalStatus(
              classified: TestStatus.pass,
              driverStatus: TestStatus.fail,
              config: config,
              driverMetrics: {'formal.verdict': token},
            ),
            TestStatus.fail,
            reason:
                'the string_match detector reads DONE (PASS in the log; the '
                "driver's reconciled verdict is the conservative fact",
          );
        }
      });
    }

    test('a token this build cannot read is not a proof either', () {
      expect(
        LocalJobScheduler.resolveFinalStatus(
          classified: TestStatus.pass,
          driverStatus: TestStatus.fail,
          config: configured,
          driverMetrics: const {'formal.verdict': 'PROVEN_SOMEHOW'},
        ),
        TestStatus.fail,
      );
    });

    test('PASS leaves the detector deciding', () {
      expect(
        LocalJobScheduler.resolveFinalStatus(
          classified: TestStatus.pass,
          driverStatus: TestStatus.pass,
          config: configured,
          driverMetrics: const {'formal.verdict': 'PASS'},
        ),
        TestStatus.pass,
      );
    });
  });
}
