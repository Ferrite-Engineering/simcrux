# Formal fixture corpus: provenance

This corpus pins how the open formal stack (SymbiYosys, EQY, Yosys and the
yosys-slang plugin, as shipped in the YosysHQ OSS CAD Suite) behaves on a
small set of designs whose correct answers are known from the designs
themselves. It is what SimCrux's formal readers are written and tested
against. `VERIFICATION_GUIDE.md` section 26 documents the output shapes it
measures.

Everything above the `regenerated` marker is written by hand. Everything
between the markers is rewritten by `tool/regenerate_formal_fixtures.sh` on
every run.

## Three kinds of file

| Kind | Where | Written by |
|---|---|---|
| Inputs | `sby/<case>/*.sv`, `*.sby`; `sva_matrix/probes/`; `eqy/*.v`, `*.eqy`; `eqy/oracle/`; `eqy_vhdl/*.vhd`, `*.eqy` | Hand. Never regenerated |
| Expectations | `*.expected.json` | Hand, from each property's meaning. Never regenerated, never copied from a tool |
| Captures | `*/captured/`, `schemas/<build>/` | `tool/regenerate_formal_fixtures.sh`, from the real tools |

The regenerator hashes every `*.expected.*` file before it starts and
refuses to finish if one changed.

## Where the inputs came from

The RTL, the `.sby` and `.eqy` files and the 51 SVA probes come from an
October 2026 measurement of the open formal stack (OSS CAD Suite build
20261013: Yosys 0.69+286, SBY v0.69, EQY v0.69-1-g7a92d84). That
measurement kept no tool output; every capture here is new.

- `eqy/gate.v` was produced in that measurement by
  `read_verilog alu.v; synth -flatten -top alu; abc -g AND,OR,XOR,MUX; opt_clean; write_verilog -noattr gate.v`
  with Yosys 0.69+286 (its first line says so). It is an input now, kept
  byte for byte: regenerating it with another Yosys would change the very
  structure the `alu_pass` false FAIL depends on.
- `eqy/gate_bad.v` is `gate.v` with the first two-input AND in an `assign`
  flipped to OR (line 147, `_062_ & _064_` to `_062_ | _064_`).
- `eqy_vhdl/alu.vhd` was written by hand on 2026-10-21 as `eqy/alu.v` in
  VHDL-2008, line for line in meaning; `eqy_vhdl/*.eqy` read it through a
  `ghdl --std=08 alu.vhd -e alu` line, which the `eqy` driver lowers with a
  standalone `ghdl --synth --out=verilog` before EQY runs. Their gates are
  `eqy/gate.v` and `eqy/gate_bad.v`, so the eqy oracle below decides them.
  `eqy_vhdl/eqy_vhdl.expected.json` states each output's result, not each
  partition's: whether EQY cuts an output whole or per bit is its choice. It
  has no captures and is checked only live
  (`test/integration/eqy_driver_live_test.dart`), first on 2026-10-21 with
  EQY v0.70-1 from OSS CAD Suite build 20261021 and GHDL 6.0.0 (Homebrew;
  that build's own `ghdl` does not start on this macOS, a duplicate
  `LC_RPATH`).

## How the expectations were written

From the property text and the RTL, before the captures existed, with two
rules stated once in each file (`step_rule`):

- Step 0 is the initial state. A check clocked on `posedge clk` (an
  immediate assertion in `always @(posedge clk)`, or a concurrent property)
  samples the values of step k on the edge into step k+1, and sby reports
  it at step k+1. This rule was read off the first exploratory
  `handshake_imm` run, before any expectation was written; every other step
  in the corpus was then predicted with it and matched.
- `$past(x, n)` on that edge reads step k-n; for k-n below 0 it reads state
  from before the trace began, which nothing constrains.

Two independent oracles back the EQY expectations:

- `eqy/oracle/tb.v` clocks every `(op, a, b)` vector (2^18 of them plus the
  reset vector) through a design with Icarus Verilog; `eqy/oracle/compare.py`
  diffs two dumps. Measured 2026-10-21 with Icarus Verilog 13 (Homebrew):
  `gate.v` equals `alu.v` on every vector; `gate_bad.v` differs in `y` on
  80896 vectors and in `z` on 4750, under every `op`.

      iverilog -o gold.vvp eqy/oracle/tb.v eqy/alu.v
      vvp -n gold.vvp +out=gold.txt
      (the same for gate.v and gate_bad.v)
      python3 eqy/oracle/compare.py gold.txt gate.txt

