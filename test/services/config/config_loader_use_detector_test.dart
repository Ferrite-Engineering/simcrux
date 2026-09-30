// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/config_loader_error.dart';
import 'package:simcrux/domain/models/pass_fail_config.dart';
import 'package:simcrux/domain/models/pass_fail_config_codec.dart';
import 'package:simcrux/services/config/config_loader.dart';

void main() {
  group('ConfigLoader — reusable detector references', () {
    test(
      'resolves a top-level use: reference to a UVM report detector',
      () async {
        final loader = ConfigLoader(
          readFile: (_) async => '''
version: "1"
defaults:
  pass_fail:
    type: use
    name: strict-uvm
suites:
  unit:
    simulator: icarus
    tests:
      - name: a
        top: tb
''',
          reusableDetectors: const <String, DetectorSpec>{
            'strict-uvm': UvmReportSpec(fatalThreshold: 0, errorThreshold: 0),
          },
        );
        final config = await loader.load('/p/simcrux.yaml');
        final pf = config.defaultPassFail;
        expect(pf, isA<UvmReportPassFailConfig>());
        final uvm = pf! as UvmReportPassFailConfig;
        expect(uvm.fatalThreshold, 0);
        expect(uvm.errorThreshold, 0);
      },
    );

    test('errors on missing reusable detector', () async {
      final loader = ConfigLoader(
        readFile: (_) async => '''
version: "1"
defaults:
  pass_fail:
    type: use
    name: missing
suites:
  unit:
    simulator: icarus
    tests:
      - name: a
        top: tb
''',
      );
      try {
        await loader.load('/p/simcrux.yaml');
        fail('expected ConfigLoaderException');
      } on ConfigLoaderException catch (e) {
        expect(
          e.errors.first.message,
          contains('unknown reusable detector "missing"'),
        );
      }
    });

    test('errors on cycle between reusable detectors', () async {
      final loader = ConfigLoader(
        readFile: (_) async => '''
version: "1"
defaults:
  pass_fail:
    type: use
    name: a
suites:
  unit:
    simulator: icarus
    tests:
      - name: t
        top: tb
''',
        reusableDetectors: const <String, DetectorSpec>{
          'a': UseSpec('b'),
          'b': UseSpec('a'),
        },
      );
      try {
        await loader.load('/p/simcrux.yaml');
        fail('expected ConfigLoaderException');
      } on ConfigLoaderException catch (e) {
        expect(
          e.errors.first.message,
          contains('cycle detected'),
        );
      }
    });

    test('resolves a use: reference nested inside a composite', () async {
      final loader = ConfigLoader(
        readFile: (_) async => '''
version: "1"
defaults:
  pass_fail:
    type: composite
    all_of:
      - type: exit_code
      - type: use
        name: strict-uvm
suites:
  unit:
    simulator: icarus
    tests:
      - name: t
        top: tb
''',
        reusableDetectors: const <String, DetectorSpec>{
          'strict-uvm': UvmReportSpec(),
        },
      );
      final config = await loader.load('/p/simcrux.yaml');
      final pf = config.defaultPassFail!;
      expect(pf, isA<CompositePassFailConfig>());
      final comp = pf as CompositePassFailConfig;
      expect(comp.allOf, hasLength(2));
      expect(comp.allOf[0], isA<ExitCodePassFailConfig>());
      expect(comp.allOf[1], isA<UvmReportPassFailConfig>());
    });
  });
}
