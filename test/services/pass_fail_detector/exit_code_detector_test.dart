// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/pass_fail_config.dart';
import 'package:simcrux/services/pass_fail_detector/exit_code_detector.dart';

void main() {
  const detector = ExitCodeDetector();

  group('ExitCodeDetector', () {
    test('classifies exit code 0 as pass', () {
      final status = detector.detect(
        stdout: '',
        stderr: '',
        exitCode: 0,
        runtime: const Duration(seconds: 1),
        config: const ExitCodePassFailConfig(),
      );
      expect(status, TestStatus.pass);
    });

    test('classifies nonzero exit code as fail', () {
      final status = detector.detect(
        stdout: '',
        stderr: 'boom',
        exitCode: 1,
        runtime: const Duration(seconds: 1),
        config: const ExitCodePassFailConfig(),
      );
      expect(status, TestStatus.fail);
    });

    test('classifies negative exit code (killed) as fail', () {
      final status = detector.detect(
        stdout: '',
        stderr: '',
        exitCode: -15,
        runtime: const Duration(seconds: 1),
        config: const ExitCodePassFailConfig(),
      );
      expect(status, TestStatus.fail);
    });

    test('classifies null exit code as unknown', () {
      final status = detector.detect(
        stdout: '',
        stderr: '',
        exitCode: null,
        runtime: const Duration(seconds: 1),
        config: const ExitCodePassFailConfig(),
      );
      expect(status, TestStatus.unknown);
    });

    test('reports unknown when handed a non-exit-code config', () {
      final status = detector.detect(
        stdout: 'PASS',
        stderr: '',
        exitCode: 0,
        runtime: const Duration(seconds: 1),
        config: const StringMatchPassFailConfig(passString: 'PASS'),
      );
      expect(status, TestStatus.unknown);
    });
  });
}
