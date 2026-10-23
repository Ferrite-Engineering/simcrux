// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_flow/crux_flow.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/flow_config.dart';
import 'package:simcrux/domain/models/test_spec.dart';

/// `TestSpec.flow`: carried by copyWith, part of equality and of the hash.
/// The hash is `Object.hashAll` over the fields, because with `flow` they
/// are past `Object.hash`'s twenty-argument ceiling.
void main() {
  FlowEntry entry(String device) => FlowEntry(
    name: 'n',
    kind: FlowKind.nextpnr,
    family: NextpnrFamily.ice40,
    device: device,
    top: 'top',
    sources: const ['a.v'],
    handoff: const {
      'nextpnr_gui': ['nextpnr-ice40', '--gui'],
    },
  );

  TestSpec spec({FlowEntry? flow, List<int>? seeds}) => TestSpec(
    id: 'flow/n',
    name: 'n',
    suiteName: 'flow',
    simulatorId: 'nextpnr',
    top: 'top',
    seeds: seeds,
    flow: flow,
  );

  test('equal flow entries make equal specs with equal hashes', () {
    final a = spec(flow: entry('up5k'));
    final b = spec(flow: entry('up5k'));
    expect(a, b);
    expect(a.hashCode, b.hashCode);
  });

  test('a different flow entry makes a different spec', () {
    expect(spec(flow: entry('up5k')), isNot(spec(flow: entry('hx8k'))));
    expect(spec(flow: entry('up5k')), isNot(spec()));
  });

  test('copyWith keeps the flow entry', () {
    final s = spec(flow: entry('up5k'));
    expect(s.copyWith(name: 'm').flow, entry('up5k'));
  });

  test('a missing and an empty sweep are unequal but may share a hash', () {
    expect(spec(), isNot(spec(seeds: const [])));
  });

  test('extra tops are carried, compared and hashed, and empty by default', () {
    final plain = spec();
    final extra = plain.copyWith(extraTops: const ['gls_portdump']);
    expect(plain.extraTops, isEmpty);
    expect(extra.extraTops, ['gls_portdump']);
    expect(extra, isNot(plain));
    expect(
      extra,
      plain.copyWith(extraTops: const ['gls_portdump']),
    );
    expect(
      extra.hashCode,
      plain.copyWith(extraTops: const ['gls_portdump']).hashCode,
    );
    expect(extra.copyWith(name: 'm').extraTops, ['gls_portdump']);
  });

  test('extra compile arguments are carried, compared and hashed, and empty '
      'by default', () {
    final plain = spec();
    const args = ['-gspecify', '-ginterconnect'];
    final extra = plain.copyWith(extraCompileArgs: args);
    expect(plain.extraCompileArgs, isEmpty);
    expect(extra.extraCompileArgs, args);
    expect(extra, isNot(plain));
    expect(extra, plain.copyWith(extraCompileArgs: args));
    expect(extra.hashCode, plain.copyWith(extraCompileArgs: args).hashCode);
    expect(extra.copyWith(name: 'm').extraCompileArgs, args);
  });
}
