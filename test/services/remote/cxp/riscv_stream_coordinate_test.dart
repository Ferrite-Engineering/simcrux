// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

@TestOn('vm')
library;

import 'package:crux_cxp/crux_cxp.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/services/remote/cxp/riscv_stream_coordinate.dart';
import 'package:simcrux/services/simulator/riscv_arch_driver.dart';
import 'package:simcrux/services/simulator/riscv_formal_driver.dart';
import 'package:simcrux/services/simulator/riscv_result_kind.dart';

/// The CXP stream coordinate's producer half (CXP §9.9,
/// https://edacrux.app/cxp#sec-9-9).
///
/// Most of this file asserts that the producer says **nothing**. That is the
/// point: §9.9 rule 3 forbids emitting a `sequence_index` the producer
/// cannot state in the named stream's own index space, and the interesting
/// question in every case below is whether SimCrux actually knows the number
/// it would be sending.
void main() {
  TestResult resultWith({
    Map<String, String> metrics = const <String, String>{},
    String? waveformPath,
    TestStatus status = TestStatus.fail,
  }) {
    final now = DateTime.utc(2026, 8, 2);
    return TestResult(
      testId: 'insn_sub_ch0',
      runId: 'run-1',
      status: status,
      startedAt: now,
      finishedAt: now,
      waveformPath: waveformPath,
      metrics: metrics,
    );
  }

  Map<String, String> formalMetrics({
    String verdict = 'FAIL',
    String? depthReached = '7',
    String? channel = 'ch0',
    String? depthConfigured = '20',
    String? mode,
    String? isa,
  }) => <String, String>{
    RiscvFormalDriver.kMetricVerdict: verdict,
    RiscvFormalDriver.kMetricCheck: 'insn_sub_ch0',
    RiscvFormalDriver.kMetricGroup: 'insn',
    RiscvFormalDriver.kMetricChannel: ?channel,
    RiscvFormalDriver.kMetricDepthReached: ?depthReached,
    RiscvFormalDriver.kMetricDepthConfigured: ?depthConfigured,
    RiscvArchDriver.kMetricMode: ?mode,
    RiscvArchDriver.kMetricIsa: ?isa,
  };

  group('a failing bounded proof — the one row that can state an index', () {
    test('emits the trace-step stream, the depth as the index, and the '
        'RVFI channel as sub_id', () {
      final coord = riscvStreamCoordinateFor(
        resultWith(metrics: formalMetrics(), waveformPath: '/w/trace.vcd'),
      );
      expect(coord, isNotNull);
      expect(
        coord!.streamId,
        CxpStreamCoordinate.riscvFormalTraceStepStreamId,
      );
      expect(coord.sequenceIndex, 7);
      expect(coord.subId, 'ch0');
    });

    test('is NOT the RVFI retire stream — SimCrux does not know '
        'rvfi_order', () {
      // An obvious design is `sequence_index` = `rvfi_order`. Converting
      // "the assertion fired at cycle 7" into "the Nth retirement" needs the
      // trace, and how many instructions a core retires in seven cycles is a
      // property of the core under proof. Emitting the retire stream here
      // would be a fabricated index that resolves to the wrong instruction.
      final coord = riscvStreamCoordinateFor(
        resultWith(metrics: formalMetrics(), waveformPath: '/w/trace.vcd'),
      );
      expect(
        coord!.streamId,
        isNot(CxpStreamCoordinate.riscvRvfiRetireStreamId),
      );
    });

    test('carries the check, group, verdict and configured depth as '
        'advisory attributes, never as identity', () {
      final coord = riscvStreamCoordinateFor(
        resultWith(
          metrics: formalMetrics(isa: 'rv32imc'),
          waveformPath: '/w/trace.vcd',
        ),
      );
      expect(
        coord!.attributes[RiscvFormalDriver.kMetricCheck],
        'insn_sub_ch0',
      );
      expect(coord.attributes[RiscvFormalDriver.kMetricGroup], 'insn');
      expect(coord.attributes[RiscvFormalDriver.kMetricVerdict], 'FAIL');
      expect(
        coord.attributes[RiscvFormalDriver.kMetricDepthConfigured],
        '20',
        reason: 'the pair is the fact — "step 7 of 20", never a bare 7',
      );
      expect(
        coord.attributes[CxpStreamCoordinate.riscvIsaAttribute],
        'rv32imc',
      );
      // Identity is the triple alone. Nothing in `attributes` may be needed
      // to resolve it, so dropping the whole bag must not change where the
      // receiver lands.
      final bare = riscvStreamCoordinateFor(
        resultWith(
          metrics: <String, String>{
            RiscvFormalDriver.kMetricVerdict: 'FAIL',
            RiscvFormalDriver.kMetricDepthReached: '7',
            RiscvFormalDriver.kMetricChannel: 'ch0',
          },
          waveformPath: '/w/trace.vcd',
        ),
      );
      expect(bare!.streamId, coord.streamId);
      expect(bare.sequenceIndex, coord.sequenceIndex);
      expect(bare.subId, coord.subId);
    });

    test('omits sub_id rather than inventing a channel', () {
      final coord = riscvStreamCoordinateFor(
        resultWith(
          metrics: formalMetrics(channel: null),
          waveformPath: '/w/trace.vcd',
        ),
      );
      expect(coord!.subId, isNull);
    });

    test('step 0 is a real coordinate — the initial state is where some '
        'counterexamples live', () {
      final coord = riscvStreamCoordinateFor(
        resultWith(
          metrics: formalMetrics(depthReached: '0'),
          waveformPath: '/w/trace.vcd',
        ),
      );
      expect(coord, isNotNull);
      expect(coord!.sequenceIndex, 0);
    });
  });

  group('a demo row emits, and that is a decision', () {
    test('a replayed counterexample still produces a coordinate', () {
      // The VCD is on disk and the step came from the replayed log, so the
      // coordinate resolves — and resolvability is what the honesty rule is
      // about. Suppressing it would break the offline conference demo for no
      // gain in truthfulness.
      final coord = riscvStreamCoordinateFor(
        resultWith(
          metrics: formalMetrics(mode: 'demo'),
          waveformPath: '/w/trace.vcd',
        ),
      );
      expect(coord, isNotNull);
    });

    test('and it labels itself demo, so the receiver never presents '
        'replayed evidence as measured', () {
      final coord = riscvStreamCoordinateFor(
        resultWith(
          metrics: formalMetrics(mode: 'demo'),
          waveformPath: '/w/trace.vcd',
        ),
      );
      expect(
        coord!.attributes[CxpStreamCoordinate.riscvModeAttribute],
        'demo',
      );
    });
  });

  group('no coordinate — absence beats approximation', () {
    test('an architectural-compatibility row, even a failing one with a '
        'signature offset', () {
      // The reason this is not "diverged at instruction N": a signature is
      // machine state dumped at test end, not a retire log. Word 12 is the
      // 12th value stored to the signature region and recovering which
      // retirement stored it needs the trace — which `riscv_arch` does not
      // produce (`supportsVcd: false`).
      final coord = riscvStreamCoordinateFor(
        resultWith(
          metrics: <String, String>{
            RiscvArchDriver.kMetricSignatureWordSize: '4',
            RiscvArchDriver.kMetricSignatureByteOffset: '48',
            RiscvArchDriver.kMetricTest: 'rv32i_m/I/src/add-01.S',
            RiscvArchDriver.kMetricIsa: 'rv32i',
          },
          waveformPath: '/w/somehow.vcd',
        ),
      );
      expect(coord, isNull);
    });

    test('a proved property — there is no counterexample to point at', () {
      final coord = riscvStreamCoordinateFor(
        resultWith(
          metrics: formalMetrics(verdict: 'PASS'),
          waveformPath: '/w/trace.vcd',
          status: TestStatus.pass,
        ),
      );
      expect(coord, isNull);
    });

    test('an undecided or errored proof — a coordinate would imply a '
        'counterexample exists', () {
      for (final verdict in const <String>[
        'UNKNOWN',
        'TIMEOUT',
        'ERROR',
        'NO_OUTCOME',
      ]) {
        expect(
          riscvStreamCoordinateFor(
            resultWith(
              metrics: formalMetrics(verdict: verdict),
              waveformPath: '/w/trace.vcd',
            ),
          ),
          isNull,
          reason: '$verdict learned nothing; it must not point at a trace',
        );
      }
    });

    test('a verdict token this build does not recognise', () {
      // Conservative on the same principle the Pro formal dashboard applies: a
      // row written by a newer SimCrux must never be read as a
      // counterexample by an older one.
      expect(
        riscvStreamCoordinateFor(
          resultWith(
            metrics: formalMetrics(verdict: 'REFUTED_MODULO_THEORIES'),
            waveformPath: '/w/trace.vcd',
          ),
        ),
        isNull,
      );
    });

    test('a counterexample whose trace did not resolve on disk', () {
      // The formal driver records `riscv.formal.trace_unresolved` and leaves waveformPath
      // null precisely so this case is distinguishable. A coordinate into a
      // file the receiver cannot open is worse than an honest absence.
      final coord = riscvStreamCoordinateFor(
        resultWith(
          metrics: <String, String>{
            ...formalMetrics(),
            RiscvFormalDriver.kMetricTraceUnresolved:
                'insn_sub_ch0/engine_0/trace.vcd',
          },
        ),
      );
      expect(coord, isNull);
    });

    test('a counterexample with no reported depth — step 0 is a real, '
        'wrong answer, not a default', () {
      final coord = riscvStreamCoordinateFor(
        resultWith(
          metrics: formalMetrics(depthReached: null),
          waveformPath: '/w/trace.vcd',
        ),
      );
      expect(coord, isNull);
    });

    test('a counterexample whose depth is not a number', () {
      for (final bad in const <String>['', 'deep', '-1', '7.5']) {
        expect(
          riscvStreamCoordinateFor(
            resultWith(
              metrics: formalMetrics(depthReached: bad),
              waveformPath: '/w/trace.vcd',
            ),
          ),
          isNull,
          reason: 'depth_reached="$bad" must not become an index',
        );
      }
    });

    test('an ordinary simulation result with no RISC-V metrics at all', () {
      expect(
        riscvStreamCoordinateFor(resultWith(waveformPath: '/w/dump.vcd')),
        isNull,
      );
    });
  });

  group('RiscvResultKind — the discriminators, now open core', () {
    test('partitions a mixed run: nothing claimed twice, nothing '
        'dropped', () {
      final rows = <TestResult>[
        resultWith(metrics: formalMetrics()),
        resultWith(
          metrics: <String, String>{
            RiscvArchDriver.kMetricSignatureWordSize: '4',
          },
        ),
        resultWith(),
      ];
      final formal = rows.where(RiscvResultKind.isFormalPropertyRow).toList();
      final arch = rows.where(RiscvResultKind.isArchCompatibilityRow).toList();
      expect(formal.length, 1);
      expect(arch.length, 1);
      expect(
        formal.toSet().intersection(arch.toSet()),
        isEmpty,
        reason: 'a row claimed by both discriminators is double-counted',
      );
    });

    test('a formal row carrying a signature word size is still only a '
        'formal row', () {
      final row = resultWith(
        metrics: <String, String>{
          ...formalMetrics(),
          RiscvArchDriver.kMetricSignatureWordSize: '4',
        },
      );
      expect(RiscvResultKind.isFormalPropertyRow(row), isTrue);
      expect(RiscvResultKind.isArchCompatibilityRow(row), isFalse);
    });

    test('a proof with no verdict line at all is still a formal row', () {
      final row = resultWith(metrics: formalMetrics(verdict: 'NO_OUTCOME'));
      expect(RiscvResultKind.isFormalPropertyRow(row), isTrue);
    });
  });
}