- The structure of `gate.v` itself: `z`'s next value is `_038_ & _055_`
  (line 184), internal nodes of the `r` logic, while every `y` bit is a
  plain register on `r[i]` (lines 282 to 305).

The SVA matrix pins two things per probe: the formal-cell count, by
counting the one assert, assume or cover in its source, and acceptance per
frontend, from the frontends' documented support. Where the documentation
does not settle a form the acceptance is `null` and only the no-silent-drop
invariant is asserted.

## Where a live run disagreed, and which side was wrong

Every disagreement was settled from the property's meaning. No expectation
was changed to match a tool.

1. **`fifo_slang` task `bug`: expected step 7, sby reported step 8.** The
   trace shows `count == 5` at step 6, so by the step rule the property is
   violated at step 7 inside that very trace, and no shorter trace exists
   (count rises by at most one per step). The task uses `abc pdr`, which is
   not a bounded search and need not return the shortest counterexample, and
   sby replays only the last step of a PDR witness ("Skipping step 0..7").
   The expectation over-specified an engine detail: it now says
   `step_at_least: 7` plus a trace check that `count` exceeds 4. Readers must
   not treat a PDR step as the first violation.
2. **`handshake_temporal` task `slang`: expected the error text "unsupported
   SVA feature", the frontend reported `unknown system name '$initstate'`
   at line 49.** The file holds ten refused constructs; which one a frontend
   names first is its elaboration order, not something the source decides.
   The expectation now lists the refused lines and requires an ERROR on one
   of them.
3. **EQY `alu_pass` and `alu_fail`: which partitions fail.** The first
   expectation recorded only the verdicts (FAIL, FAIL) and the reasons. After
   the run named the failing partitions (`alu.z`; `alu.r` and `alu.z`), they
   were derived independently from the `gate.v` structure above and the
   oracle, and recorded as `failing_outputs` with that derivation in the
   `why`.
4. **`pretrace` task `builtin_cover`: the first expectation gave the
   built-in covers no label**, by analogy with `handshake_imm`, whose
   unlabelled immediate assertions the built-in frontend names
   `_witness_.check_…`. Here every cover carries a statement label in the
   source (`c_footgun: cover (…)`), and a label is the property's name on
   either frontend; the expectation now names them.

## Builds the live expectations do not hold on

The live test passes on build 20261021. The two older builds differ, and
the differences are the frontend, not the expectations:

- 20260921: yosys-slang refuses `$onehot0` in a concurrent property (probe
  `matrix/23_onehot0`), and sby does not repeat the frontend's error in the
  task log (it is only in `model/design.log`, which the regenerator keeps as
  `design.log` for every task that ended in ERROR).
- 20260821: yosys-slang also refuses `$rose`, `$stable`, `$fell` and
  `$changed`, so every `handshake_slang` and `fifo_slang` task ends in ERROR
  (`schemas/20260821/sby/fifo_slang/` shows it).

No build silently dropped a property: every probe a frontend accepted kept
its one formal cell.

## The pre-trace case and the refusal captures

- `sby/pretrace/` holds the pre-trace `$past` trap on both open frontends:
  a cover that is unreachable on any real trace (`c_footgun`), one that is
  reachable for real but first reached on pre-trace state (`c_unguarded`),
  the correctly constrained variant (`c_guarded`, guarded by a register that
  holds 3 only once the `$past` chain has filled), and the assertion form
  (`a_footgun`). Its expectation was written from the counter's timeline
  before the first run, with the step rule above checked first on a
  boundary probe (a constant-0 register `r`, covers `$past(r, 2) && t == k`
  for k = 0 to 4 with `t` a step counter): on build 20261021 both frontends
  reached k = 0 and k = 1 only, at steps 1 and 2. A property reported at
  step s therefore reads state from before the trace began through a
  `$past` chain of depth n exactly when s <= n.
- `elaborated.json` beside every task that did not end in ERROR is the
  design sby elaborated (`model/design.il`) written as Yosys JSON by the
  same build's Yosys (`read_rtlil design.il; write_json`). It is the input
  the pre-trace detector and the dropped-property guard read in the
  product, so the detector's unit tests run on the real thing.
- `schemas/<build>/sby/handshake_temporal/` keeps each build's task log and
  Yosys log for the refused design, because the refusal's shape changes
  across builds: 20261021 repeats the frontend's `file:line: ERROR:` line in
  the task log, the two older builds keep slang's `file:line:col: error:`
  line only in `model/design.log`.

