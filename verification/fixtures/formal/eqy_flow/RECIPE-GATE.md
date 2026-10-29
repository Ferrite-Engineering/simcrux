# G6: RTL-to-netlist equivalence on real LibreLane netlists, measured

**Result: the recipe does not prove the mapping-gate design's correct
netlist. Outcome: `fail`.** "Prove this run's netlist equals my RTL" does not
ship in 1.2 and no page, help text or announcement names it. A `.eqy` file
the user writes still runs through the EQY driver as before.

The rule was fixed before the measurement and is applied as written. On a
real LibreLane `final/nl` (the small sky130A design and the 500-plus
flip-flop mapping-gate design; resizer buffers, clock tree buffers, clock
gating where the design has it) the generated recipe must prove the correct
netlist (every partition proved, or "partially proven" naming exactly the
blackboxed clock-gating cells), and a one-gate mutant of the same netlist
must fail in exactly one partition, every partition inside the per-partition
budget (600 s). **Pass:** the action ships. **Pass only without clock
gating:** it ships with "partially proven" for clock-gated designs.
**Fail:** it does not ship in 1.2. The threshold does not move.

| Design | Correct netlist | One-gate mutant | Slowest partition |
|---|---|---|---|
| path_adder, sky130A (73 flip-flops) | **PASS**, 4 of 4 partitions, 2 s | **FAIL in 1 partition** (`sum_q.0`), 2 s | under 1 s |
| path_adder, gf180mcuD | PASS, 4 of 4 | not built | under 1 s |
| path_adder, ihp-sg13g2 | PASS, 4 of 4 | not built | under 1 s |
| PicoRV32, sky130A (1,597 flip-flops) | **FAIL: 67 of 75 proved, 8 fail** | fails in the **same 8 partitions** (`_04946_` and2 into or2): not told apart from the correct netlist | 13 s |
| PicoRV32 with clock gating (41 `dlclkp_1`) | **does not run** (gate side does not elaborate) | not built | none |

## The recipe

`flow_netlist.eqy.in`, filled from the run's own records
(`tool/flow/gate_level/regen_gate_level.py` fills it):

```
[gold]
read_verilog -sv {rtl}
prep -top {top}
memory_map
opt_clean
splitnets

[gate]
read_liberty -ignore_miss_func {liberty}
read_verilog {netlist}
hierarchy -top {top}
delete {physical}
hierarchy -top {top} -purge_lib
prep -top {top}

[strategy sby]
use sby
depth 5
engine smtbmc bitwuzla
timeout {timeout}
```

- `{liberty}`: `resolved.json` `LIB` at the pattern matching `DEFAULT_CORNER`
  (`sky130_fd_sc_hd__tt_025C_1v80.lib`). The tt, ss and ff files define the
  same cells, so the corner does not change the result.
- `{physical}`: `t:<cell>` for each of the run's `FILL_CELLS`, `DECAP_CELLS`,
  `WELLTAP_CELL`, `ENDCAP_CELL` (sky130: `fill_1`, `fill_2`, `decap_3`,
  `tapvpwrvgnd_1`; gf180mcuD: `fill_*`, `fillcap_*`, `filltie`, `endcap`;
  ihp-sg13g2: `sg13g2_fill_1`, `_2`, `sg13g2_decap_*`). Fill and tap cells
  have no Liberty entry in any corner.
- Two additions to the research recipe, both needed on LibreLane's output:
  **`splitnets` on the gold side** (LibreLane writes every register bit as its
  own net, `\src_a[3]`; without it no internal register matches and the
  adder's one partition is Inconclusive), and **`memory_map`** (PicoRV32's
  register file is flip-flops in the netlist, `cpuregs[21][19]`).

## Commands

```
python3 -I tool/flow/gate_level/regen_gate_level.py --suite <oss-cad-suite> --out <dir> \
    --run picorv32=<work>/3.0.16/g1/design/runs/g1 \
    --run picorv32_cg=<work>/3.0.16/g1_cg/design/runs/g1_cg
```

which runs, per design, `eqy -d <dir>/<case>/eqy_nl <case>.eqy` (and
`eqy_mutant`) in a shell that first raises the stack limit to its hard
limit, and a blackbox listing:

```
read_liberty -lib <lib>
read_liberty -overwrite -ignore_miss_func <lib>
read_verilog <final/nl>
hierarchy -top <top>
delete <physical>
hierarchy -check -top <top> -purge_lib
select -list =A:blackbox
stat -json
```

Every Liberty cell is first a blackbox; the ones with a function overwrite
it; what is still a blackbox after the purge is an instantiated cell without
a function. Tools: OSS CAD Suite 2026-10-21, EQY v0.70-1-gfb8b211, Yosys
0.70+186, bitwuzla through sby. Runs: LibreLane 3.0.16, sky130A open_pdks
`8afc8346a57fe1ab7934ba5a6056ea8b43078e71`. Measured 2026-10-22 on an Apple
M4. Work directories stayed outside the repository; `eqy -f` overwrites its
`-d`, so the regenerator only ever points it at a directory it created.

## Blackboxed cells

| Design | Instantiated cells without a Liberty function |
|---|---|
| path_adder (all three PDKs), PicoRV32 | none |
| PicoRV32 with clock gating | `sky130_fd_sc_hd__dlclkp_1` × 41 |

## PicoRV32: why the correct netlist does not prove

The 8 failing partitions are `mem_addr`, `mem_instr`, `mem_la_wdata`,
`mem_la_wstrb`, `mem_valid`, `mem_wdata`, `mem_wstrb`, `pcpi_rs2`, each with a
counterexample at step 1 or 2. They are not netlist bugs (the gate-level
simulation of the same netlist passes its testbench with no real
difference); they come from how EQY cuts the design:

