// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/simulator_policy.dart';

void main() {
  group('SimulatorPolicy', () {
    test('none restricts nothing and names no fallback', () {
      expect(SimulatorPolicy.none.fallbackSimulatorId, isNull);
      expect(SimulatorPolicy.none.allowedSimulatorIds, isNull);
      expect(SimulatorPolicy.none.allows('anything'), isTrue);
    });

    test('an allow-list allows exactly its members', () {
      const policy = SimulatorPolicy(
        allowedSimulatorIds: {'icarus', 'verilator'},
      );
      expect(policy.allows('icarus'), isTrue);
      expect(policy.allows('verilator'), isTrue);
      expect(policy.allows('ghdl'), isFalse);
    });

    test('an empty allow-list allows nothing', () {
      const policy = SimulatorPolicy(allowedSimulatorIds: <String>{});
      expect(policy.allows('icarus'), isFalse);
    });

    test('value equality ignores allow-list order', () {
      const a = SimulatorPolicy(
        fallbackSimulatorId: 'icarus',
        allowedSimulatorIds: {'icarus', 'verilator'},
      );
      const b = SimulatorPolicy(
        fallbackSimulatorId: 'icarus',
        allowedSimulatorIds: {'verilator', 'icarus'},
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(const SimulatorPolicy(fallbackSimulatorId: 'icarus')));
      expect(
        const SimulatorPolicy(allowedSimulatorIds: <String>{}),
        isNot(SimulatorPolicy.none),
      );
      expect(a.toString(), contains('icarus'));
    });
  });
}
