# G8: functional gate-level simulation on real LibreLane netlists, measured

**Result: Icarus passes and Verilator fails. Outcome: `verilator_fails_icarus_passes`.**
Functional gate-level simulation ships for Icarus only in 1.2; a Verilator
test's gate-level request runs both its RTL and its gate run under Icarus,
never a comparison across simulators.

The rule was fixed before the measurement and is applied as written. On
LibreLane's sky130A runs of the small design and of the 500-plus flip-flop
mapping-gate design, rerun a self-checking testbench against `final/nl` with
the cell models found from the run's own records. **Pass:** the RTL testbench
binds the netlist unchanged, the models resolve, and Icarus (`-DFUNCTIONAL
-DUNIT_DELAY=#1`) and Verilator (`--binary --timing`) each report 0 real
differences, every difference classified (x-asymmetry apart). **Verilator
fails, Icarus passes:** gate-level simulation ships Icarus-only. **Ports do
not bind:** a generated port adapter is researched first. The threshold does
not move.

| Check | path_adder (73 flip-flops) | PicoRV32 (1,597 flip-flops) |
|---|---|---|
| RTL testbench binds `final/nl` unchanged | yes (`clk`, `d`, `q`) | yes (27 ports, buses kept: `mem_addr[31:0]`, `trace_data[35:0]`) |
| Cell models found from `resolved.json` | yes | yes |
| Icarus: testbench at RTL / gate | passed / passed | passed / passed (14 of 14 checks, 527 cycles) |
| Icarus: real differences | **0** of 201 samples | **0** of 528 samples |
| Icarus: x-asymmetry | 0 | 39,344 bits on 528 samples, 8 ports |
| Verilator: testbench at RTL / gate | passed / passed (200 known checks) | passed / passed |
| Verilator: real differences | 0 of 201 samples | **78 bits on 19 samples** (`mem_la_wdata[10]`, `pcpi_rs2[10]`) |

The clock-gated variant of PicoRV32 (below) gives the same Icarus result: the
testbench passes at gate level and 0 real differences, the same 39,344
x-asymmetry bits.

## Designs and testbenches

Both designs are the LibreLane fixture set's own
(`../librelane/designs/`), run with LibreLane 3.0.16 (Classic flow) on sky130A,
`sky130_fd_sc_hd`, PDK `8afc8346a57fe1ab7934ba5a6056ea8b43078e71` from ciel.

- **path_adder** (`path_adder/tb_path_adder.v`). The design has no reset and
  `src_b` feeds back on itself, so in a four-state simulator `q` is x for
  ever, at RTL and at gate level alike, and a two-state simulator starts every
  register at zero. The testbench's reference model restates the RTL with the
  same uninitialised registers and checks with `!==`, so it expects x where
  the RTL means x. Under Icarus it checks 200 samples, none of them known;
  under Verilator 200 known samples. The netlist is the committed trimmed run,
  `../librelane/3.0.16/sky130A_met/run/final/nl/path_adder.nl.v`, with its
  `final/pnl` and `final/sdf/` beside it.
