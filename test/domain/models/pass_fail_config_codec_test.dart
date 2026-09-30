// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/golden_compare_profile.dart';
import 'package:simcrux/domain/models/pass_fail_config.dart';
import 'package:simcrux/domain/models/pass_fail_config_codec.dart';

void main() {
  group('DetectorSpec.decode/encode round-trip', () {
    test('exit_code', () {
      const original = ExitCodeSpec();
      final round = DetectorSpec.decode(DetectorSpec.encode(original));
      expect(round, original);
    });

    test('string_match with both pass and fail strings', () {
      const original = StringMatchSpec(
        passString: 'ALL OK',
        failString: 'FATAL',
      );
      final round = DetectorSpec.decode(DetectorSpec.encode(original));
      expect(round, original);
    });

    test('regex with only failPattern', () {
      const original = RegexSpec(failPattern: 'FATAL.*');
      final round = DetectorSpec.decode(DetectorSpec.encode(original));
      expect(round, original);
    });

    test('uvm_report with default thresholds', () {
      const original = UvmReportSpec();
      final round = DetectorSpec.decode(DetectorSpec.encode(original));
      expect(round, original);
    });

    test('cocotb with defaults', () {
      const original = CocotbSpec();
      final round = DetectorSpec.decode(DetectorSpec.encode(original));
      expect(round, original);
    });

    test('cocotb with allow_no_tests', () {
      const original = CocotbSpec(allowNoTests: true);
      final round = DetectorSpec.decode(DetectorSpec.encode(original));
      expect(round, original);
      expect(DetectorSpec.encode(original)['allow_no_tests'], isTrue);
    });

    test('cocotb omits allow_no_tests when false', () {
      // Encoding a default keeps saved detector libraries free of noise that
      // reads as an intentional setting when it is not.
      expect(
        DetectorSpec.encode(const CocotbSpec()).containsKey('allow_no_tests'),
        isFalse,
      );
    });

    test('composite of mixed children', () {
      final original = CompositeSpec(
        allOf: const [
          ExitCodeSpec(),
          StringMatchSpec(failString: 'oops'),
        ],
        anyOf: const [RegexSpec(passPattern: 'OK')],
      );
      final round = DetectorSpec.decode(DetectorSpec.encode(original));
      expect(round, original);
    });

    test('use reference', () {
      const original = UseSpec('strict-uvm');
      final round = DetectorSpec.decode(DetectorSpec.encode(original));
      expect(round, original);
    });

    test('decodeFromString tolerates malformed input', () {
      expect(DetectorSpec.decodeFromString(null), isNull);
      expect(DetectorSpec.decodeFromString(''), isNull);
      expect(DetectorSpec.decodeFromString('not json'), isNull);
    });

    test('decode rejects unknown type', () {
      expect(DetectorSpec.decode({'type': 'unknown'}), isNull);
    });
  });

  group('DetectorSpec.resolve', () {
    test('expands a use reference', () {
      final reusable = <String, DetectorSpec>{
        'strict-uvm': const UvmReportSpec(),
      };
      final resolved = DetectorSpec.resolve(
        const UseSpec('strict-uvm'),
        reusable,
      );
      expect(resolved, isA<UvmReportPassFailConfig>());
    });

    test('resolves nested composites with use children', () {
      final reusable = <String, DetectorSpec>{
        'inner': const RegexSpec(failPattern: 'FATAL'),
      };
      final spec = CompositeSpec(
        allOf: const [
          ExitCodeSpec(),
          UseSpec('inner'),
        ],
      );
      final resolved =
          DetectorSpec.resolve(spec, reusable)! as CompositePassFailConfig;
      expect(resolved.allOf, hasLength(2));
      expect(resolved.allOf[0], isA<ExitCodePassFailConfig>());
      expect(resolved.allOf[1], isA<RegexPassFailConfig>());
    });

    test('detects direct cycle', () {
      final reusable = <String, DetectorSpec>{
        'a': const UseSpec('a'),
      };
      expect(
        () => DetectorSpec.resolve(const UseSpec('a'), reusable),
        throwsA(isA<StateError>()),
      );
    });

    test('detects mutual cycle', () {
      final reusable = <String, DetectorSpec>{
        'a': const UseSpec('b'),
        'b': const UseSpec('a'),
      };
      expect(
        () => DetectorSpec.resolve(const UseSpec('a'), reusable),
        throwsA(isA<StateError>()),
      );
    });

    test('unknown reference resolves to null', () {
      final reusable = <String, DetectorSpec>{
        'a': const ExitCodeSpec(),
      };
      expect(
        DetectorSpec.resolve(const UseSpec('missing'), reusable),
        isNull,
      );
    });
  });

  group('GoldenCompareSpec', () {
    test('round-trips through encode/decode with its profile', () {
      const original = GoldenCompareSpec(
        dutPath: 'out/dut.sig',
        referencePath: '/goldens/rv32i.sig',
        profile: GoldenCompareProfile.riscvSignature,
      );
      final json = DetectorSpec.encode(original);
      expect(json, {
        'type': 'golden_compare',
        'profile': 'riscv_signature',
        'dut': 'out/dut.sig',
        'reference': '/goldens/rv32i.sig',
      });
      expect(DetectorSpec.decode(json), original);
    });

    test('round-trips through the string codec', () {
      final original = GoldenCompareSpec.forProfile(
        GoldenCompareProfile.riscvSignature,
      );
      final text = DetectorSpec.encodeToString(original);
      expect(DetectorSpec.decodeFromString(text), original);
    });

    test('decode fills the profile defaults when paths are omitted', () {
      final spec =
          DetectorSpec.decode({
                'type': 'golden_compare',
                'profile': 'riscv_signature',
              })!
              as GoldenCompareSpec;
      expect(spec.dutPath, 'signature.dut.sig');
      expect(spec.referencePath, 'signature.ref.sig');
    });

    test('decode defaults to the generic profile and then needs paths', () {
      expect(
        DetectorSpec.decode({
          'type': 'golden_compare',
          'dut': 'a.bin',
          'reference': 'b.bin',
        }),
        const GoldenCompareSpec(dutPath: 'a.bin', referencePath: 'b.bin'),
      );
      // Generic has no conventional filenames, so an entry with neither
      // is malformed rather than silently defaulted.
      expect(DetectorSpec.decode({'type': 'golden_compare'}), isNull);
    });

    test('decode rejects an unknown profile', () {
      expect(
        DetectorSpec.decode({
          'type': 'golden_compare',
          'profile': 'rv64gc',
          'dut': 'a',
          'reference': 'b',
        }),
        isNull,
      );
    });

    test('resolves to the runtime config', () {
      final resolved = DetectorSpec.resolve(
        GoldenCompareSpec.forProfile(GoldenCompareProfile.riscvSignature),
        const <String, DetectorSpec>{},
      );
      expect(resolved, isA<GoldenComparePassFailConfig>());
      final config = resolved! as GoldenComparePassFailConfig;
      expect(config.profile, GoldenCompareProfile.riscvSignature);
      expect(config.dutPath, 'signature.dut.sig');
    });

    test('nests inside a composite and survives the round-trip', () {
      final original = CompositeSpec(
        allOf: [
          const ExitCodeSpec(),
          GoldenCompareSpec.forProfile(GoldenCompareProfile.riscvSignature),
        ],
      );
      expect(DetectorSpec.decode(DetectorSpec.encode(original)), original);
    });

    test('copyWith replaces one field at a time', () {
      final base = GoldenCompareSpec.forProfile(
        GoldenCompareProfile.riscvSignature,
      );
      expect(base.copyWith(dutPath: 'x').dutPath, 'x');
      expect(base.copyWith(dutPath: 'x').referencePath, base.referencePath);
      expect(
        base.copyWith(profile: GoldenCompareProfile.generic).profile,
        GoldenCompareProfile.generic,
      );
    });

    test('forProfile refuses a profile with no conventional filenames', () {
      expect(
        () => GoldenCompareSpec.forProfile(GoldenCompareProfile.generic),
        throwsArgumentError,
      );
    });

    test('equality covers every field', () {
      const a = GoldenCompareSpec(dutPath: 'a', referencePath: 'b');
      const b = GoldenCompareSpec(dutPath: 'a', referencePath: 'b');
      const c = GoldenCompareSpec(
        dutPath: 'a',
        referencePath: 'b',
        profile: GoldenCompareProfile.riscvSignature,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });
}