- **Matched combinational nets are cut points.** EQY makes every net it
  matches by name a free input of the partitions that read it. The netlist's
  `mem_valid` logic reads the port `mem_la_write`, which the RTL computes
  from `mem_state` and `mem_do_wdata`; as a free input it can take values the
  design never produces, and the gold and gate partitions disagree
  (`mem_valid` partition: `resetn` low, gold resets `mem_valid`, gate does
  not, because its reset path goes through `mem_la_write`).
- **Yosys re-encodes FSM registers.** LibreLane's synthesis log says
  `Recoding FSM` for `cpu_state` and `mem_wordsize`; the netlist's
  `mem_wordsize` has three bits where the RTL has two, yet bits 0 and 1 match
  by name (`mem_la_wstrb` partition).

What was tried, all with the same tools, none of it adopted:

| Variant | Correct PicoRV32 | Adder mutant |
|---|---|---|
| `[partition *] amend *` (cut points get their driving logic) | 70 proved; Inconclusive `mem_la_wdata` (about 400 s), `mem_valid`, `mem_wstrb`; FAIL `mem_la_wstrb` (the FSM), `pcpi_rs2`; 27 minutes in all | **Inconclusive**, not FAIL: the amended uninitialised feedback register keeps the gold side x |
| `amend *` with `timeout 20` | 70 proved, 4 timed out, `mem_la_wstrb` FAIL | not run |
| `gold-nomatch`/`gate-nomatch` on `cpu_state*`, `mem_wordsize*` | 5 FAIL (`mem_addr`, `mem_instr`, `mem_valid`, `mem_wdata`, `mem_wstrb`) | not run |
| both | `mem_valid` Inconclusive after about 5 minutes (stopped there; the partitions before it proved) | not run |
| both, with `noamend` on every register (amend only combinational matches) | 65 proved, including `mem_addr` and `mem_instr`; then `mem_valid` Inconclusive after about 8 minutes, over the 600 s budget (stopped there) | not run |

`amend *` makes a real one-gate fault Inconclusive on the adder, so it cannot
be the recipe even where it helps PicoRV32. The last row is the most
promising direction for a later attempt (registers stay cut, so the adder's
mutant would still fail; the FSM list comes from the run's own synthesis
log), but `mem_valid` alone outlasts the budget.

PicoRV32's mutant (the first `and2_2`, `_04946_`, turned into an `or2_2`)
fails in exactly the 8 partitions the correct netlist fails in, so the check
cannot tell the fault from the cut-point failures. Simulation does: the same
mutant gives 8 real port differences under Icarus where the correct netlist
gives none (`../../flow/gate_level/GLS-GATE.md`).

The weekly rerun proves the PicoRV32 netlist LibreLane's Linux x64 build
writes, which is not the darwin one. On the netlist of the flow-live run of
2026-10-28 the correct netlist fails 6 of 75 partitions (`mem_instr` and
`mem_valid` prove there) and its mutant (`_04951_`) fails the same 6; the
darwin arm64 EQY build gives those 6 on that netlist and these 8 on the darwin
one. So which partitions fail is a property of the netlist, recorded as
`differs_by_platform` in `recipe.expected.json`, and what the outcome rests on
holds on both: the correct netlist fails, and the mutant fails in exactly its
partitions.

## Clock gating

`config_cg.yaml` (`SYNTH_CLOCKGATE_MIN_WIDTH: 8`,
`SYNTH_CLOCKGATE_POSEDGE_ICG: sky130_fd_sc_hd__dlclkp_1/GATE/CLK/GCLK`) is
LibreLane's own clock gating; the PDK sets no ICG by default. PicoRV32 then
has 41 `dlclkp_1`. The gate-level simulation is unaffected (Icarus: 0 real
differences, the testbench passes). Equivalence cannot run:

- `read_liberty -ignore_miss_func` **drops** the cell ("Ignoring cell
  sky130_fd_sc_hd__dlclkp_1 with missing function on output GCLK"), so the
  gate side fails: `Module \sky130_fd_sc_hd__dlclkp_1 ... is not part of the
  design`.
- Declared a **blackbox** (`read_liberty -lib`, then the functional read
  with `-overwrite`), EQY's combine step never ends: it repeats
  `flatten`/`hierarchy` (11,265 iterations before it was stopped). An EQY
  internal error.
- Given a **functional model** (latch on `GATE` while `CLK` is low, `GCLK =
  CLK & latch`), sby refuses it: "derived signal ... is used as clock,
  derived clocks are only supported with clk2fflogic"; with `option
  multiclock on` the same error, and other partitions turn Inconclusive.

So "partially proven" is not reachable either.

## Other EQY records

- **Stack overflow.** On PicoRV32 `eqy_partition` dies with a segmentation
  fault (`Partition::add` recursing until the 8 MB stack is gone) in the
  2026-08-21, 2026-09-21 and 2026-10-21 builds. Raising the soft stack limit
  to the hard limit (65,520 KB on macOS) fixes it.
- **Per-partition timeout.** The sby strategy's `timeout <seconds>` is
  honoured: with `timeout 20`, slow partitions end as `timeout` and EQY moves
  on.
- No "This should not happen" internal error appeared: physical-only cells are
  deleted, never stubbed.

## Hand-offs

- The EQY partition explorer and the formal driver keep their own fixtures;
  nothing here changes them. The weekly `flow-live.yml` job `gate-level`
  re-measures this file's outcomes (`recipe.expected.json`) so a fixed EQY or
  a changed LibreLane netlist shows up as a changed outcome, which is when to
  measure again.
