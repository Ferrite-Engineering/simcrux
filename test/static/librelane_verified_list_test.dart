// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// The docs-site list of LibreLane releases read as verified is generated from
// crux_flow's `kLibreLane30Verified` and committed; this keeps the committed
// file equal to what the generator makes of the constant, and keeps the page
// that includes it from growing a second, hand-written list.
//
// MUTATION: change a release in docs-site/generated/librelane-verified.md, or
// widen kLibreLane30Verified without regenerating, and this fails.

import 'dart:io';

import 'package:crux_flow/crux_flow.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/generate_librelane_verified_list.dart' as gen;

void main() {
  test('the committed list is what the generator makes of the constant', () {
    final committed = File(gen.kDefaultOut);
    expect(committed.existsSync(), isTrue, reason: gen.kDefaultOut);
    expect(
      committed.readAsStringSync(),
      gen.librelaneVerifiedList(kLibreLane30Verified),
      reason:
          'run `dart run tool/generate_librelane_verified_list.dart` and '
          'commit the result',
    );
  });

  test('the list names exactly the releases the reader verifies', () {
    final text = File(gen.kDefaultOut).readAsStringSync();
    final listed = RegExp(
      r'^\| (\d+\.\d+\.\d+) \| Verified \|$',
      multiLine: true,
    ).allMatches(text).map((m) => m.group(1)).toList();
    expect(listed, <String>['3.0.15', '3.0.16']);
    for (final raw in listed) {
      expect(
        kLibreLane30Verified.contains(LibreLaneVersion.tryParse(raw)!),
        isTrue,
      );
    }
  });

  test('flow-librelane.md includes the generated list, not a copy', () {
    final page = File('docs-site/docs/flow-librelane.md').readAsStringSync();
    expect(page, contains('--8<-- "librelane-verified.md"'));
    expect(page, isNot(contains('3.0.15')));
    expect(page, isNot(contains('3.0.16')));
  });
}
