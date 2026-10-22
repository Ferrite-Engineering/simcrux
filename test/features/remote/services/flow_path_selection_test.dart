// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_cxp/crux_cxp.dart';
import 'package:crux_cxp_ui/crux_cxp_ui.dart';
import 'package:crux_flow/crux_flow.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/features/remote/services/flow_path_selection.dart';
import 'package:simcrux/services/flow/flow_worst_paths.dart';

import '../../flow/flow_panel_harness.dart';

// A worst path's cross-probe (Flow §6.7, §9.1, §9.4; CXP §8.2): one element
// per directed request, the one the target's kind row picks, and the whole
// path as one notify_selection. The rows are the panel harness's hand-built
// paths: rank 1 maps both ends to registers, rank 2 maps nothing.
//
// MUTATION: put the timing_path first among the candidates and NetCrux is
// sent the opaque path instead of the endpoint register; send the
// registers unrooted when the entry names its top and the rooted case fails.

PeerIdentity _peer(String product) => PeerIdentity(
  peerId: '$product-1-1',
  productName: product,
  productVersion: '1.2.0',
);

FlowPathTarget _target(FlowPathRow row, {String? top = 'adder'}) =>
    FlowPathTarget(
      run: nextpnrReading('t2', wns: -1.5, fmax: 40).run.ref,
      row: row,
      design: 'adder',
      top: top,
      designId: 'd1',
    );

const FlowPathRow _withStatements = FlowPathRow(
  path: TimingPath(
    rank: 3,
    startpoint: 'cnt_SB_DFF_Q',
    endpoint: 'cnt_SB_DFF_Q_7',
    delayPs: 1000,
    delayNs: 1,
    segments: <TimingSegment>[],
    origin: TimingPathOrigin.nextpnrReport,
  ),
  startpoint: RtlMapping(
    fidelity: MappingFidelity.register,
    register: 'u_div.cnt_q',
    spans: <SrcSpan>[SrcSpan(file: 'rtl/div.v', startLine: 12)],
  ),
  endpoint: RtlMapping(
    fidelity: MappingFidelity.statement,
    register: 'u_div.cnt_q',
    spans: <SrcSpan>[SrcSpan(file: 'rtl/div.v', startLine: 21)],
  ),
);

void main() {
  final mapped = flowPanelPaths().rows.first;
  final unmapped = flowPanelPaths().rows.last;

  group('the directed request', () {
    test('the endpoint register first, rooted at the top, and the opaque '
        'path last', () {
      final selection = flowPathCrossProbeSelection(_target(mapped));
      expect(
        selection.candidates.first,
        const ElementId(
          kind: ElementKind.signal,
          path: 'adder.sum_q',
        ),
      );
      expect(selection.candidates[1].path, 'adder.src_a');
      expect(
        selection.candidates.last,
        const ElementId(
          kind: ElementKind.timingPath,
          path: 't2/1',
        ),
      );
      expect(selection.metadata[cxpMappingMetadataKey], 'register');
      expect(selection.metadata[cxpDesignIdMetadataKey], 'd1');
    });

    test('each peer gets the kind its row picks: WaveCrux and NetCrux the '
        'endpoint register, LintCrux a statement', () {
      final selection = flowPathCrossProbeSelection(_target(_withStatements));
      ElementId? to(String product) =>
          crossProbeElementFor(selection, _peer(product));
      expect(to('wavecrux')!.path, 'adder.u_div.cnt_q');
      expect(to('netcrux')!.kind, ElementKind.signal);
      expect(to('netcrux')!.path, 'adder.u_div.cnt_q');
      expect(to('lintcrux')!.kind, ElementKind.source);
      expect(to('lintcrux')!.path, 'rtl/div.v:21');
    });

    test('an unmapped path offers NetCrux only the path, which it places '
        'from the selection', () {
      final selection = flowPathCrossProbeSelection(_target(unmapped));
      expect(selection.candidates, <ElementId>[
        const ElementId(kind: ElementKind.timingPath, path: 't2/2'),
      ]);
      expect(selection.metadata[cxpMappingMetadataKey], 'unmapped');
    });

    test('without the top, the names are the ones relative to it', () {
      final selection = flowPathCrossProbeSelection(
        _target(mapped, top: null),
      );
      expect(selection.candidates.first.path, 'sum_q');
    });
  });

  group('the notify_selection', () {
    test('timing_path, then the registers in path order, then the '
        'statements', () {
      final message = flowPathNotifySelection(_target(_withStatements));
      expect(message.elements.map((e) => e.kind), <ElementKind>[
        ElementKind.timingPath,
        ElementKind.signal,
        ElementKind.source,
        ElementKind.source,
      ]);
      // One register at both ends is named once.
      expect(message.elements[1].path, 'adder.u_div.cnt_q');
      expect(message.elements[2].path, 'rtl/div.v:21');
      expect(message.elements[3].path, 'rtl/div.v:12');
      expect(message.metadata[cxpMappingMetadataKey], 'statement');
    });
  });

  group('paths through a register', () {
    test('rooted, relative or bare, with or without a bit select', () {
      for (final name in <String>[
        'adder.sum_q',
        'sum_q',
        'sum_q[3]',
        'adder.src_a',
      ]) {
        expect(
          flowPathThroughRegister(mapped, name, top: 'adder'),
          isTrue,
          reason: name,
        );
      }
      expect(
        flowPathThroughRegister(mapped, 'adder.cnt_q', top: 'adder'),
        isFalse,
      );
      expect(flowPathThroughRegister(unmapped, 'sum_q'), isFalse);
      expect(
        flowPathThroughRegister(_withStatements, 'top.u_div.cnt_q'),
        isTrue,
      );
      expect(flowPathThroughRegister(_withStatements, 'u_x.cnt_q'), isFalse);
    });
  });
}
