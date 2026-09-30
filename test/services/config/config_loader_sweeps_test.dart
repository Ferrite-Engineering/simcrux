// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_license/crux_license.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/config_loader_error.dart';
import 'package:simcrux/services/config/config_loader.dart';

/// Covers the structured validation errors raised by
/// `config_loader_sweeps.dart` — the `parameters:` and `seeds:` type
/// checks whose messages a user reads verbatim in the config-error
/// banner when a project file is malformed.
///
/// The happy paths (cartesian expansion, range shorthand, tier gating,
/// runaway protection) live in `config_loader_parameterization_test`;
/// this file is the error-branch half.
void main() {
  /// Parses [yaml] and returns the messages of the errors it raised.
  List<String> errorsFor(String yaml) {
    try {
      ConfigLoader().parse(yaml, '/p.yaml');
    } on ConfigLoaderException catch (e) {
      return e.errors.map((err) => err.message).toList();
    }
    fail('expected the loader to reject this document');
  }

  group('parameters: block type validation', () {
    test('a scalar where a map is required names the field and the '
        'accepted shapes', () {
      expect(
        errorsFor(_parametersYaml('parameters: 7')),
        contains(
          allOf(
            contains('parameters'),
            contains('must be a map of string to string or list of strings'),
          ),
        ),
      );
    });

    test('a list entry that is neither string, num nor bool reports the '
        'offending type', () {
      expect(
        errorsFor(
          _parametersYaml('parameters:\n  MEM_SIZE:\n    - [1, 2]\n'),
        ),
        contains(
          allOf(
            contains('MEM_SIZE'),
            contains('strings, numbers'),
            contains('list'),
          ),
        ),
      );
    });

    test('numeric and boolean sweep values are accepted and stringified', () {
      // At a tier that has sweeps: the default Open Core loader drops them.
      final config = ConfigLoader(licenseTier: LicenseTier.pro).parse(
        _parametersYaml('parameters:\n  MEM_SIZE:\n    - 1024\n    - true\n'),
        '/p.yaml',
      );
      expect(
        config.suites.single.tests.map((t) => t.parameters['MEM_SIZE']),
        ['1024', 'true'],
      );
    });

    test('a map-valued parameter reports the offending type', () {
      expect(
        errorsFor(
          _parametersYaml('parameters:\n  MEM_SIZE:\n    nested: 1\n'),
        ),
        contains(
          allOf(
            contains('MEM_SIZE'),
            contains('or a list of those'),
            contains('map'),
          ),
        ),
      );
    });
  });

  group('seeds: block type validation', () {
    test('a scalar where a list is required names the field', () {
      expect(
        errorsFor(_seedsYaml('7')),
        contains(
          allOf(
            contains('seeds'),
            contains('must be a list of non-negative'),
          ),
        ),
      );
    });

    test('a negative seed is rejected with its value', () {
      expect(
        errorsFor(_seedsYaml('[-1]')),
        contains(
          allOf(
            contains('Seed values must be non-negative integers'),
            contains('-1'),
          ),
        ),
      );
    });

    test('a non-integer seed entry reports the offending type', () {
      expect(
        errorsFor(_seedsYaml('[{a: 1}]')),
        contains(
          allOf(
            contains('non-negative'),
            contains('map'),
          ),
        ),
      );
    });
  });

  group('scalar seed: field validation', () {
    test('a negative scalar seed is rejected with its value', () {
      expect(
        errorsFor(_scalarSeedYaml('-2')),
        contains(
          allOf(
            contains('`seed`'),
            contains('must be a non-negative integer'),
            contains('-2'),
          ),
        ),
      );
    });

    test('a non-integer scalar seed is rejected', () {
      expect(
        errorsFor(_scalarSeedYaml('"many"')),
        contains(
          allOf(
            contains('`seed`'),
            contains('must be a non-negative integer'),
          ),
        ),
      );
    });
  });

  group('seed range shorthand bounds', () {
    test('low greater than high is rejected with both bounds', () {
      expect(
        errorsFor(_seedsYaml('["5..2"]')),
        contains(
          allOf(
            contains('low (5)'),
            contains('high'),
            contains('2'),
          ),
        ),
      );
    });
  });
}

String _seedsYaml(String seedsLiteral) =>
    '''
version: "1"
defaults:
  simulator: icarus
suites:
  unit:
    tests:
      - name: alu
        top: tb
        seeds: $seedsLiteral
''';

String _scalarSeedYaml(String seedLiteral) =>
    '''
version: "1"
defaults:
  simulator: icarus
suites:
  unit:
    tests:
      - name: alu
        top: tb
        seed: $seedLiteral
''';

/// Wraps a block written at test-entry depth into a full document,
/// applying the 8-space indent that places it under `- name: alu`.
String _parametersYaml(String block) {
  final indented = block
      .split('\n')
      .map((line) => line.isEmpty ? line : '        $line')
      .join('\n');
  return '''
version: "1"
defaults:
  simulator: icarus
suites:
  unit:
    tests:
      - name: alu
        top: tb
$indented
''';
}
