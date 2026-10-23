# The SDF gate: delay annotation on a real LibreLane SDF, measured

**Result: passes.** Delay-annotated gate-level simulation is built, Icarus
only, labelled on every result: "Delay-annotated simulation, no timing
checks. Setup and hold violations are not detected."

The rule was fixed before the measurement and is applied as written. A
LibreLane `final/sdf/<corner>/` file written by OpenSTA annotates in Icarus
(`-gspecify -ginterconnect`) with every IOPATH and INTERCONNECT accounted for
(annotated, or named as skipped with the reason), and on the functional
gate's design (PicoRV32) a deliberately shortened clock period yields
"behaviour differs with delays" while the nominal period matches RTL.
**Pass:** the delay-annotated simulation is built. **Fail:** it waits for a
later release as a unit. The threshold does not move.

| Check | Measured on PicoRV32, `nom_tt_025C_1v80` | Holds |
|---|---|---|
| Every IOPATH accounted for | 24,001 IOPATH: Icarus names none as unmatched | yes |
| Every INTERCONNECT accounted for | 23,295 INTERCONNECT: 23,189 annotated; 106 named "Could not find intermodpath", each a tie-off cell's output (`sky130_fd_sc_hd__conb_1` `LO`) to a top-level output the netlist connects with a continuous `assign` (`eoi`, `trace_data` and the like): a constant net, so no delay is lost | yes |
| TIMINGCHECK | 1,597 "TIMINGCHECK not supported" warnings, one per flip-flop | expected: Icarus has no timing checks |
| Nominal period matches RTL | 25 ns: testbench passes (14 of 14), 0 real differences, the same 39,344 X-asymmetry bits as the functional run | yes |
| A shortened period differs | equal down to 8 ns; 7 ns: 1 real difference while the testbench still passes; 6 ns: 261 samples and the testbench fails; 5 ns: 519; 4 ns: 524 | yes |
| A setup-violating period is a wrong capture, no X, no message | 6 ns: the first difference is a wrong known value (`pcpi_rs1` at sample 267, `0xc0200001` for `0x1`), with no X and no message; X appear 26 samples later, downstream of the wrong program flow | yes |

Two numbers the header line hides: the timing variants of the sky130 models
are compiled (no `FUNCTIONAL`, no `UNIT_DELAY`), and their `$setuphold`
checks are parsed with the warning "Timing checks are not supported. Delayed
reference and data signals become copies of the original reference and data
signals." So a capture that arrives too late in the cycle is silently wrong,
never an X and never a message: the label says so.

## The testbench must drive its inputs after the clock edge

With the committed testbench unchanged (inputs change at the clock edge,
`mem_rdata <= ...` on `posedge clk`), the annotated netlist **differs at every
period**: 25 ns and 100 ns give the same 515 samples with real differences
and a failing testbench. The netlist's clock arrives through the clock tree,
so an input the testbench changes at the edge reaches some flip-flops before
their clock does. The run's timing analysis assumed the inputs arrive later
(`IO_DELAY_CONSTRAINT`: 20% of the period). With the testbench's inputs
changing 20% of the period after the edge (`-DIN_DELAY`, see the testbench),
the nominal period matches RTL as tabled above. The zero-delay control (the
same timing models, `-gspecify`, no SDF) passes at 25 ns and at 6 ns, so the
differences are the annotated delays.

So the result surfaces say it in one line: an input the testbench changes at
the clock edge races the netlist's delayed clock; drive inputs after the edge,
as the run's input delay assumes.

## COND clauses and escaped names

The sky130 SDFs OpenSTA wrote on these runs carry no COND clause and no
escaped name. The committed adder runs of the other two PDKs do:

