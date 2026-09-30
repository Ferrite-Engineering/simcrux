// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/golden_compare_profile.dart';
import 'package:simcrux/domain/models/pass_fail_config.dart';

void main() {
  group('ExitCodePassFailConfig', () {
    test('equality is type-based (it carries no fields)', () {
      const a = ExitCodePassFailConfig();
      const b = ExitCodePassFailConfig();
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });
  });

  group('StringMatchPassFailConfig', () {
    test('equality compares both pass and fail strings', () {
      const a = StringMatchPassFailConfig(passString: 'OK');
      const b = StringMatchPassFailConfig(passString: 'OK');
      const c = StringMatchPassFailConfig(
        passString: 'OK',
        failString: 'ERROR',
      );
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
    });

    test('asserts at least one of pass / fail strings is non-null', () {
      expect(StringMatchPassFailConfig.new, throwsAssertionError);
    });
  });

  group('RegexPassFailConfig', () {
    test('equality compares both pass and fail patterns', () {
      const a = RegexPassFailConfig(passPattern: 'TEST PASSED');
      const b = RegexPassFailConfig(passPattern: 'TEST PASSED');
      const c = RegexPassFailConfig(failPattern: 'TEST FAILED');
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
    });

    test('asserts at least one of pass / fail patterns is non-null', () {
      expect(RegexPassFailConfig.new, throwsAssertionError);
    });
  });

  group('UvmReportPassFailConfig', () {
    test('default thresholds are 1 / 1 / null', () {
      const a = UvmReportPassFailConfig();
      expect(a.fatalThreshold, 1);
      expect(a.errorThreshold, 1);
      expect(a.warningThreshold, isNull);
    });

    test('equality compares all three thresholds', () {
      const a = UvmReportPassFailConfig();
      const b = UvmReportPassFailConfig();
      const c = UvmReportPassFailConfig(errorThreshold: 5);
      const d = UvmReportPassFailConfig(warningThreshold: 10);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
      expect(a, isNot(equals(d)));
    });

    test('asserts thresholds are non-negative', () {
      expect(
        () => UvmReportPassFailConfig(fatalThreshold: -1),
        throwsAssertionError,
      );
      expect(
        () => UvmReportPassFailConfig(errorThreshold: -1),
        throwsAssertionError,
      );
    });
  });

  group('CompositePassFailConfig', () {
    test('asserts at least one of allOf / anyOf is non-empty', () {
      expect(CompositePassFailConfig.new, throwsAssertionError);
    });

    test('equality is order-sensitive across allOf and anyOf', () {
      final a = CompositePassFailConfig(
        allOf: const [
          ExitCodePassFailConfig(),
          StringMatchPassFailConfig(passString: 'OK'),
        ],
      );
      final b = CompositePassFailConfig(
        allOf: const [
          ExitCodePassFailConfig(),
          StringMatchPassFailConfig(passString: 'OK'),
        ],
      );
      final c = CompositePassFailConfig(
        allOf: const [
          StringMatchPassFailConfig(passString: 'OK'),
          ExitCodePassFailConfig(),
        ],
      );
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
    });

    test('wraps allOf / anyOf in unmodifiable lists', () {
      final original = [const ExitCodePassFailConfig()];
      final composite = CompositePassFailConfig(allOf: original);
      expect(
        () => composite.allOf.add(const ExitCodePassFailConfig()),
        throwsUnsupportedError,
      );
    });
  });

  group('GoldenComparePassFailConfig', () {
    test('equality covers paths and profile', () {
      const a = GoldenComparePassFailConfig(
        dutPath: 'd',
        referencePath: 'r',
      );
      const b = GoldenComparePassFailConfig(
        dutPath: 'd',
        referencePath: 'r',
      );
      const c = GoldenComparePassFailConfig(
        dutPath: 'd',
        referencePath: 'r',
        profile: GoldenCompareProfile.riscvSignature,
      );
      const d = GoldenComparePassFailConfig(
        dutPath: 'd',
        referencePath: 'other',
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
      expect(a, isNot(d));
    });

    test('defaults to the generic profile', () {
      const config = GoldenComparePassFailConfig(
        dutPath: 'd',
        referencePath: 'r',
      );
      expect(config.profile, GoldenCompareProfile.generic);
    });

    test('forProfile seeds the conventional RISC-V filenames', () {
      final config = GoldenComparePassFailConfig.forProfile(
        GoldenCompareProfile.riscvSignature,
      );
      expect(config.dutPath, 'signature.dut.sig');
      expect(config.referencePath, 'signature.ref.sig');
      expect(config.profile, GoldenCompareProfile.riscvSignature);
    });

    test('forProfile refuses a profile with no conventional filenames', () {
      expect(
        () => GoldenComparePassFailConfig.forProfile(
          GoldenCompareProfile.generic,
        ),
        throwsArgumentError,
      );
    });
  });
}
