// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/golden_compare_profile.dart';
import 'package:simcrux/domain/models/config_loader_error.dart';
import 'package:simcrux/domain/models/pass_fail_config.dart';
import 'package:simcrux/domain/models/pass_fail_config_codec.dart';
import 'package:simcrux/services/config/config_loader.dart';

// Loader coverage for the seventh YAML detector type, `golden_compare`.
//
// MUTATION: drop `golden_compare` from the `default:` branch's list of
// valid types and the "enumerates every valid type" test fails; drop the
// dut == reference guard and "same file" starts loading as a config that
// always passes.
void main() {
  ConfigLoader loaderFor(
    String yaml, {
    Map<String, DetectorSpec> reusable = const <String, DetectorSpec>{},
  }) {
    return ConfigLoader(
      readFile: (_) async => yaml,
      reusableDetectors: reusable,
    );
  }

  String doc(String passFail) =>
      '''
version: "1"
defaults:
  pass_fail:
$passFail
suites:
  unit:
    simulator: icarus
    tests:
      - name: a
        top: tb
''';

  Future<List<ConfigLoaderError>> errorsFrom(ConfigLoader loader) async {
    try {
      await loader.load('/p/simcrux.yaml');
      fail('expected ConfigLoaderException');
    } on ConfigLoaderException catch (e) {
      return e.errors;
    }
  }

  group('ConfigLoader — golden_compare', () {
    test('riscv_signature profile supplies conventional filenames', () async {
      final config = await loaderFor(
        doc('    type: golden_compare\n    profile: riscv_signature'),
      ).load('/p/simcrux.yaml');
      final pf = config.defaultPassFail;
      expect(pf, isA<GoldenComparePassFailConfig>());
      final golden = pf! as GoldenComparePassFailConfig;
      expect(golden.profile, GoldenCompareProfile.riscvSignature);
      expect(golden.dutPath, 'signature.dut.sig');
      expect(golden.referencePath, 'signature.ref.sig');
    });

    test('explicit paths win over the profile defaults', () async {
      final config = await loaderFor(
        doc(
          '    type: golden_compare\n'
          '    profile: riscv_signature\n'
          '    dut: out/mine.sig\n'
          '    reference: /goldens/rv32i.sig',
        ),
      ).load('/p/simcrux.yaml');
      final golden = config.defaultPassFail! as GoldenComparePassFailConfig;
      expect(golden.dutPath, 'out/mine.sig');
      expect(golden.referencePath, '/goldens/rv32i.sig');
    });

    test('the generic profile is the default when none is given', () async {
      final config = await loaderFor(
        doc(
          '    type: golden_compare\n'
          '    dut: out.bin\n'
          '    reference: golden.bin',
        ),
      ).load('/p/simcrux.yaml');
      final golden = config.defaultPassFail! as GoldenComparePassFailConfig;
      expect(golden.profile, GoldenCompareProfile.generic);
    });

    test('works as a per-test detector, not just a default', () async {
      final config = await loaderFor('''
version: "1"
suites:
  arch:
    simulator: icarus
    tests:
      - name: add
        top: tb
        pass_fail:
          type: golden_compare
          profile: riscv_signature
''').load('/p/simcrux.yaml');
      final spec = config.suites.single.tests.single;
      expect(spec.passFail, isA<GoldenComparePassFailConfig>());
    });

    test('composes as a composite leaf', () async {
      final config = await loaderFor(
        doc(
          '    type: composite\n'
          '    all_of:\n'
          '      - type: exit_code\n'
          '      - type: golden_compare\n'
          '        profile: riscv_signature',
        ),
      ).load('/p/simcrux.yaml');
      final composite = config.defaultPassFail! as CompositePassFailConfig;
      expect(composite.allOf.last, isA<GoldenComparePassFailConfig>());
    });

    test('resolves through a `use:` reference', () async {
      final config = await loaderFor(
        doc('    type: use\n    name: arch-sig'),
        reusable: <String, DetectorSpec>{
          'arch-sig': GoldenCompareSpec.forProfile(
            GoldenCompareProfile.riscvSignature,
          ),
        },
      ).load('/p/simcrux.yaml');
      expect(config.defaultPassFail, isA<GoldenComparePassFailConfig>());
    });

    test('is NOT tier-gated — no license is consulted', () async {
      // The compatibility verdict is correctness, and
      // correctness is free. The loader's `_parameterizationUnlocked`
      // gate covers sweeps only; this path must have no analogue. A
      // loader constructed with no license context at all must still
      // produce the detector.
      final config = await loaderFor(
        doc('    type: golden_compare\n    profile: riscv_signature'),
      ).load('/p/simcrux.yaml');
      expect(config.defaultPassFail, isA<GoldenComparePassFailConfig>());
    });
  });

  group('ConfigLoader — golden_compare validation', () {
    test('generic profile requires both paths', () async {
      final errors = await errorsFrom(
        loaderFor(doc('    type: golden_compare')),
      );
      expect(
        errors.map((e) => e.message).join('\n'),
        allOf(
          contains('pass_fail.dut'),
          contains('is required'),
          contains('generic'),
        ),
      );
    });

    test('accumulates BOTH missing-path errors, not just the first', () async {
      // The loader shows the whole punch list per load rather than
      // failing fast.
      final errors = await errorsFrom(
        loaderFor(doc('    type: golden_compare')),
      );
      final messages = errors.map((e) => e.message).toList();
      expect(messages.where((m) => m.contains('pass_fail.dut')), hasLength(1));
      expect(
        messages.where((m) => m.contains('pass_fail.reference')),
        hasLength(1),
      );
    });

    test('rejects an unknown profile and names the valid ones', () async {
      final errors = await errorsFrom(
        loaderFor(doc('    type: golden_compare\n    profile: rv64gc')),
      );
      expect(
        errors.first.message,
        allOf(
          contains('pass_fail.profile'),
          contains('generic'),
          contains('riscv_signature'),
          contains('rv64gc'),
        ),
      );
    });

    test('rejects a non-string or empty path', () async {
      final errors = await errorsFrom(
        loaderFor(
          doc(
            '    type: golden_compare\n'
            '    profile: riscv_signature\n'
            '    dut: 42',
          ),
        ),
      );
      expect(
        errors.first.message,
        allOf(contains('pass_fail.dut'), contains('non-empty file path')),
      );
    });

    test('rejects dut == reference, which would always pass', () async {
      final errors = await errorsFrom(
        loaderFor(
          doc(
            '    type: golden_compare\n'
            '    dut: same.sig\n'
            '    reference: same.sig',
          ),
        ),
      );
      expect(
        errors.first.message,
        allOf(contains('same file'), contains('always pass')),
      );
    });

    test(
      'type: cocotb loads, with allow_no_tests defaulting to false',
      () async {
        final config = await loaderFor(doc('    type: cocotb')).load(
          '/p/simcrux.yaml',
        );
        expect(
          config.defaultPassFail,
          const CocotbPassFailConfig(),
        );
      },
    );

    test('type: cocotb rejects a non-boolean allow_no_tests', () async {
      final errors = await errorsFrom(
        loaderFor(
          doc(
            '    type: cocotb\n'
            '    allow_no_tests: yesplease',
          ),
        ),
      );
      expect(
        errors.first.message,
        allOf(contains('allow_no_tests'), contains('boolean')),
      );
    });

    test('the unknown-type error enumerates every valid type', () async {
      final errors = await errorsFrom(loaderFor(doc('    type: bogus')));
      final message = errors.first.message;
      for (final type in const [
        'exit_code',
        'string_match',
        'regex',
        'uvm_report',
        'cocotb',
        'golden_compare',
        'composite',
        'use',
      ]) {
        expect(message, contains(type), reason: 'missing $type');
      }
      expect(message, contains('bogus'));
    });
  });
}
