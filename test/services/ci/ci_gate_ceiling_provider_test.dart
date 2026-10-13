// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/cli/cli_args.dart';
import 'package:simcrux/services/ci/ci_gate_ceiling_provider.dart';

void main() {
  group('ciGateCeilingProvider', () {
    test('open core applies no ceiling', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(ciGateCeilingProvider), isNull);
    });
  });

  group('applyCiGateCeiling', () {
    const ci = CliArgs(projectPaths: ['p.yaml'], ciMode: true);

    test('no ceiling leaves the args untouched and says nothing', () {
      final notes = <String>[];
      final out = applyCiGateCeiling(ci, ceiling: null, note: notes.add);
      expect(identical(out, ci), isTrue);
      expect(notes, isEmpty);
    });

    test('a ceiling replaces the default as ceiling + 1', () {
      final notes = <String>[];
      final out = applyCiGateCeiling(ci, ceiling: 3, note: notes.add);
      // `failures >= 4` fails, so three failures pass and four do not.
      expect(out.failThreshold, 4);
      expect(out.failThresholdExplicit, isFalse);
      expect(notes, hasLength(1));
      expect(notes.single, contains('ciGateThreshold'));
      expect(notes.single, contains('more than 3 tests fail'));
    });

    test('a ceiling of 0 fails on any failure', () {
      final out = applyCiGateCeiling(ci, ceiling: 0, note: (_) {});
      expect(out.failThreshold, 1);
    });

    test('an explicit --fail-threshold wins over the ceiling', () {
      final typed = ci.copyWith(failThreshold: 10, failThresholdExplicit: true);
      final notes = <String>[];
      final out = applyCiGateCeiling(typed, ceiling: 0, note: notes.add);
      expect(out.failThreshold, 10);
      expect(notes, isEmpty);
    });

    test('a negative ceiling is ignored rather than trusted', () {
      final out = applyCiGateCeiling(ci, ceiling: -1, note: (_) {});
      expect(identical(out, ci), isTrue);
    });
  });
}
