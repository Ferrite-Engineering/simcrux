// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/formal_verdict.dart';
import 'package:simcrux/domain/enums/riscv_formal_verdict.dart';
import 'package:simcrux/domain/enums/test_status.dart';

/// Pins the formal verdict's wire contract.
///
/// The wire names are stored verbatim in trend databases and exported
/// reports written by earlier builds, and the RISC-V track's rows carry
/// them already. Renaming, reordering or adding a token here silently
/// changes what an old row means, so the full list is spelled out rather
/// than derived.
///
/// MUTATION: rename `NO_OUTCOME`, add a value, or map `unknown` to
/// `TestStatus.pass`, and this goes red.
void main() {
  const wire = <FormalVerdict, String>{
    FormalVerdict.pass: 'PASS',
    FormalVerdict.fail: 'FAIL',
    FormalVerdict.unknown: 'UNKNOWN',
    FormalVerdict.error: 'ERROR',
    FormalVerdict.timeout: 'TIMEOUT',
    FormalVerdict.noOutcome: 'NO_OUTCOME',
  };

  test('every value has its pinned wire name, and no value is missing', () {
    expect(FormalVerdict.values.toSet(), wire.keys.toSet());
    for (final MapEntry(key: verdict, value: name) in wire.entries) {
      expect(verdict.wireName, name, reason: '$verdict');
    }
  });

  test('wire names round-trip, ignoring case and surrounding space', () {
    for (final MapEntry(key: verdict, value: name) in wire.entries) {
      expect(FormalVerdict.fromWireName(name), verdict);
      expect(FormalVerdict.fromWireName(' ${name.toLowerCase()} '), verdict);
    }
  });

  test('only PASS is proved and only PASS maps to TestStatus.pass', () {
    for (final verdict in FormalVerdict.values) {
      final isPass = verdict == FormalVerdict.pass;
      expect(verdict.proved, isPass, reason: '$verdict');
      expect(
        verdict.status,
        isPass ? TestStatus.pass : TestStatus.fail,
        reason: '$verdict must never read green unless it is PASS',
      );
    }
  });

  test('an engine TIMEOUT is not TestStatus.timeout', () {
    expect(FormalVerdict.timeout.status, isNot(TestStatus.timeout));
  });

  group('the Unrecognised path', () {
    // A verdict metric written by a newer build, or a token this build has
    // never seen, parses to null. Null is the Unrecognised bucket: it lands
    // conservative and never in Proved.
    const unrecognised = <Object?>[
      'PROVED',
      'PASSED',
      'COUNTEREXAMPLE',
      'REACHED',
      'PASS,',
      '',
      ' ',
      null,
      0,
      true,
    ];
    for (final raw in unrecognised) {
      test('"$raw" is unrecognised, not a verdict', () {
        expect(FormalVerdict.fromWireName(raw), isNull);
      });
    }
  });

  test('RiscvFormalVerdict is the same type, not a copy', () {
    expect(RiscvFormalVerdict.values, same(FormalVerdict.values));
    expect(RiscvFormalVerdict.fail, same(FormalVerdict.fail));
    expect(RiscvFormalVerdict.fromWireName('FAIL'), FormalVerdict.fail);
  });
}
