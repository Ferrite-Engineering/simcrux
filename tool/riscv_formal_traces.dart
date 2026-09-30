// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// The hand-authored RVFI traces of the riscv-formal demo corpus.
//
// `generate_riscv_formal_fixtures.dart` turns every [RvfiTraceSpec] here into
// the `engine_*/trace*.vcd` file its case declares. The *data* below is
// hand-authored — a fictional single-issue RV32I core, its retire log written
// out by hand — and the VCD text is mechanical, so review reads the retire
// sequence rather than a wall of binary literals.
//
// **Nothing here is derived from riscv-formal, SymbiYosys, or any other
// upstream project**, so the corpus carries no third-party attribution
// obligation. The shape is `sby`'s because that is the shape
// the corpus must exercise; the content is invented.
//
// ## Why these traces carry the whole RVFI bundle
//
// A counterexample trace is not only an input to SimCrux's driver — it is the
// artifact the counterexample hand-off ships to WaveCrux, whose consumer needs
// `rvfi_valid`, `rvfi_insn` and `rvfi_pc_rdata` before it will admit the trace
// carries an RVFI bundle at all, and the remaining channels before its Commit
// Inspector can show registers, memory and traps rather than a degraded view.
// An earlier revision of this corpus declared three channels — enough for the
// driver's "a VCD exists on disk" tests, not enough for anything downstream to
// read — and the cross-product demo silently landed nowhere. Hence
// [kRvfiChannelOrder]: the full 21-channel bundle, in riscv-formal's own port
// order.
//
// ## Why the step lattice is uniform
//
// A bounded model checker indexes its counterexample by *step*, and a waveform
// has only ticks. A receiver recovers the step lattice by measuring the gaps
// between RVFI transitions, so every value change in these traces lands on a
// multiple of [kStepPitchTicks] from tick 0 — step *k* is tick
// `k * kStepPitchTicks`, exactly. A trace whose activity is irregular carries
// no recoverable lattice and a coordinate against it must be declined.
//
// Pure Dart, no imports: this file is data.

/// Ticks per bounded-proof step. Step *k* is at tick `k * kStepPitchTicks`.
const int kStepPitchTicks = 10;

/// The riscv-formal RVFI channels these traces declare, in port order, with
/// the bit width each is dumped at for a 32-bit core.
///
/// The order is the declaration order in the emitted VCD; a reader binds by
/// name, so it is presentation only.
const Map<String, int> kRvfiChannelOrder = <String, int>{
  'rvfi_valid': 1,
  'rvfi_order': 64,
  'rvfi_insn': 32,
  'rvfi_trap': 1,
  'rvfi_halt': 1,
  'rvfi_intr': 1,
  'rvfi_mode': 2,
  'rvfi_ixl': 2,
  'rvfi_rs1_addr': 5,
  'rvfi_rs1_rdata': 32,
  'rvfi_rs2_addr': 5,
  'rvfi_rs2_rdata': 32,
  'rvfi_rd_addr': 5,
  'rvfi_rd_wdata': 32,
  'rvfi_pc_rdata': 32,
  'rvfi_pc_wdata': 32,
  'rvfi_mem_addr': 32,
  'rvfi_mem_rmask': 4,
  'rvfi_mem_wmask': 4,
  'rvfi_mem_rdata': 32,
  'rvfi_mem_wdata': 32,
};

/// One trace file: where it goes, and the full RVFI state at every step.
class RvfiTraceSpec {
  /// Creates a spec. [steps] is dense — index *k* is bounded-proof step *k*,
  /// and every entry names every channel in [kRvfiChannelOrder].
  const RvfiTraceSpec({
    required this.relativePath,
    required this.date,
    required this.scopeName,
    required this.steps,
  });

  /// Path of the emitted file relative to `verification/fixtures/riscv_formal`.
  final String relativePath;

  /// The `$date` the fixture claims. Fixed, so regeneration is a no-op diff.
  final String date;

  /// The module the RVFI ports are dumped under.
  final String scopeName;

  /// Full channel state per step, densely indexed by step number.
  final List<Map<String, int>> steps;

  /// Renders the VCD text, emitting a channel only when its value differs
  /// from the previous step — which is what a dumper does, and what makes the
  /// file readable as a sequence of events.
  String toVcd() {
    final ids = _identifiers();
    final out = StringBuffer()
      ..writeln(
        r'$date '
        '$date'
        r' $end',
      )
      ..writeln(
        r'$version SimCrux hand-authored riscv-formal demo fixture $end',
      )
      ..writeln(r'$timescale 1 ns $end')
      ..writeln(
        r'$scope module '
        '$scopeName'
        r' $end',
      );
    for (final entry in kRvfiChannelOrder.entries) {
      out.writeln(
        r'$var wire '
        '${entry.value} ${ids[entry.key]} ${entry.key}'
        r' $end',
      );
    }
    out
      ..writeln(r'$upscope $end')
      ..writeln(r'$enddefinitions $end');

    final previous = <String, int>{};
    for (var step = 0; step < steps.length; step++) {
      out.writeln('#${step * kStepPitchTicks}');
      final state = steps[step];
      for (final channel in kRvfiChannelOrder.keys) {
        final value = state[channel];
        if (value == null) {
          throw StateError('$relativePath step $step omits $channel');
        }
        if (step > 0 && previous[channel] == value) continue;
        final width = kRvfiChannelOrder[channel]!;
        final bits = _bits(value, width);
        out.writeln(
          width == 1 ? '$bits${ids[channel]}' : 'b$bits ${ids[channel]}',
        );
        previous[channel] = value;
      }
    }
    return out.toString();
  }

