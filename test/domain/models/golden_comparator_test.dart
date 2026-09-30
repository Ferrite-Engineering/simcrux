// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/golden_compare_profile.dart';
import 'package:simcrux/domain/models/golden_comparator.dart';

// Unit coverage for the pure comparator that both the `golden_compare`
// detector and the `riscv_arch` driver call. Everything here is string in,
// value out — no filesystem, no scheduler.
//
// MUTATION: change the `<` to `<=` in the first-divergence loop, or make
// the empty-vs-empty branch report `matched: true`, and this file fails.
void main() {
  const canonical = 'deadbeef\n0000000f\n12345678\ncafebabe\n';

  group('tokenize', () {
    test('splits on any whitespace run and drops empties', () {
      expect(
        GoldenComparator.tokenize('  a\n\nb\t c \r\n d  '),
        ['a', 'b', 'c', 'd'],
      );
    });

    test('CRLF, trailing newline and blank lines tokenize identically', () {
      expect(
        GoldenComparator.tokenize('a\r\nb\r\n\r\n   \r\n'),
        GoldenComparator.tokenize('a\nb'),
      );
    });

    test('a dump with no words yields an empty list', () {
      expect(GoldenComparator.tokenize(''), isEmpty);
      expect(GoldenComparator.tokenize('   \n\n\t\r\n'), isEmpty);
    });
  });

  group('normalize', () {
    test('generic profile is the identity — case and 0x are significant', () {
      const p = GoldenCompareProfile.generic;
      expect(GoldenComparator.normalize('0XDEADBEEF', p), '0XDEADBEEF');
      expect(GoldenComparator.normalize('DeadBeef', p), 'DeadBeef');
    });

    test('riscv profile folds case and an optional 0x prefix', () {
      const p = GoldenCompareProfile.riscvSignature;
      expect(GoldenComparator.normalize('0XDEADBEEF', p), 'deadbeef');
      expect(GoldenComparator.normalize('0xdeadbeef', p), 'deadbeef');
      expect(GoldenComparator.normalize('DEADBEEF', p), 'deadbeef');
    });

    test('riscv profile does NOT strip leading zeros', () {
      // Signature words are fixed width, so 0000dead and dead are
      // genuinely different words. Folding them would hide a real
      // divergence.
      const p = GoldenCompareProfile.riscvSignature;
      expect(
        GoldenComparator.normalize('0000dead', p),
        isNot(GoldenComparator.normalize('dead', p)),
      );
    });

    test('a bare 0x is left alone rather than folded to empty', () {
      const p = GoldenCompareProfile.riscvSignature;
      expect(GoldenComparator.normalize('0x', p), '0x');
      expect(GoldenComparator.normalize('0X', p), '0x');
    });
  });

  group('compare — match', () {
    test('identical dumps match', () {
      final r = GoldenComparator.compare(dut: canonical, reference: canonical);
      expect(r.matched, isTrue);
      expect(r.mismatchOffset, isNull);
      expect(r.dutWord, isNull);
      expect(r.refWord, isNull);
      expect(r.dutWords, 4);
      expect(r.refWords, 4);
      expect(r.lengthMismatch, isFalse);
    });

    test('whitespace variance alone matches under either profile', () {
      const respaced = ' deadbeef \r\n\r\n0000000f\t12345678\n\n cafebabe\n';
      for (final profile in GoldenCompareProfile.values) {
        final r = GoldenComparator.compare(
          dut: respaced,
          reference: canonical,
          profile: profile,
        );
        expect(r.matched, isTrue, reason: 'profile ${profile.wireName}');
      }
    });

    test('hex-format variance matches only under the riscv profile', () {
      const respelled = '0XDEADBEEF\n0X0000000F\n0X12345678\n0XCAFEBABE\n';
      expect(
        GoldenComparator.compare(
          dut: respelled,
          reference: canonical,
          profile: GoldenCompareProfile.riscvSignature,
        ).matched,
        isTrue,
      );
      final generic = GoldenComparator.compare(
        dut: respelled,
        reference: canonical,
      );
      expect(generic.matched, isFalse);
      expect(generic.mismatchOffset, 0);
      expect(generic.dutWord, '0XDEADBEEF');
      expect(generic.refWord, 'deadbeef');
    });
  });

  group('compare — divergence', () {
    test('first-word mismatch reports offset 0 with both words as dumped', () {
      final r = GoldenComparator.compare(
        dut: 'deadbee0\n0000000f\n12345678\ncafebabe\n',
        reference: canonical,
        profile: GoldenCompareProfile.riscvSignature,
      );
      expect(r.matched, isFalse);
      expect(r.mismatchOffset, 0);
      expect(r.dutWord, 'deadbee0');
      expect(r.refWord, 'deadbeef');
      expect(r.lengthMismatch, isFalse);
    });

    test('mid-file mismatch reports the FIRST divergence, not the last', () {
      final r = GoldenComparator.compare(
        dut: 'deadbeef\n0000000f\nAAAAAAAA\nBBBBBBBB\n',
        reference: canonical,
        profile: GoldenCompareProfile.riscvSignature,
      );
      expect(r.mismatchOffset, 2);
      expect(r.dutWord, 'AAAAAAAA');
      expect(r.refWord, '12345678');
    });

    test('carries the ORIGINAL spelling, not the normalized form', () {
      final r = GoldenComparator.compare(
        dut: '0XAAAAAAAA\n',
        reference: '0xbbbbbbbb\n',
        profile: GoldenCompareProfile.riscvSignature,
      );
      expect(r.dutWord, '0XAAAAAAAA');
      expect(r.refWord, '0xbbbbbbbb');
    });
  });

  group('compare — length divergence', () {
    test('short DUT: offset is where it ran out; only ref carries a word', () {
      final r = GoldenComparator.compare(
        dut: 'deadbeef\n0000000f\n',
        reference: canonical,
      );
      expect(r.matched, isFalse);
      expect(r.lengthMismatch, isTrue);
      expect(r.mismatchOffset, 2);
      expect(r.dutWord, isNull);
      expect(r.refWord, '12345678');
      expect(r.dutWords, 2);
      expect(r.refWords, 4);
    });

    test('long DUT: only the DUT carries a word at the offset', () {
      final r = GoldenComparator.compare(
        dut:
            '$canonical'
            'ffffffff\n',
        reference: canonical,
      );
      expect(r.matched, isFalse);
      expect(r.mismatchOffset, 4);
      expect(r.dutWord, 'ffffffff');
      expect(r.refWord, isNull);
      expect(r.dutWords, 5);
      expect(r.refWords, 4);
    });

    test('a word divergence inside the common prefix wins over length', () {
      final r = GoldenComparator.compare(
        dut: 'deadbeef\nffffffff\n',
        reference: canonical,
      );
      expect(r.mismatchOffset, 1);
      expect(r.dutWord, 'ffffffff');
      expect(r.refWord, '0000000f');
    });
  });

  group('compare — empty dumps never match', () {
    test('empty DUT against a real golden', () {
      final r = GoldenComparator.compare(dut: '', reference: canonical);
      expect(r.matched, isFalse);
      expect(r.dutEmpty, isTrue);
      expect(r.refEmpty, isFalse);
      expect(r.mismatchOffset, 0);
      expect(r.dutWord, isNull);
      expect(r.refWord, 'deadbeef');
    });

    test('empty golden against a real DUT', () {
      final r = GoldenComparator.compare(dut: canonical, reference: '');
      expect(r.matched, isFalse);
      expect(r.refEmpty, isTrue);
      expect(r.mismatchOffset, 0);
      expect(r.dutWord, 'deadbeef');
      expect(r.refWord, isNull);
    });

    test('BOTH empty is a failure, not a vacuous pass', () {
      // The whole point: "nothing == nothing" is exactly the
      // shape a broken run produces, and reporting it as a match would
      // let a core that emitted no signature at all report green.
      final r = GoldenComparator.compare(dut: '', reference: '   \n\n');
      expect(r.matched, isFalse);
      expect(r.dutWords, 0);
      expect(r.refWords, 0);
      expect(r.mismatchOffset, isNull, reason: 'no word to point at');
    });
  });

  group('toMetrics', () {
    test('uses the reserved golden.* keys and no riscv-specific ones', () {
      final metrics = GoldenComparator.compare(
        dut: 'aa\nbb\n',
        reference: 'aa\ncc\n',
      ).toMetrics();
      expect(metrics, {
        'golden.dut_words': '2',
        'golden.ref_words': '2',
        'golden.mismatch_offset': '1',
        'golden.dut_value': 'bb',
        'golden.ref_value': 'cc',
      });
      expect(metrics.keys, everyElement(isNot(contains('riscv'))));
      expect(GoldenComparator.kMetricKeys, containsAll(metrics.keys));
    });

    test('word counts are always emitted, even on a clean match', () {
      final metrics = GoldenComparator.compare(
        dut: canonical,
        reference: canonical,
      ).toMetrics();
      expect(metrics, {'golden.dut_words': '4', 'golden.ref_words': '4'});
    });

    test('omits the side that has no word at the offset', () {
      final metrics = GoldenComparator.compare(
        dut: 'aa\n',
        reference: 'aa\nbb\n',
      ).toMetrics();
      expect(metrics.containsKey('golden.dut_value'), isFalse);
      expect(metrics['golden.ref_value'], 'bb');
      // The counts are what let a consumer tell a length divergence from
      // a content divergence without re-reading pruned files.
      expect(metrics['golden.dut_words'], '1');
      expect(metrics['golden.ref_words'], '2');
    });
  });

  group('value semantics', () {
    test('== and hashCode cover every field', () {
      const a = GoldenComparison(matched: false, dutWords: 2, refWords: 3);
      const b = GoldenComparison(matched: false, dutWords: 2, refWords: 3);
      const c = GoldenComparison(
        matched: false,
        dutWords: 2,
        refWords: 3,
        mismatchOffset: 2,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });

    test('toString names the offset and both words', () {
      final r = GoldenComparator.compare(dut: 'aa\n', reference: 'bb\n');
      expect(r.toString(), contains('offset: 0'));
      expect(r.toString(), contains('aa'));
      expect(r.toString(), contains('bb'));
    });
  });
}
