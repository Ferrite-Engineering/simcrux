// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';
import 'dart:math';

import 'package:crux_license/crux_license.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/config_loader_error.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/config/config_loader.dart';
import 'package:simcrux/services/config/test_spec_expander.dart';
import 'package:simcrux/services/import/fusesoc_importer.dart';

/// Runaway-regression guard, expansion axis. Property-sweeps the
/// expansion ceiling and asserts it is checked against the **Cartesian
/// product across every axis**, not just the largest single axis, and
/// that the same chokepoint guards imported (FuseSoC) configs.
///
/// MUTATION: changing `TestSpecExpander.expansionSize` to return the
/// largest single axis instead of the product makes the multi-axis
/// cases red — a 100×100×2 sweep (20 000 specs) slips past a per-axis
/// 10 000 check.
///
/// The loaders are at Pro: sweeps are a Pro feature, and the default Open
/// Core loader drops them before any expansion, so there is no ceiling to
/// reach there.
void main() {
  const expander = TestSpecExpander();

  TestSpec fuzzSpec(Random rng) {
    final seedCount = rng.nextInt(7); // 0..6
    final seeds = seedCount == 0
        ? null
        : <int>[for (var i = 0; i < seedCount; i++) i];
    final axisCount = rng.nextInt(4); // 0..3 parameter axes
    final sweeps = <String, List<String>>{};
    for (var a = 0; a < axisCount; a++) {
      final card = 1 + rng.nextInt(5); // 1..5 values per axis
      sweeps['p$a'] = <String>[for (var v = 0; v < card; v++) 'v$v'];
    }
    return TestSpec(
      id: 'unit/alu',
      name: 'alu',
      suiteName: 'unit',
      simulatorId: 'icarus',
      top: 'tb',
      seeds: seeds,
      parameterSweeps: sweeps.isEmpty ? null : sweeps,
    );
  }

  int expectedProduct(TestSpec spec) {
    var product = (spec.seeds == null || spec.seeds!.isEmpty)
        ? 1
        : spec.seeds!.length;
    for (final values in (spec.parameterSweeps ?? const {}).values) {
      product *= values.length;
    }
    return product;
  }

  group('expansionSize is the Cartesian product across all axes', () {
    test('fixed-seed fuzz: size == product, and matches actual expansion', () {
      final rng = Random(0x51305130);
      var sawMultiAxis = false;
      for (var i = 0; i < 400; i++) {
        final spec = fuzzSpec(rng);
        final expected = expectedProduct(spec);
        // The product across EVERY axis — not the max single axis.
        expect(
          expander.expansionSize(spec),
          expected,
          reason: 'seeds=${spec.seeds} sweeps=${spec.parameterSweeps}',
        );
        // The guard count must match what expand() actually produces, so
        // the pre-expansion check is sound.
        expect(expander.expand(spec).length, expected);

        final axes = <int>[
          if (spec.seeds != null && spec.seeds!.isNotEmpty) spec.seeds!.length,
          for (final v in (spec.parameterSweeps ?? const {}).values) v.length,
        ];
        if (axes.length >= 2 &&
            expected > axes.fold<int>(1, (m, a) => a > m ? a : m)) {
          sawMultiAxis = true;
        }
      }
      // Guarantee the sweep actually exercised the product > max-axis
      // case the mutation would slip through.
      expect(sawMultiAxis, isTrue);
    });
  });

  group('ConfigLoader rejects a multi-axis product over the ceiling', () {
    String sweepYaml(int aCard, int bCard, List<int> seeds) {
      final a = <String>[for (var i = 0; i < aCard; i++) '"a$i"'].join(', ');
      final b = <String>[for (var i = 0; i < bCard; i++) '"b$i"'].join(', ');
      return '''
version: "1"
defaults:
  simulator: icarus
suites:
  unit:
    tests:
      - name: alu
        top: tb
        seeds: $seeds
        parameters:
          A: [$a]
          B: [$b]
''';
    }

    test('100×100×2 = 20000 specs is rejected before any spawn', () {
      final loader = ConfigLoader(licenseTier: LicenseTier.pro);
      expect(
        () => loader.parse(sweepYaml(100, 100, const [1, 2]), '/p.yaml'),
        throwsA(
          isA<ConfigLoaderException>().having(
            (e) => e.errors.map((x) => x.message).join('\n'),
            'message',
            contains('would expand into 20000'),
          ),
        ),
      );
    });

    test('a multi-axis product within budget expands normally', () {
      final loader = ConfigLoader(licenseTier: LicenseTier.pro);
      // 50 × 50 × 2 = 5000 ≤ 10000.
      final config = loader.parse(sweepYaml(50, 50, const [1, 2]), '/p.yaml');
      final total = config.suites.expand((s) => s.tests).length;
      expect(total, 5000);
    });
  });

  group('imported FuseSoC configs hit the same expansion ceiling', () {
    test(
      'importer output loads, and a runaway sweep on it is rejected',
      () async {
        final importer = FuseSoCImporter();
        final core = File(
          'test/fixtures/fusesoc/simple.core',
        ).readAsStringSync();
        final imported = importer.parse(core, '/cores/simple.core');

        // The imported config flows through the same ConfigLoader chokepoint.
        final loader = ConfigLoader(licenseTier: LicenseTier.pro);
        expect(
          () => loader.parse(imported.simcruxYaml, '/cores/simple.yaml'),
          returnsNormally,
        );

        // A runaway parameterization authored on top of an imported config
        // is rejected by that same chokepoint, including configs that
        // originate from the FuseSoC importer rather than a hand-written
        // simcrux.yaml.
        final runaway =
            '''
version: "1"
defaults:
  simulator: icarus
suites:
  imported:
    tests:
      - name: top
        top: top
        seeds: ${List<int>.generate(20001, (i) => i)}
''';
        expect(
          () => loader.parse(runaway, '/cores/simple.yaml'),
          throwsA(isA<ConfigLoaderException>()),
        );
      },
    );
  });
}
