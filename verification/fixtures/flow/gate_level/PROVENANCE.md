# Gate-level fixtures: provenance

Fixtures for functional gate-level simulation on LibreLane netlists and on
the research MAC. Consumers: the gate-level runner and its port comparator,
the cell-model resolver, the gate-level triage, the SDF gate, and the
netlist-equivalence recipe beside them in `../../formal/eqy_flow/`.
`GLS-GATE.md` records the gate measured on them.

## Tools and date

Measured 2026-10-22 on an Apple M4 Mac mini (darwin arm64) with OSS CAD Suite
2026-10-21: Icarus Verilog 14.0 (devel) s20260301-631-gce9868196, Verilator
5.053 devel rev v5.052-521-g6388139f7, Yosys 0.70+186 (3718f7f13), EQY
v0.70-1-gfb8b211. LibreLane 3.0.16 runs (Classic flow) on sky130A
(`sky130_fd_sc_hd`, open_pdks `8afc8346a57fe1ab7934ba5a6056ea8b43078e71`),
gf180mcuD and ihp-sg13g2 from ciel, as recorded in
`../librelane/PROVENANCE.md`.

## Files

| Path | What | Origin |
|---|---|---|
| `path_adder/tb_path_adder.v` | self-checking testbench for the adder | written here; expectations restate the RTL |
| `picorv32/tb_picorv32.v` | self-checking testbench for PicoRV32 with a hand-encoded RV32I program | written here; expectations from the program's meaning |
| `*/gls_portdump.v` | a second top that dumps the DUT's ports | written here from each RTL top's port list |
| `harness/gls_bind.v` | binds the port dump into `tb` (Verilator) | written here |
| `harness/gls_power.v` | ties `final/pnl`'s supply ports from outside | written here |
| `mac/dut.v`, `mac/tb.v`, `mac/net.v` | the research MAC, its testbench and its Yosys netlist (sky130_fd_sc_hd) | copied unchanged from the gate-level research fixtures |
| `mac/net_splitports.v` | `net.v` with its bus ports split | `yosys`: `read_liberty -lib <tt lib>; read_verilog net.v; hierarchy -top dut; splitnets -ports; write_verilog -noattr -noexpr -nohex -nodec` |
| `mac/vcd/{rtl,gate}.vcd`, `{rtl_x,gate_x}.vcd` | Icarus port dumps, without and with `XPROBE` | `iverilog -g2012 -s tb -s gls_portdump [-DXPROBE] -DOUT=... [-DFUNCTIONAL -DUNIT_DELAY=#1]` then `vvp -n` |
| `mac/vcd/verilator_{rtl,gate}.vcd` | Verilator port dumps (the whole model is traced) | `verilator --binary --timing --trace -Wno-BLKANDNBLK --top-module tb ... gls_bind.v` |
| `gls.expected.json` | the recorded outcomes, per design and simulator | hand-written from the RTL, the testbenches and the tools' own output records |

The adder's netlist, power-aware netlist and SDF are not copied here: the
committed trimmed run `../librelane/3.0.16/sky130A_met/run/final/{nl,pnl,sdf}`
is the fixture (and `gf180mcuD_met`, `ihp-sg13g2_met` beside it for the other
PDKs). PicoRV32's run, plain and with Yosys clock gating
(`../librelane/designs/picorv32/config_cg.yaml`), is regenerated weekly by the
LibreLane job of `flow-live.yml` and handed to its gate-level job; it is not
committed (`final/nl` alone is 3 MB, `final/pnl` 7 MB).

The MAC's text dumps (`tb.v` writes one line per cycle to `` `OUT ``) were
compared byte for byte with the research run's at RTL and gate level, with
and without `XPROBE`: identical.

## Command

```
python3 -I tool/flow/gate_level/regen_gate_level.py --suite <oss-cad-suite> --out <dir> \
    [--run picorv32=<run dir>] [--run picorv32_cg=<run dir>] [--pdk-root <dir>] [--case <name>]...
```

It re-measures and writes `<dir>/gate_level.json`; it never writes into the
fixtures. `test/static/flow_gate_level_live_test.dart` runs it and compares
with `gls.expected.json` and `../../formal/eqy_flow/recipe.expected.json`.
`test/static/flow_gate_level_fixtures_test.dart` checks the committed files
without any tool.

## Where each expectation comes from

- **path_adder:** the testbench's model restates the RTL with the same
  uninitialised registers, so a four-state simulator expects x for ever (no
  reset, `src_b` feeds back on itself) and a two-state simulator expects the
  zero-start sequence; never from a simulator's output.
- **PicoRV32:** each checked word follows from the program (sum of 1 to 10 is
  55, `55 << 3` is 440, `~55`, `-56 >>> 2 = -14`, byte and halfword stores
  into zeroed words, `0x12345678 & 0x00012345 = 0x240`, and so on); `trap`
  must stay 0.
- **MAC:** `tb.v` has no verdict. What the VCD checks expect follows from the
  RTL: the asynchronous reset starts asserted, so the RTL is x until the first
  edge while reset gate flops are 0; under `XPROBE` the RTL product `x*0` is x
  and the accumulator keeps it.
- **Outcomes in `gls.expected.json`:** pass or fail per run is the
  testbench's own `TEST PASSED` and exit status; difference counts are
  `gls_compare.py`'s classification of the simulators' VCDs, a measurement
  tool that shares no code with SimCrux.