  /// One printable identifier per channel: `A`, `B`, … Letters only, so no
  /// identifier can be confused with a `#` timestamp or a `$` directive.
  Map<String, String> _identifiers() {
    final ids = <String, String>{};
    var code = 'A'.codeUnitAt(0);
    for (final channel in kRvfiChannelOrder.keys) {
      ids[channel] = String.fromCharCode(code++);
    }
    return ids;
  }

  static String _bits(int value, int width) =>
      value.toRadixString(2).padLeft(width, '0');
}

// ── the authored programs ────────────────────────────────────────────────────

/// The reset state: nothing retired, machine mode, XLEN 32.
///
/// `rvfi_mode` and `rvfi_ixl` are not gated on `rvfi_valid` in a real core, so
/// they hold their value for the whole trace and change only here.
Map<String, int> _reset() => <String, int>{
  for (final channel in kRvfiChannelOrder.keys) channel: 0,
  'rvfi_mode': 3,
  'rvfi_ixl': 1,
};

/// A retirement: `rvfi_valid` high with the architectural effect beside it.
Map<String, int> _retire({
  required int order,
  required int insn,
  required int pc,
  int? pcNext,
  int rs1Addr = 0,
  int rs1 = 0,
  int rs2Addr = 0,
  int rs2 = 0,
  int rdAddr = 0,
  int rd = 0,
  int memAddr = 0,
  int rmask = 0,
  int wmask = 0,
  int rdata = 0,
  int wdata = 0,
  bool trap = false,
  bool halt = false,
  bool intr = false,
}) => <String, int>{
  'rvfi_valid': 1,
  'rvfi_order': order,
  'rvfi_insn': insn,
  'rvfi_trap': trap ? 1 : 0,
  'rvfi_halt': halt ? 1 : 0,
  'rvfi_intr': intr ? 1 : 0,
  'rvfi_mode': 3,
  'rvfi_ixl': 1,
  'rvfi_rs1_addr': rs1Addr,
  'rvfi_rs1_rdata': rs1,
  'rvfi_rs2_addr': rs2Addr,
  'rvfi_rs2_rdata': rs2,
  'rvfi_rd_addr': rdAddr,
  'rvfi_rd_wdata': rd,
  'rvfi_pc_rdata': pc,
  'rvfi_pc_wdata': pcNext ?? pc + 4,
  'rvfi_mem_addr': memAddr,
  'rvfi_mem_rmask': rmask,
  'rvfi_mem_wmask': wmask,
  'rvfi_mem_rdata': rdata,
  'rvfi_mem_wdata': wdata,
};

/// A step in which nothing retired. The payload channels are don't-care while
/// `rvfi_valid` is low, so a dumper leaves them at their last value and only
/// the strobe moves — which is also what keeps the step lattice measurable.
Map<String, int> _bubble(Map<String, int> previous) => <String, int>{
  ...previous,
  'rvfi_valid': 0,
};

