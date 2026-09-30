// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/pass_fail_config.dart';
import 'package:simcrux/services/pass_fail_detector/string_match_detector.dart';

void main() {
  const detector = StringMatchDetector();

  group('StringMatchDetector', () {
    test('classifies as pass when passString appears in stdout', () {
      final status = detector.detect(
        stdout: 'log lines\nTEST PASSED\nmore lines',
        stderr: '',
        exitCode: 0,
        runtime: Duration.zero,
        config: const StringMatchPassFailConfig(passString: 'TEST PASSED'),
      );
      expect(status, TestStatus.pass);
    });

    test('classifies as pass when passString appears in stderr', () {
      final status = detector.detect(
        stdout: '',
        stderr: 'TEST PASSED',
        exitCode: 0,
        runtime: Duration.zero,
        config: const StringMatchPassFailConfig(passString: 'TEST PASSED'),
      );
      expect(status, TestStatus.pass);
    });

    test('classifies as fail when passString is missing', () {
      final status = detector.detect(
        stdout: 'log lines without pass',
        stderr: '',
        exitCode: 0,
        runtime: Duration.zero,
        config: const StringMatchPassFailConfig(passString: 'TEST PASSED'),
      );
      expect(status, TestStatus.fail);
    });

    test(
      'classifies as fail when failString appears (overrides passString)',
      () {
        final status = detector.detect(
          stdout: 'TEST PASSED\nERROR: oops\n',
          stderr: '',
          exitCode: 0,
          runtime: Duration.zero,
          config: const StringMatchPassFailConfig(
            passString: 'TEST PASSED',
            failString: 'ERROR:',
          ),
        );
        expect(status, TestStatus.fail);
      },
    );

    test(
      'classifies as unknown when only failString is configured and absent',
      () {
        final status = detector.detect(
          stdout: 'clean run',
          stderr: '',
          exitCode: 0,
          runtime: Duration.zero,
          config: const StringMatchPassFailConfig(failString: 'ERROR:'),
        );
        expect(status, TestStatus.unknown);
      },
    );

    test('classifies as fail when failString appears in stderr', () {
      final status = detector.detect(
        stdout: '',
        stderr: 'FATAL: simulation died',
        exitCode: 1,
        runtime: Duration.zero,
        config: const StringMatchPassFailConfig(failString: 'FATAL:'),
      );
      expect(status, TestStatus.fail);
    });

    test('returns unknown for a non-string-match config', () {
      final status = detector.detect(
        stdout: '',
        stderr: '',
        exitCode: 0,
        runtime: Duration.zero,
        config: const ExitCodePassFailConfig(),
      );
      expect(status, TestStatus.unknown);
    });

    test('treats empty passString as no positive signal', () {
      final status = detector.detect(
        stdout: 'anything',
        stderr: '',
        exitCode: 0,
        runtime: Duration.zero,
        config: const StringMatchPassFailConfig(
          passString: '',
          failString: 'X',
        ),
      );
      // Empty passString is ignored; failString didn't fire either —
      // unknown.
      expect(status, TestStatus.unknown);
    });
  });
}
