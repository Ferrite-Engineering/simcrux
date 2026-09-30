// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/config/test_spec_expander.dart';

TestSpec _baseTemplate({
  String id = 'cpu_unit/alu_basic',
  Map<String, String>? parameters,
  int? seed,
  List<int>? seeds,
  Map<String, List<String>>? parameterSweeps,
}) {
  return TestSpec(
    id: id,
    name: 'alu_basic',
    suiteName: 'cpu_unit',
    simulatorId: 'icarus',
    top: 'tb_alu',
    parameters: parameters,
    seed: seed,
    seeds: seeds,
    parameterSweeps: parameterSweeps,
  );
}

void main() {
  const expander = TestSpecExpander();

  group('TestSpecExpander.expand — no parameterization', () {
    test('returns [source] unchanged when no sweeps declared', () {
      final source = _baseTemplate();
      final expanded = expander.expand(source).toList();
      expect(expanded, hasLength(1));
      expect(expanded.single, same(source));
    });

    test('returns [source] unchanged when sweeps maps are empty', () {
      final source = _baseTemplate(
        seeds: const <int>[],
        parameterSweeps: const <String, List<String>>{},
      );
      final expanded = expander.expand(source).toList();
      expect(expanded, hasLength(1));
      expect(expanded.single, same(source));
    });
  });

  group('TestSpecExpander.expand — seed sweep only', () {
    test('fans out one child per seed in declaration order', () {
      final source = _baseTemplate(seeds: const [1, 5, 9]);
      final expanded = expander.expand(source).toList();
      expect(expanded.map((s) => s.seed), [1, 5, 9]);
      // Every child has the seed sweep field cleared.
      expect(expanded.every((s) => s.seeds == null), isTrue);
      // Every child references the parent's id.
      expect(expanded.every((s) => s.parentSpecId == source.id), isTrue);
      // Ids carry the +seed= suffix.
      expect(
        expanded.map((s) => s.id),
        [
          'cpu_unit/alu_basic+seed=1',
          'cpu_unit/alu_basic+seed=5',
          'cpu_unit/alu_basic+seed=9',
        ],
      );
    });
  });

  group('TestSpecExpander.expand — parameter sweep only', () {
    test('fans out cartesian product in declaration order', () {
      final source = _baseTemplate(
        parameterSweeps: const <String, List<String>>{
          'dataWidth': ['8', '16', '32'],
          'mode': ['fast', 'slow'],
        },
      );
      final expanded = expander.expand(source).toList();
      expect(expanded, hasLength(6));
      // The first axis (dataWidth) advances slowest; mode advances fastest.
      expect(
        expanded
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
      expect(
        expanded.every((s) => s.parameterSweeps == null && s.seeds == null),
        isTrue,
      );
      expect(expanded.every((s) => s.parentSpecId == source.id), isTrue);
    });

    test('merges existing scalar parameters with sweep slice', () {
      final source = _baseTemplate(
        parameters: const {'fixed': 'true'},
        parameterSweeps: const {
          'mode': ['fast', 'slow'],
        },
      );
      final expanded = expander.expand(source).toList();
      expect(expanded, hasLength(2));
      expect(expanded.first.parameters, {'fixed': 'true', 'mode': 'fast'});
      expect(expanded.last.parameters, {'fixed': 'true', 'mode': 'slow'});
    });
  });

  group('TestSpecExpander.expand — both axes', () {
    test('seeds outer, parameters inner in declaration order', () {
      final source = _baseTemplate(
        seeds: const [1, 2],
        parameterSweeps: const {
          'dataWidth': ['8', '16'],
        },
      );
      final expanded = expander.expand(source).toList();
      expect(expanded.map((s) => '${s.seed}/${s.parameters['dataWidth']}'), [
        '1/8',
        '1/16',
        '2/8',
        '2/16',
      ]);
      // Ids carry both suffixes; parameters sort alphabetically inside
      // the suffix.
      expect(expanded.map((s) => s.id), [
        'cpu_unit/alu_basic+dataWidth=8+seed=1',
        'cpu_unit/alu_basic+dataWidth=16+seed=1',
        'cpu_unit/alu_basic+dataWidth=8+seed=2',
        'cpu_unit/alu_basic+dataWidth=16+seed=2',
      ]);
    });
  });

  group('TestSpecExpander.expansionSize', () {
    test('returns 1 for unparameterized templates', () {
      expect(expander.expansionSize(_baseTemplate()), 1);
    });

    test('returns seed factor when only seeds parameterize', () {
      final source = _baseTemplate(seeds: const [1, 2, 3, 4]);
      expect(expander.expansionSize(source), 4);
    });

    test('returns product of axes when only parameters parameterize', () {
      final source = _baseTemplate(
        parameterSweeps: const {
          'a': ['1', '2', '3'],
          'b': ['x', 'y'],
        },
      );
      expect(expander.expansionSize(source), 6);
    });

    test('returns seed * params when both parameterize', () {
      final source = _baseTemplate(
        seeds: const [1, 2],
        parameterSweeps: const {
          'mode': ['fast', 'slow'],
          'memSize': ['1k', '4k', '16k'],
        },
      );
      expect(expander.expansionSize(source), 12);
    });

    test('returns 0 when any axis has zero values', () {
      // The parser rejects empty sweep lists before reaching the
      // expander, but expansionSize defends against malformed runtime
      // input by returning 0 so callers can treat it as a guard.
      final source = _baseTemplate(
        parameterSweeps: const {'mode': <String>[]},
      );
      expect(expander.expansionSize(source), 0);
    });
  });

  group('TestSpecExpander — backward compat', () {
    test('preserves all non-parameterization fields on expanded children', () {
      final source = TestSpec(
        id: 'unit/t',
        name: 't',
        suiteName: 'unit',
        simulatorId: 'verilator',
        top: 'tb',
        sources: const ['a.v', 'b.v'],
        includeDirs: const ['inc'],
        defines: const {'SIM': '1'},
        seeds: const [1, 2],
      );
      final expanded = expander.expand(source).toList();
      for (final child in expanded) {
        expect(child.simulatorId, 'verilator');
        expect(child.top, 'tb');
        expect(child.sources, ['a.v', 'b.v']);
        expect(child.includeDirs, ['inc']);
        expect(child.defines, {'SIM': '1'});
      }
    });
  });
}
