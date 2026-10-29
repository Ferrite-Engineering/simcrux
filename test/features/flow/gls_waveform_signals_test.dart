// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/features/flow/flow_actions.dart';
import 'package:simcrux/services/flow/gate_level/gls_outcome.dart';
import 'package:simcrux/services/flow/gate_level/gls_result.dart';

GlsResultView _view({String? scope}) => GlsResultView(
  testId: 'gls/picorv32_smoke',
  outcome: GlsOutcome.xOnly,
  netlist: 'nl',
  simulator: 'icarus',
  strictX: false,
  gateVcd: '/runs/clk_25ns/gls/gate/ports.vcd',
  scope: scope,
);

void main() {
  group('glsWaveformSignals', () {
    test('suggests every signal under the dumped scope', () {
      // The port dump holds only the top-level ports, under the instance the
      // testbench drives; WaveCrux reads `<scope>.*` as that whole subtree.
      expect(FlowActions.glsWaveformSignals(_view(scope: 'tb.uut')), <String>[
        'tb.uut.*',
      ]);
    });

    test('suggests nothing when the result records no scope', () {
      expect(FlowActions.glsWaveformSignals(_view()), isEmpty);
      expect(FlowActions.glsWaveformSignals(_view(scope: '')), isEmpty);
    });
  });
}
