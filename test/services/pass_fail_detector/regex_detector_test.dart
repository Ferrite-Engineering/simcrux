// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/pass_fail_config.dart';
import 'package:simcrux/services/pass_fail_detector/regex_detector.dart';

void main() {
  group('RegexDetector', () {
    const detector = RegexDetector();

    TestStatus run(
      String stdout, {
      String stderr = '',
      int? exitCode = 0,
      String? passPattern,
      String? failPattern,
    }) => detector.detect(
      stdout: stdout,
      stderr: stderr,
      exitCode: exitCode,
      runtime: Duration.zero,
      config: RegexPassFailConfig(
        passPattern: passPattern,
        failPattern: failPattern,
      ),
    );

    test('returns pass when passPattern matches stdout', () {
      expect(
        run('hello\nTEST PASSED\nbye', passPattern: r'^TEST PASSED$'),
        TestStatus.pass,
      );
    });

    test('returns pass when passPattern matches stderr blob', () {
      expect(
        run('stdout only', stderr: 'PASS-OK', passPattern: 'PASS-OK'),
        TestStatus.pass,
      );
    });

    test(
      'returns fail when failPattern matches (even if passPattern also does)',
      () {
        expect(
          run(
            'TEST PASSED\nERROR: bad thing',
            passPattern: r'^TEST PASSED$',
            failPattern: 'ERROR:',
          ),
          TestStatus.fail,
        );
      },
    );

    test('returns fail when required passPattern is absent', () {
      expect(
        run('nothing relevant', passPattern: r'^TEST PASSED$'),
        TestStatus.fail,
      );
    });

    test('returns unknown when only failPattern is set and never fires', () {
      expect(
        run('quiet log', failPattern: 'ERROR:'),
        TestStatus.unknown,
      );
    });

    test('returns unknown for non-regex configs', () {
      expect(
        detector.detect(
          stdout: '',
          stderr: '',
          exitCode: 0,
          runtime: Duration.zero,
          config: const ExitCodePassFailConfig(),
        ),
        TestStatus.unknown,
      );
    });

    test('invalid regex degrades to unknown rather than throwing', () {
      expect(
        run('anything', failPattern: '['), // unclosed character class
        TestStatus.unknown,
      );
    });
  });
}