/// `insn_sub_counterexample` — the WaveCrux counterexample hand-off case.
///
/// The fictional core runs a six-instruction program and gets `SUB` wrong: at
/// **step 7** it retires `sub x5, x1, x2` with `x1 = 7`, `x2 = 5` and writes
/// **3** where the ISA says 2. That is the violation `sby.log` reports as
/// "Assert failed in rvfi_insn_sub: rvfi_spec_check" at depth 7, and the step
/// the CXP §9.9 coordinate addresses
/// (https://edacrux.app/cxp#sec-9-9).
///
/// Step 3 is a deliberate bubble: it is a real step of the trace that holds no
/// retirement, which is the case CXP §9.9.2
/// (https://edacrux.app/cxp#sec-9-9-2) prescribes a cursor-only landing for.
List<Map<String, int>> _insnSubCounterexampleSteps() {
  final steps = <Map<String, int>>[
    // Step 0 — the trace's initial state. Step 0 *is* the reset state by the
    // binding's own definition, which is what fixes the lattice's phase.
    _reset(),
    // Step 1 — addi x1, x0, 7
    _retire(order: 0, insn: 0x00700093, pc: 0x1000, rdAddr: 1, rd: 7),
    // Step 2 — addi x2, x0, 5
    _retire(order: 1, insn: 0x00500113, pc: 0x1004, rdAddr: 2, rd: 5),
  ];
  // Step 3 — a stall. Nothing retires.
  steps.add(_bubble(steps.last));
  steps.addAll(<Map<String, int>>[
    // Step 4 — lw x3, 32(x0), reading 42 out of data memory.
    _retire(
      order: 2,
      insn: 0x02002183,
      pc: 0x1008,
      rdAddr: 3,
      rd: 42,
      memAddr: 0x20,
      rmask: 0xF,
      rdata: 42,
    ),
    // Step 5 — sw x1, 36(x0), storing 7. Writes no register.
    _retire(
      order: 3,
      insn: 0x02102223,
      pc: 0x100C,
      rs2Addr: 1,
      rs2: 7,
      memAddr: 0x24,
      wmask: 0xF,
      wdata: 7,
    ),
    // Step 6 — add x4, x1, x2 = 12. Correct, so the proof walks past it.
    _retire(
      order: 4,
      insn: 0x00208233,
      pc: 0x1010,
      rs1Addr: 1,
      rs1: 7,
      rs2Addr: 2,
      rs2: 5,
      rdAddr: 4,
      rd: 12,
    ),
    // Step 7 — sub x5, x1, x2. 7 - 5 is 2; the core writes 3. THE BUG.
    _retire(
      order: 5,
      insn: 0x402082B3,
      pc: 0x1014,
      rs1Addr: 1,
      rs1: 7,
      rs2Addr: 2,
      rs2: 5,
      rdAddr: 5,
      rd: 3,
    ),
  ]);
  return steps;
}

/// `cover_multi_trace` trace0 — `rvfi_cover_retire` reached at step 3.
List<Map<String, int>> _coverRetireSteps() => <Map<String, int>>[
  _reset(),
  // Step 1 — addi x1, x0, 7
  _retire(order: 0, insn: 0x00700093, pc: 0x1000, rdAddr: 1, rd: 7),
  // Step 2 — addi x2, x0, 5
  _retire(order: 1, insn: 0x00500113, pc: 0x1004, rdAddr: 2, rd: 5),
  // Step 3 — add x4, x1, x2 = 12. The retirement the cover statement wanted.
  _retire(
    order: 2,
    insn: 0x00208233,
    pc: 0x1008,
    rs1Addr: 1,
    rs1: 7,
    rs2Addr: 2,
    rs2: 5,
    rdAddr: 4,
    rd: 12,
  ),
];

/// `cover_multi_trace` trace1 — `rvfi_cover_trap` reached at step 6.
///
/// Same program, run further, ending on an `ecall` that traps: `rvfi_trap` is
/// set and `rvfi_pc_wdata` is the handler entry rather than `pc + 4`.
List<Map<String, int>> _coverTrapSteps() {
  final steps = <Map<String, int>>[
    _reset(),
    _retire(order: 0, insn: 0x00700093, pc: 0x1000, rdAddr: 1, rd: 7),
    _retire(order: 1, insn: 0x00500113, pc: 0x1004, rdAddr: 2, rd: 5),
    _retire(
      order: 2,
      insn: 0x00208233,
      pc: 0x1008,
      rs1Addr: 1,
      rs1: 7,
      rs2Addr: 2,
      rs2: 5,
      rdAddr: 4,
      rd: 12,
    ),
  ];
  // Step 4 — a stall.
  steps.add(_bubble(steps.last));
  steps.addAll(<Map<String, int>>[
    // Step 5 — sw x4, 36(x0), storing 12.
    _retire(
      order: 3,
      insn: 0x02402223,
      pc: 0x100C,
      rs2Addr: 4,
      rs2: 12,
      memAddr: 0x24,
      wmask: 0xF,
      wdata: 12,
    ),
    // Step 6 — ecall. Traps into the handler at 0x1100.
    _retire(
      order: 4,
      insn: 0x00000073,
      pc: 0x1010,
      pcNext: 0x1100,
      trap: true,
    ),
  ]);
  return steps;
}

/// Every trace the corpus commits, in emission order.
final List<RvfiTraceSpec> kRiscvFormalTraces = <RvfiTraceSpec>[
  RvfiTraceSpec(
    relativePath: 'insn_sub_counterexample/engine_0/trace.vcd',
    date: 'Feb 01 2026 11:05:02',
    scopeName: 'rvfi',
    steps: _insnSubCounterexampleSteps(),
  ),
  RvfiTraceSpec(
    relativePath: 'cover_multi_trace/engine_0/trace0.vcd',
    date: 'Feb 01 2026 11:14:22',
    scopeName: 'rvfi',
    steps: _coverRetireSteps(),
  ),
  RvfiTraceSpec(
    relativePath: 'cover_multi_trace/engine_0/trace1.vcd',
    date: 'Feb 01 2026 11:14:23',
    scopeName: 'rvfi',
    steps: _coverTrapSteps(),
  ),
];