## The vacuity case and the EQY partition files

- `sby/vacuity/` holds an assertion that is never checked: `m_reset`
  assumes `rst` on every step, and `a_vacuous` is disabled in reset
  (`disable iff (rst)` on yosys-slang, `if (!rst)` around the immediate
  assertion on the built-in frontend), so both tasks pass without it ever
  being exercised. `a_live` is checked on every step and is the control.
  The expectation was written from the RTL before the first run. On build
  20261021 both frontends elaborate the disabled enable the same way: the
  assertion's `EN` is a `$mux` selecting constant 0 when `rst` is 1, and the
  assumption's `A` is `rst` with a constant-1 `EN`.
- Each `eqy/captured/<run>/` keeps EQY's `gold.ids` (the port direction of
  every gold signal: an internal match point has none) and
  `partitions/<partition>.json` (the partition's inputs and outputs, and
  the inputs each side leaves unused). On `alu_pass`, `alu.z`'s gold side
  leaves `a`, `b` and `op` unused and its gate side leaves `r` unused: the
  gold `z` starts at the match point `r`, the restructured gate `z` starts
  at the primary inputs.
- Both came from a partial recapture on 2026-10-22 (UTC) with
  `tool/regenerate_formal_fixtures.sh --suite <oss-cad-suite 20261021> --only eqy --only sby/vacuity`,
  on the same build as every other capture. `--only` leaves the other
  captures, the schemas and the date below alone. Of that EQY recapture
  only `gold.ids` and `partitions/*.json` were kept: both are Yosys's
  deterministic output for the same inputs, while the logs and the
  induction traces differ from run to run in timestamps and solver choices,
  and the counterexample traces are a corpus WaveCrux pins by digest. The
  rest of `eqy/captured/` is the 2026-10-21 capture.

<!-- regenerated:begin -->

## Captures (written by tool/regenerate_formal_fixtures.sh)

Regenerated 2026-10-21 with:

    tool/regenerate_formal_fixtures.sh --suite <oss-cad-suite 20261021> --suite <oss-cad-suite 20260921> --suite <oss-cad-suite 20260821>

### Builds

- build 20261021:
  - yosys Yosys 0.70+186 (git sha1 3718f7f13, Release, Clang /usr/local/osxcross/target/bin/aarch64-apple-darwin25.5-clang++ 21.1.8)
  - sby SBY v0.70-9-g79fc9ed
  - eqy EQY v0.70-1-gfb8b211
  - yosys-slang plugin sha256 9926fc4acdaaef1f, slang version 12.0.0+545f88b2e
  - yices Yices 2.7.0
  - bitwuzla 0.9.1
  - boolector 3.2.4
- build 20260921:
  - yosys Yosys 0.69+77 (git sha1 9ff27d29c-dirty, Release, Clang /usr/local/osxcross/target/bin/aarch64-apple-darwin25.5-clang++ 21.1.8)
  - sby SBY v0.69
  - eqy EQY v0.69-1-g7a92d84
  - yosys-slang plugin sha256 d9b4f29252794f01, slang version 11.0.448+e222e7dc0
  - yices Yices 2.7.0
  - bitwuzla 0.9.1
  - boolector 3.2.4
- build 20260821:
  - yosys Yosys 0.68+118 (git sha1 144c707b7-dirty, Release, Clang /usr/local/osxcross/target/bin/aarch64-apple-darwin25.5-clang++ 21.1.8)
  - sby SBY v0.68
  - eqy EQY v0.68
  - yosys-slang plugin sha256 38edf9a604b6608c, slang version 11.0.448+e222e7dc0
  - yices Yices 2.7.0
  - bitwuzla 0.9.1
  - boolector 3.2.4

### Capture directories and the build each came from

- `sby/fifo_slang/captured/` build 20261021
- `sby/handshake_imm/captured/` build 20261021
- `sby/handshake_slang/captured/` build 20261021
- `sby/handshake_temporal/captured/` build 20261021
- `sby/pretrace/captured/` build 20261021
- `sby/vacuity/captured/` build 20261021
- `sva_matrix/captured/` build 20261021
- `eqy/captured/` build 20261021
- `schemas/20261021/` build 20261021
- `schemas/20260921/` build 20260921
- `schemas/20260821/` build 20260821

<!-- regenerated:end -->