- **PicoRV32** (`picorv32/tb_picorv32.v`). A 4 KB memory holds a hand-encoded
  RV32I program (each word's assembly is in the comment beside it) that clears
  the register file, sums 1 to 10 in a loop, shifts, inverts, stores bytes and
  halfwords and loads them back signed and unsigned, compares, calls a leaf
  routine and returns, and takes and falls through branches. Every stored
  word's expected value follows from the program's meaning (55, 440, ~55,
  -56 >>> 2, ...); the testbench checks 14 of them and that `trap` stays 0.
  The mapping-gate design's views are regenerated weekly by `flow-live.yml`,
  not committed.

## Commands

From the repository root, with an OSS CAD Suite and the runs at hand:

```
python3 -I tool/flow/gate_level/regen_gate_level.py --suite <oss-cad-suite> --out <dir> \
    --run picorv32=<work>/3.0.16/g1/design/runs/g1 \
    --run picorv32_cg=<work>/3.0.16/g1_cg/design/runs/g1_cg
```

It runs, per design and simulator, the RTL and the gate run of the same
testbench and compares their port dumps with
`tool/flow/gate_level/gls_compare.py`. The exact tool lines (`<models>` is
the run's `CELL_VERILOG_MODELS`: `primitives.v` then `sky130_fd_sc_hd.v`):

```
iverilog -g2012 -s tb -s gls_portdump -DFUNCTIONAL -DUNIT_DELAY=#1 -DGLS_VCD="gate.vcd" \
    tb_<design>.v gls_portdump.v <models> final/nl/<top>.nl.v -o gate.vvp
vvp -n gate.vvp
verilator --binary --timing --trace -Wno-fatal -Wno-lint -Wno-style -Wno-BLKANDNBLK \
    --top-module tb -DFUNCTIONAL -DUNIT_DELAY=#1 -DGLS_VCD="gate.vcd" \
    tb_<design>.v gls_portdump.v <models> final/nl/<top>.nl.v ../harness/gls_bind.v
```

The RTL runs are the same lines with the RTL file in place of the models and
the netlist, and without the two defines.

Tools: OSS CAD Suite 2026-10-21 (darwin-arm64): Icarus Verilog 14.0 (devel)
s20260301-631-gce9868196, Verilator 5.053 devel rev v5.052-521-g6388139f7,
Yosys 0.70+186, EQY v0.70-1-gfb8b211. Measured 2026-10-22 on an Apple M4.

## Where the cell models come from

From the run's own `resolved.json`, no search:

| Field | Value on these runs |
|---|---|
| `PDK_ROOT` | `<home>/.ciel/ciel/sky130/versions/8afc8346a57fe1ab7934ba5a6056ea8b43078e71` |
| `PDK` | `sky130A` |
| `STD_CELL_LIBRARY` | `sky130_fd_sc_hd` |
| `CELL_VERILOG_MODELS` | `<PDK_ROOT>/sky130A/libs.ref/sky130_fd_sc_hd/verilog/primitives.v`, `.../sky130_fd_sc_hd.v` |
| `DEFAULT_CORNER`, `LIB` | `nom_tt_025C_1v80`; `LIB["*_tt_025C_1v80"]` is `.../lib/sky130_fd_sc_hd__tt_025C_1v80.lib` (for the equivalence recipe) |

The manager layout is **ciel's**: `PDK_ROOT` in the run is the versioned
directory itself, `~/.ciel/ciel/<family>/versions/<open_pdks commit>`, with
the variant (`sky130A/`) beneath it; there is no enabled-version symlink in
the path the run records. A run copied from another machine records that
machine's path; the models are then found by rebasing onto
`<PDK_ROOT or ~/.ciel>/ciel/<family>/versions/<the recorded commit>`, which is
what the weekly job does. volare was not installed and was not measured.

## The power-aware netlist (`final/pnl`)

`final/pnl/<top>.pnl.v` adds `inout VPWR, VGND` top ports and connects every
cell's `VPWR`, `VGND`, `VPB`, `VNB`. Measured on PicoRV32 under Icarus:

- without `USE_POWER_PINS` it does not compile (`port "VGND" is not a port of
  FILLER_0_102`, every cell, exit 52 on path_adder);
- with `USE_POWER_PINS` and the RTL testbench unchanged the supply ports
  float and every output is x: the testbench fails (timeout after 4,004
  cycles, `trap` x, 16 errors);
- with `USE_POWER_PINS` and a second top that ties the supply from outside
  (`harness/gls_power.v`: `force tb.uut.VPWR = 1'b1; force tb.uut.VGND =
  1'b0`) it passes, with the same classification as `nl` (0 real, 39,344
  x-asymmetry bits). Neither the testbench nor the netlist is edited.

So `pnl` needs `USE_POWER_PINS` and a generated supply tie; `nl` needs
neither and is the default.

## Differences, per simulator

**Icarus.** No real difference on either design. PicoRV32's x-asymmetry is
all RTL x against gate 0 or 1: outputs the RTL never assigns with its
default parameters (`pcpi_insn`, `trace_data`, `eoi`, `pcpi_valid`,
`trace_valid`: x in the RTL, tied to 0 by synthesis), `mem_addr[1:0]` before
the first fetch, and `mem_la_wdata`/`pcpi_rs2` while the RTL's `(* full_case
*)` write-data mux has an unknown select. path_adder: x on both sides at every
sample, so nothing differs.

**Verilator.** A two-state simulator has no x. Where the four-state RTL is x,
Verilator's RTL shows 0 and the netlist shows what its gates compute, so the
classifier sees both known and unequal: 78 real bits on samples 297 to 315,
`mem_la_wdata[10]` and its alias `pcpi_rs2[10]`. Icarus shows x-asymmetry on
those same samples (RTL x, gate `...0100 0000 0000`). The testbench passes in
both, but by the rule's own classification Verilator reports real
differences, so Verilator fails. Verilator also leaves ports it reduced to
constants out of its trace (7 of PicoRV32's 27 ports at gate level, among
them `pcpi_insn`, `pcpi_valid`, `trace_valid` and the tied inputs; 3 at RTL),
so those ports are not compared at all under Verilator.

## One-gate mutants, simulated

The mutants the equivalence check uses (the first `and2_2` turned into an
`or2_2`) were simulated too, to show what the comparison sees:

- **path_adder** (`_165_`): Icarus sees nothing (x on both sides, as for the
  correct netlist); Verilator's testbench fails (47 errors) and the
  comparison finds 46 samples with real differences.
- **PicoRV32** (`_04946_`): Icarus's testbench still passes, but the
  comparison finds 8 real bits on 8 samples that the correct netlist does not
  have; Verilator 86 real bits against its baseline 78.

So the port comparison catches a fault the self-checking testbench misses,
and a design that never leaves x under four-state simulation (the adder)
cannot be judged by Icarus at all.

## gf180mcuD and ihp-sg13g2

Measured on the adder only (the committed `gf180mcuD_met` and
`ihp-sg13g2_met` runs). The models resolve from `CELL_VERILOG_MODELS`
(`gf180mcu_fd_sc_mcu7t5v0.v` then `primitives.v`; `sg13g2_stdcell.v`) and the
netlists bind. Icarus runs both (x for ever, as on sky130). Verilator's gate
runs fail the testbench: 105 and 132 samples with real differences, where
the gf180 flip-flop UDP raises `MULTIDRIVEN` and the IHP models' `specify`
blocks are ignored. The equivalence check proves both netlists against the
RTL, so the failure is in the simulation of the models, not in the netlists.
Unmeasured for a verdict: these PDKs ship bannered.

## Dumping the ports without editing the testbench

- **Icarus:** a second top, `iverilog -s tb -s gls_portdump`, whose
  `$dumpvars(0, tb.uut.<port>, ...)` lists the RTL top's ports
  (`<design>/gls_portdump.v`). The VCD holds those ports only.
- **Verilator:** a second top is not usable: without `--top-module` every
  unreferenced module becomes a top (`-Wno-MULTITOP`), which for a gate-level
  build means every cell of the library. What works is `--top-module tb` plus
  a `bind` file, `bind tb gls_portdump u_gls_portdump();`
  (`harness/gls_bind.v`). Verilator ignores the signal list and traces the
  whole model, so the comparison keeps only the DUT scope's port names. A
  comment that begins with "Verilator" is read as a pragma
  (`BADVLTPRAGMA`), so the bind file's comment avoids the word at its start.
- **Verilator and asynchronous reset cells:** the MAC netlist's `dfrtp` flops
  stop the build with `%Error-BLKANDNBLK` in the cell library's UDP
  (`primitives.v:352`); `-Wno-BLKANDNBLK` builds it and the result matches
  the RTL. The LibreLane designs have no such cells.

## The MAC case

The research MAC (`mac/`: `dut.v`, an 8x8 multiply-accumulate, a counter and
a reset-less register; `tb.v`; `net.v`, its Yosys netlist on sky130_fd_sc_hd)
re-run here with the same suite. `tb.v` is not self-checking: it writes one
text line per cycle to `` `OUT `` (and drives `a = x`, `b = 0` for three
cycles under `-DXPROBE`). The text dumps are byte-identical to the research
ones at RTL and gate level, with and without `XPROBE`. Committed port VCDs in
`mac/vcd/`: Icarus `rtl`, `gate`, `rtl_x`, `gate_x`; Verilator
`verilator_rtl`, `verilator_gate`.

- Without `XPROBE`: 0 real; x-asymmetry on the first sample only (the RTL's
  asynchronous-reset registers are x until the first edge, the gate flops are
  already reset). Verilator: 0 differences.
- With `XPROBE`: 0 real; `parity` x-asymmetric on 199 samples (the RTL `x*0`
  stays x in the accumulator; the gates compute 0).
- `mac/net_splitports.v` is `net.v` after `splitnets -ports` (same cells; only
  the bus ports split into bits). The unchanged testbench does not bind it:
  `port "a" is not a port of uut` (Icarus exit 8). It is the port-shape case.

## Hand-offs

- Gate-level triage builds on these fixtures: the PicoRV32 x-asymmetry
  pattern (full_case mux, never-assigned outputs) and the MAC `x*0` case are
  the worked examples.
- SDF annotation: `final/sdf/<corner>/<top>__<corner>.sdf` is committed for
  path_adder under `../librelane/3.0.16/sky130A_met/run/final/sdf/`
  (OpenSTA, nine corners); PicoRV32's is regenerated weekly. The SDF gate
  measures annotation there.
