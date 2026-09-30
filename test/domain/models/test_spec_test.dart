// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/pass_fail_config.dart';
import 'package:simcrux/domain/models/resource_lock.dart';
import 'package:simcrux/domain/models/test_spec.dart';

TestSpec _spec({
  String id = 'cpu_unit/alu_basic',
  String name = 'alu_basic',
  String suiteName = 'cpu_unit',
  String simulatorId = 'icarus',
  String top = 'tb_alu',
}) {
  return TestSpec(
    id: id,
    name: name,
    suiteName: suiteName,
    simulatorId: simulatorId,
    top: top,
  );
}

void main() {
  group('TestSpec', () {
    test('default sources / includeDirs / defines / parameters are empty', () {
      final spec = _spec();
      expect(spec.sources, isEmpty);
      expect(spec.includeDirs, isEmpty);
      expect(spec.defines, isEmpty);
      expect(spec.parameters, isEmpty);
    });

    test('default passFail / waveform / resources / timeout', () {
      final spec = _spec();
      expect(spec.passFail, const ExitCodePassFailConfig());
      expect(spec.timeout, const Duration(seconds: 300));
      expect(spec.resources, isEmpty);
    });

    test('lists and maps are unmodifiable', () {
      final spec = TestSpec(
        id: 'cpu_unit/alu_basic',
        name: 'alu_basic',
        suiteName: 'cpu_unit',
        simulatorId: 'icarus',
        top: 'tb_alu',
        sources: const ['rtl/alu.v'],
        defines: const {'SIM': '1'},
        resources: const [ResourceLock(name: 'fpga_board_0')],
      );
      expect(() => spec.sources.add('x'), throwsUnsupportedError);
      expect(() => spec.defines['k'] = 'v', throwsUnsupportedError);
      expect(
        () => spec.resources.add(const ResourceLock(name: 'x')),
        throwsUnsupportedError,
      );
    });

    test('copyWith replaces fields', () {
      final spec = _spec();
      final updated = spec.copyWith(
        simulatorId: 'verilator',
        timeout: const Duration(seconds: 600),
      );
      expect(updated.simulatorId, 'verilator');
      expect(updated.timeout, const Duration(seconds: 600));
      expect(updated.id, spec.id);
      expect(updated.name, spec.name);
    });

    test('equality compares every field value', () {
      final a = _spec();
      final b = _spec();
      final c = _spec(simulatorId: 'verilator');
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
    });

    test('equality is order-sensitive on sources but unordered on defines', () {
      final a = TestSpec(
        id: 'x',
        name: 'x',
        suiteName: 's',
        simulatorId: 'icarus',
        top: 'tb',
        sources: const ['a.v', 'b.v'],
        defines: const {'X': '1', 'Y': '2'},
      );
      final swappedSources = TestSpec(
        id: 'x',
        name: 'x',
        suiteName: 's',
        simulatorId: 'icarus',
        top: 'tb',
        sources: const ['b.v', 'a.v'],
        defines: const {'X': '1', 'Y': '2'},
      );
      final swappedDefines = TestSpec(
        id: 'x',
        name: 'x',
        suiteName: 's',
        simulatorId: 'icarus',
        top: 'tb',
        sources: const ['a.v', 'b.v'],
        defines: const {'Y': '2', 'X': '1'},
      );
      expect(a, isNot(equals(swappedSources)));
      expect(a, equals(swappedDefines));
    });

    test('seed defaults to null', () {
      expect(_spec().seed, isNull);
    });

    test('seed round-trips through copyWith and participates in equality', () {
      final base = _spec();
      final pinned = base.copyWith(seed: 1234);
      expect(pinned.seed, 1234);
      final pinned2 = _spec().copyWith(seed: 1234);
      expect(pinned, equals(pinned2));
      expect(pinned.hashCode, pinned2.hashCode);
      expect(pinned, isNot(equals(base)));
      expect(pinned, isNot(equals(_spec().copyWith(seed: 1235))));
    });

    test('seeds / parameterSweeps / parentSpecId default to null', () {
      final spec = _spec();
      expect(spec.seeds, isNull);
      expect(spec.parameterSweeps, isNull);
      expect(spec.parentSpecId, isNull);
      expect(spec.isParameterized, isFalse);
    });

    test('isParameterized reflects either axis being non-empty', () {
      expect(_spec().copyWith(seeds: const [1, 2]).isParameterized, isTrue);
      expect(
        _spec()
            .copyWith(
              parameterSweeps: const {
                'mode': ['fast', 'slow'],
              },
            )
            .isParameterized,
        isTrue,
      );
      expect(_spec().copyWith(seeds: const []).isParameterized, isFalse);
      expect(
        _spec().copyWith(parameterSweeps: const {}).isParameterized,
        isFalse,
      );
    });

    test('displayName format covers all four axes', () {
      // No seed, no parameters → just suite/name.
      expect(_spec().displayName, 'cpu_unit/alu_basic');

      // Seed only.
      final seeded = _spec().copyWith(seed: 7);
      expect(seeded.displayName, 'cpu_unit/alu_basic [seed=7]');

      // Parameters only (alphabetical inside the brackets).
      final paramsOnly = _spec().copyWith(
        parameters: const {'mode': 'fast', 'dataWidth': '16'},
      );
      expect(
        paramsOnly.displayName,
        'cpu_unit/alu_basic [dataWidth=16, mode=fast]',
      );

      // Both.
      final both = _spec().copyWith(
        seed: 7,
        parameters: const {'mode': 'fast', 'dataWidth': '16'},
      );
      expect(
        both.displayName,
        'cpu_unit/alu_basic [seed=7, dataWidth=16, mode=fast]',
      );
    });

    test('copyWith clear* flags null out the sweep fields', () {
      final template = _spec().copyWith(
        seeds: const [1, 2, 3],
        parameterSweeps: const {
          'mode': ['fast', 'slow'],
        },
      );
      final cleared = template.copyWith(
        clearSeeds: true,
        clearParameterSweeps: true,
      );
      expect(cleared.seeds, isNull);
      expect(cleared.parameterSweeps, isNull);
      // Without the clear flag, the existing value is preserved.
      final keep = template.copyWith();
      expect(keep.seeds, [1, 2, 3]);
      expect(keep.parameterSweeps, {
        'mode': ['fast', 'slow'],
      });
    });

    test('parentSpecId round-trips through copyWith and ==', () {
      final spec = _spec().copyWith(parentSpecId: 'cpu_unit/alu_basic');
      expect(spec.parentSpecId, 'cpu_unit/alu_basic');
      expect(
        spec,
        equals(_spec().copyWith(parentSpecId: 'cpu_unit/alu_basic')),
      );
      expect(spec, isNot(equals(_spec())));
    });

    test('seeds / parameterSweeps participate in equality and hashCode', () {
      final a = _spec().copyWith(seeds: const [1, 2]);
      final b = _spec().copyWith(seeds: const [1, 2]);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);

      // Different seeds → not equal.
      expect(a, isNot(equals(_spec().copyWith(seeds: const [1, 3]))));

      final c = _spec().copyWith(
        parameterSweeps: const {
          'mode': ['a', 'b'],
        },
      );
      final d = _spec().copyWith(
        parameterSweeps: const {
          'mode': ['a', 'b'],
        },
      );
      expect(c, equals(d));
      expect(c.hashCode, d.hashCode);
      expect(
        c,
        isNot(
          equals(
            _spec().copyWith(
              parameterSweeps: const {
                'mode': ['a', 'c'],
              },
            ),
          ),
        ),
      );
    });

    test('unmodifiable sweep collections survive original mutation', () {
      final mutableSeeds = [1, 2, 3];
      final mutableSweep = {
        'mode': ['fast', 'slow'],
      };
      final spec = _spec().copyWith(
        seeds: mutableSeeds,
        parameterSweeps: mutableSweep,
      );
      // Mutating the original collections after construction must not
      // leak into the spec.
      mutableSeeds.add(99);
      mutableSweep['mode']!.add('extra');
      mutableSweep['new_axis'] = ['x'];
      expect(spec.seeds, [1, 2, 3]);
      expect(spec.parameterSweeps, {
        'mode': ['fast', 'slow'],
      });

      // The captured collections themselves are unmodifiable.
      expect(() => spec.seeds!.add(4), throwsUnsupportedError);
      expect(
        () => spec.parameterSweeps!['mode']!.add('x'),
        throwsUnsupportedError,
      );
    });
  });
}