| Run (`../librelane/3.0.16/`) | IOPATH | Under COND | INTERCONNECT | Icarus | Coverage |
|---|---|---|---|---|---|
| `sky130A_met`, `nom_tt_025C_1v80` | 654 | 0 | 614 | header and 73 TIMINGCHECK warnings only | full |
| `gf180mcuD_met`, `nom_tt_025C_5v00` | 640 | 385 | 579 | 192 "Unable to match ModPath" on `xor2_1`/`xnor2_1` unconditional IOPATHs (the cell models declare only conditional paths); the 385 under COND annotate | partial, the 192 named |
| `ihp-sg13g2_met`, `nom_typ_1p20V_25C` | 594 | 397 | 668 | "Invalid/malformed COND" at line 1676 (`(COND A1 == 1'b0 & A2 == 1'b0`, a single `&`), then "Too many errors: syntax error": the file is not annotated | failed |

The adder never leaves X under four-state simulation (see `GLS-GATE.md`), so
these runs measure annotation only, not behaviour. A file Icarus cannot parse
is the `failed` coverage, and no result is shown for it.

## The research MAC (the live fixture)

`sdf/mac_0p5ns.sdf` gives every path of the research MAC netlist 0.5 ns
(`tool/flow/gate_level/gen_sdf.py`, a synthetic file, not OpenSTA's). Its
testbench changes inputs on the falling edge, so no input races the clock.
Equal to RTL at 40 and 20 ns; differences at 16 ns (157 samples), 12 ns (195)
and 8 ns (197), every one a known wrong value, no X and no message. Fast
enough to run on every live check, it is the one the product's live test
sweeps.

## Commands

From the repository root, with an OSS CAD Suite and the sky130 PDK from ciel:

```
python3 -I tool/flow/gate_level/sdf_gate.py sweep --suite <oss-cad-suite> \
    --run <work>/3.0.16/g1/design/runs/g1 --out <dir> [--period <ns>]... [--at-edge]
python3 -I tool/flow/gate_level/sdf_gate.py annotate --suite <oss-cad-suite> \
    --run verification/fixtures/flow/librelane/3.0.16/<pdk>_met/run --corner <corner> --out <dir>
python3 -I tool/flow/gate_level/sdf_gate.py mac --suite <oss-cad-suite> \
    --pdk <sky130A>/libs.ref/sky130_fd_sc_hd/verilog --out <dir> [--period <ns>]...
```

The tool lines (gate run; the RTL run is the same testbench with the RTL in
place of the models and the netlist):

```
iverilog -g2012 -gspecify -ginterconnect -s tb -s gls_portdump \
    -DGLS_VCD="gate.vcd" -DGLS_SDF="<run>/final/sdf/<corner>/<top>__<corner>.sdf" \
    -DHALF_PERIOD=<p/2> -DIN_DELAY=<p/5> \
    picorv32/tb_picorv32.v picorv32/gls_portdump.v <models> <run>/final/nl/<top>.nl.v -o gate.vvp
vvp -n gate.vvp
```

A delay-annotated run of PicoRV32 takes about 100 seconds of simulation for
527 cycles on an Apple M4, where the functional run takes half a second.

Tools: OSS CAD Suite 2026-10-21 (darwin-arm64), Icarus Verilog 14.0 (devel)
s20260301-631-gce9868196. LibreLane 3.0.16, sky130A (`sky130_fd_sc_hd`,
open_pdks `8afc8346a57fe1ab7934ba5a6056ea8b43078e71`). Measured 2026-10-22.

## Files

| Path | What |
|---|---|
| `picorv32/tb_picorv32.v` | the functional gate's testbench, with `HALF_PERIOD` and `IN_DELAY` (both default to the original behaviour) |
| `picorv32/gls_portdump.v` | its port dump, which annotates `tb.uut` first when `GLS_SDF` is defined |
| `sdf/icarus/*.log` | every SDF line Icarus printed on the four runs above, the SDF's path replaced by `<sdf>` |
| `sdf/mac_0p5ns.sdf` | the research MAC's synthetic SDF |
| `sdf/picorv32_sweep.json`, `sdf/mac_sweep.json` | the tool's records of the two sweeps above (inputs 20% after the edge), as it wrote them |
| `sdf/sdf_gate.expected.json` | the recorded outcomes, written from the measurements above |
