// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/config_loader_error.dart';
import 'package:simcrux/domain/models/pass_fail_config.dart';
import 'package:simcrux/domain/models/pass_fail_config_codec.dart';
import 'package:simcrux/services/config/config_loader.dart';

// An uncompilable regex used to reach the detector, which can only answer
// `unknown` for it; the scheduler then adopted the driver's status, so a
// failing test that exited 0 was reported as a pass. The loader now compiles
// every pattern and refuses the project instead.

Future<ConfigLoaderException> _loadError(
  String yaml, {
  Map<String, DetectorSpec> reusable = const <String, DetectorSpec>{},
}) async {
  final loader = ConfigLoader(
    readFile: (_) async => yaml,
    reusableDetectors: reusable,
  );
  try {
    await loader.load('/p/simcrux.yaml');
  } on ConfigLoaderException catch (e) {
    return e;
  }
  fail('expected ConfigLoaderException');
}

void main() {
  group('ConfigLoader — regex patterns are compiled at load', () {
    test('a (?i) fail_pattern is rejected with its line and a hint', () async {
      final e = await _loadError('''
version: "1"
defaults:
  pass_fail:
    type: regex
    fail_pattern: "(?i)error"
suites:
  unit:
    simulator: icarus
    tests:
      - name: a
        top: tb
''');
      final error = e.errors.single;
      expect(error.message, contains('defaults.pass_fail.fail_pattern'));
      expect(error.message, contains('not a valid regular expression'));
      expect(error.message, contains('(?i)error'));
      expect(error.message, contains('(?i:…)'));
      expect(error.line, 5, reason: 'points at the fail_pattern line');
    });

    test('an invalid pass_pattern on a test is rejected', () async {
      final e = await _loadError('''
version: "1"
suites:
  unit:
    simulator: icarus
    tests:
      - name: a
        top: tb
        pass_fail:
          type: regex
          pass_pattern: "TEST (PASSED"
''');
      expect(e.errors.single.message, contains('pass_pattern'));
      expect(e.errors.single.message, isNot(contains('(?i:…)')));
    });

    test('an invalid pattern inside a composite is rejected', () async {
      final e = await _loadError('''
version: "1"
defaults:
  pass_fail:
    type: composite
    any_of:
      - type: exit_code
      - type: regex
        fail_pattern: "[unclosed"
suites:
  unit:
    simulator: icarus
    tests:
      - name: a
        top: tb
''');
      expect(
        e.errors.single.message,
        contains('not a valid regular expression'),
      );
    });

    test('a library detector with an invalid pattern fails the load of the '
        'project that uses it', () async {
      final e = await _loadError(
        '''
version: "1"
defaults:
  pass_fail:
    type: use
    name: loose-errors
suites:
  unit:
    simulator: icarus
    tests:
      - name: a
        top: tb
''',
        reusable: <String, DetectorSpec>{
          'loose-errors': CompositeSpec(
            allOf: const [RegexSpec(failPattern: '(?i)error')],
          ),
        },
      );
      expect(e.errors.single.message, contains('use "loose-errors"'));
      expect(e.errors.single.message, contains('(?i)error'));
    });

    test('the scoped (?i:…) form and plain patterns load', () async {
      final loader = ConfigLoader(
        readFile: (_) async => r'''
version: "1"
defaults:
  pass_fail:
    type: regex
    fail_pattern: "(?i:error)|FATAL"
    pass_pattern: "^TEST PASSED$"
suites:
  unit:
    simulator: icarus
    tests:
      - name: a
        top: tb
''',
      );
      final config = await loader.load('/p/simcrux.yaml');
      final regex = config.defaultPassFail! as RegexPassFailConfig;
      expect(regex.failPattern, '(?i:error)|FATAL');
    });
  });
}
