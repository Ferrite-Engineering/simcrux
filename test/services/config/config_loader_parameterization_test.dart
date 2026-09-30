// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_license/crux_license.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/config_loader_error.dart';
import 'package:simcrux/services/config/config_loader.dart';

/// Tests that cover the parameterization extensions to
/// the YAML schema:
///
/// - `seeds: [N, ...]` and `seeds: ["1..N"]` range shorthand
/// - `parameters: { KEY: [v1, v2, ...] }` cartesian-product expansion
/// - License-tier gating on both blocks
/// - Runaway-protection via `maxExpansionSize`
///
/// The loader is exercised through [ConfigLoader.parse] directly so
/// the tests do not need to touch the filesystem.
void main() {
  group('ConfigLoader.parse — seeds expansion', () {
    test('expands literal seed list into N concrete TestSpecs', () {
      final loader = _expanding();
      final config = loader.parse(_seedsYaml('[1, 2, 3]'), '/p.yaml');
      final suite = config.suites.single;
      expect(suite.tests, hasLength(3));
      expect(suite.tests.map((s) => s.seed), [1, 2, 3]);
      expect(suite.tests.map((s) => s.id), [
        'unit/alu+seed=1',
        'unit/alu+seed=2',
        'unit/alu+seed=3',
      ]);
      // Every expanded child references the parent's id and clears
      // the sweep field.
      for (final spec in suite.tests) {
        expect(spec.parentSpecId, 'unit/alu');
        expect(spec.seeds, isNull);
      }
    });

    test('expands range shorthand `"1..5"` inclusively', () {
      final loader = _expanding();
      final config = loader.parse(_seedsYaml('["1..5"]'), '/p.yaml');
      expect(config.suites.single.tests.map((s) => s.seed), [1, 2, 3, 4, 5]);
    });

    test('rejects malformed range shorthand with a structured error', () {
      final loader = _expanding();
      expect(
        () => loader.parse(_seedsYaml('["1..x"]'), '/p.yaml'),
        throwsA(
          isA<ConfigLoaderException>().having(
            (e) => e.errors.single.message,
            'message',
            contains('range shorthand'),
          ),
        ),
      );
    });

    test('rejects empty seed list', () {
      final loader = _expanding();
      expect(
        () => loader.parse(_seedsYaml('[]'), '/p.yaml'),
        throwsA(isA<ConfigLoaderException>()),
      );
    });

    test('single-element seed list folds into scalar seed (no expansion)', () {
      final loader = _expanding();
      final config = loader.parse(_seedsYaml('[7]'), '/p.yaml');
      final tests = config.suites.single.tests;
      expect(tests, hasLength(1));
      expect(tests.single.seed, 7);
      // Synthesized id stays at the parent form — no `+seed=` suffix.
      expect(tests.single.id, 'unit/alu');
      expect(tests.single.parentSpecId, isNull);
    });
  });

  group('ConfigLoader.parse — parameter sweeps', () {
    test('expands cartesian product in declaration order', () {
      final loader = _expanding();
      final config = loader.parse(
        _parametersYaml('''
parameters:
  dataWidth: ["8", "16", "32"]
  mode: ["fast", "slow"]
'''),
        '/p.yaml',
      );
      final tests = config.suites.single.tests;
      expect(tests, hasLength(6));
      expect(
        tests
            .map((s) => '${s.parameters['dataWidth']}+${s.parameters['mode']}')
            .toList(),
        [
          '8+fast',
          '8+slow',
          '16+fast',
          '16+slow',
          '32+fast',
          '32+slow',
        ],
      );
    });

    test('scalar values pass through unchanged (no expansion)', () {
      final loader = _expanding();
      final config = loader.parse(
        _parametersYaml('''
parameters:
  MEM_SIZE: "1024"
'''),
        '/p.yaml',
      );
      final tests = config.suites.single.tests;
      expect(tests, hasLength(1));
      expect(tests.single.parameters, {'MEM_SIZE': '1024'});
      expect(tests.single.id, 'unit/alu+MEM_SIZE=1024');
    });

    test('single-element sweep folds into scalar', () {
      final loader = _expanding();
      final config = loader.parse(
        _parametersYaml('''
parameters:
  MEM_SIZE: ["1024"]
'''),
        '/p.yaml',
      );
      final tests = config.suites.single.tests;
      expect(tests, hasLength(1));
      expect(tests.single.parameters, {'MEM_SIZE': '1024'});
    });

    test('rejects empty sweep value list with a clear error', () {
      final loader = _expanding();
      expect(
        () => loader.parse(
          _parametersYaml('''
parameters:
  MEM_SIZE: []
'''),
          '/p.yaml',
        ),
        throwsA(
          isA<ConfigLoaderException>().having(
            (e) => e.errors.single.message,
            'message',
            contains('empty'),
          ),
        ),
      );
    });
  });

  group('ConfigLoader.parse — combined sweeps', () {
    test('seeds and parameters fan out together', () {
      final loader = _expanding();
      final config = loader.parse('''
version: "1"
defaults:
  simulator: icarus
suites:
  unit:
    tests:
      - name: alu
        top: tb
        seeds: [1, 2]
        parameters:
          mode: ["fast", "slow"]
''', '/p.yaml');
      expect(config.suites.single.tests, hasLength(4));
    });
  });

  group('ConfigLoader.parse — runaway protection', () {
    test('rejects parameterization that exceeds maxExpansionSize', () {
      // Force a low cap so the test stays small.
      final loader = ConfigLoader(
        licenseTier: LicenseTier.pro,
        maxExpansionSize: 4,
      );
      expect(
        () => loader.parse('''
version: "1"
defaults:
  simulator: icarus
suites:
  unit:
    tests:
      - name: alu
        top: tb
        seeds: [1, 2, 3, 4, 5]
''', '/p.yaml'),
        throwsA(
          isA<ConfigLoaderException>().having(
            (e) => e.errors.single.message,
            'message',
            allOf(
              contains('would expand into 5'),
              contains('max 4'),
            ),
          ),
        ),
      );
    });

    test('the rejection names the setting that raises the ceiling and '
        'offers no command-line flag', () {
      // No `--max-expansion` (or any other) flag exists, and `--ci` never
      // reads the Pro setting — so the message must neither invent a flag
      // nor imply the setting reaches a CI run. The Pro overlay pins the
      // setting's path against its own rail label.
      final loader = ConfigLoader(
        licenseTier: LicenseTier.pro,
        maxExpansionSize: 4,
      );
      expect(
        () => loader.parse('''
version: "1"
defaults:
  simulator: icarus
suites:
  unit:
    tests:
      - name: alu
        top: tb
        seeds: [1, 2, 3, 4, 5]
''', '/p.yaml'),
        throwsA(
          isA<ConfigLoaderException>().having(
            (e) => e.errors.single.message,
            'message',
            allOf(
              contains('Max expansion size'),
              contains('`--ci` always uses the default'),
              isNot(contains('--max-expansion')),
            ),
          ),
        ),
      );
    });
  });

  group('ConfigLoader.parse — tier gating', () {
    test('under beta (any tier), seeds + parameters expand regardless of '
        'tier', () {
      // The beta is pinned, not defaulted: `kBetaPeriod` is false now, and
      // this tests what a beta build does. The gate should be open even when
      // the active tier is openCore.
      final loader = ConfigLoader(betaPeriod: true);
      final config = loader.parse(_seedsYaml('[1, 2, 3]'), '/p.yaml');
      expect(config.suites.single.tests, hasLength(3));
      expect(config.loadWarnings, isEmpty);
    });

    test('post-beta openCore tier: sweeps are silently dropped and a '
        'warning is recorded', () {
      final loader = ConfigLoader(
        // Pinned, not defaulted: this tests post-beta behaviour on purpose.
        // ignore: avoid_redundant_argument_values
        betaPeriod: false,
      );
      final config = loader.parse(_seedsYaml('[1, 2, 3]'), '/p.yaml');
      // Sweep dropped → test runs exactly once with no pinned seed.
      expect(config.suites.single.tests, hasLength(1));
      expect(config.suites.single.tests.single.seed, isNull);
      // Warning surfaced on the loaded config.
      expect(config.loadWarnings, hasLength(1));
      expect(
        config.loadWarnings.single.severity,
        ConfigLoaderErrorSeverity.warning,
      );
      expect(
        config.loadWarnings.single.message,
        contains('requires SimCrux Pro'),
      );
    });

    test('post-beta openCore tier: parameters sweep is also dropped with '
        'a warning', () {
      final loader = ConfigLoader(
        // Pinned, not defaulted: this tests post-beta behaviour on purpose.
        // ignore: avoid_redundant_argument_values
        betaPeriod: false,
      );
      final config = loader.parse(
        _parametersYaml('''
parameters:
  MEM_SIZE: ["1024", "4096"]
'''),
        '/p.yaml',
      );
      expect(config.suites.single.tests, hasLength(1));
      expect(config.suites.single.tests.single.parameters, isEmpty);
      expect(config.loadWarnings, hasLength(1));
    });

    test('post-beta Pro tier: sweeps expand normally with no warning', () {
      final loader = ConfigLoader(
        licenseTier: LicenseTier.pro,
        // Pinned, not defaulted: this tests post-beta behaviour on purpose.
        // ignore: avoid_redundant_argument_values
        betaPeriod: false,
      );
      final config = loader.parse(_seedsYaml('[1, 2, 3]'), '/p.yaml');
      expect(config.suites.single.tests, hasLength(3));
      expect(config.loadWarnings, isEmpty);
    });

    test('post-beta EDU tier: feature-equivalent to Pro — sweeps expand', () {
      final loader = ConfigLoader(
        licenseTier: LicenseTier.edu,
        // Pinned, not defaulted: this tests post-beta behaviour on purpose.
        // ignore: avoid_redundant_argument_values
        betaPeriod: false,
      );
      final config = loader.parse(_seedsYaml('[1, 2, 3]'), '/p.yaml');
      expect(config.suites.single.tests, hasLength(3));
      expect(config.loadWarnings, isEmpty);
    });

    test('post-beta Enterprise tier: sweeps expand', () {
      final loader = ConfigLoader(
        licenseTier: LicenseTier.enterprise,
        // Pinned, not defaulted: this tests post-beta behaviour on purpose.
        // ignore: avoid_redundant_argument_values
        betaPeriod: false,
      );
      final config = loader.parse(_seedsYaml('[1, 2, 3]'), '/p.yaml');
      expect(config.suites.single.tests, hasLength(3));
      expect(config.loadWarnings, isEmpty);
    });

    test('a single-element seeds list bypasses the gate (no sweep)', () {
      // [7] folds into scalar seed; no advisory should fire on
      // openCore post-beta.
      final loader = ConfigLoader(
        // Pinned, not defaulted: this tests post-beta behaviour on purpose.
        // ignore: avoid_redundant_argument_values
        betaPeriod: false,
      );
      final config = loader.parse(_seedsYaml('[7]'), '/p.yaml');
      expect(config.suites.single.tests, hasLength(1));
      expect(config.suites.single.tests.single.seed, 7);
      expect(config.loadWarnings, isEmpty);
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

/// Wraps a `parameters: {...}` block (caller supplies the literal
/// YAML body that goes under the test entry) into a complete YAML
/// document. The body is indented to match the test-entry depth — the
/// caller writes the body unindented and this helper applies the
/// 8-space indent that puts each line under the `- name: alu` test
/// entry.
String _parametersYaml(String parametersBlock) {
  final indented = parametersBlock
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

/// A loader at a tier that includes parameterization, for the tests of how
/// sweeps expand. Since the beta ended, the default Open Core loader drops
/// every sweep (the tier-gating group below covers that), so a test of the
/// expansion itself has to be at a tier that has it.
ConfigLoader _expanding() => ConfigLoader(licenseTier: LicenseTier.pro);
