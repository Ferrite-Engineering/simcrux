# Gate-level simulation, from 1.2

From SimCrux 1.2, a LibreLane run's netlist can be simulated with the
regression tests you already have. SimCrux reruns the tests a flow entry names
against the run's gate-level netlist and the PDK's cell models, runs each one at
RTL and at gate level, and compares what the design's top-level ports do. This
page covers what it runs, what the three outcomes mean, how to start it from the
window or the command line, and what it does not do. It is part of
[Implementation flow](flow.md).

<!-- vocabulary-guard: disclaimer begin -->
Results are findings, not signoff.
<!-- vocabulary-guard: disclaimer end -->

Gate-level simulation is open core and free in every tier: running it, each
test's outcome and both counts, the reasons a test did not run, and the
waveform hand-off. The view of which port differs at which cycle is a Pro
analysis.

## What it runs {#what}

- **Functional simulation, under Icarus.** Every gate has a unit delay
  (`UNIT_DELAY=#1`) and the cell models are compiled with `FUNCTIONAL`. There
  are no timing checks and no delays from the run's SDF file, so a result says
  nothing about timing.
- **Icarus only in this release.** A test that runs under Verilator has its RTL
  and its gate-level run both rerun under Icarus. SimCrux says so before it
  starts, and the Simulator column of the rows reads `icarus`. The two runs of a
  test always use the same simulator, the same seed, the same defines and the
  same parameters, because a random sequence differs between simulators and a
  comparison across two would be noise.
- **The netlist as LibreLane wrote it.** `final/nl/<top>.nl.v` by default, or
  `final/pnl/<top>.pnl.v` with `netlist: pnl`, whose power pins SimCrux ties
  from a generated second top module. SimCrux never synthesises and never
  reshapes a netlist.
- **Your testbench, unedited.** The design sources the run synthesised are
  replaced by the netlist and the cell models; the testbench sources are kept.
  A generated module, written into SimCrux's own scratch directory and never
  into the run or the project, dumps the design's top-level ports.
- **The cell models from the run's own record.** `CELL_VERILOG_MODELS` in the
  run's `resolved.json`, found in your ciel or volare PDK install, even for a
  run copied from another machine. A PDK version that differs from the run's is
  said on the row. SimCrux never downloads a model.

## Choosing the tests {#entry}

The `flow:` entry of a LibreLane run names the tests, by test name:

```yaml
flow:
  entries:
    - name: counter_sky130
      kind: librelane
      config: librelane/config.yaml
      gls:
        tests: [counter_smoke, counter_random]
        netlist: nl          # nl (default) or pnl
        strict_x: false      # true: X-asymmetry only fails the test
        clock: clk           # only when the design has more than one clock input
```

SimCrux samples the comparison on the rising edge of the clock: the entry's
`clock`, else the run's own `CLOCK_PORT`, else the design's only input named
like a clock. With none or several to choose from the test does not run, and
the row says which inputs it found; name the clock in the entry.

## Running it {#run}

Select a LibreLane run in **View > Flow Runs** and choose **Tools > Run
Gate-Level Simulation** (or the button beside the run, or its context menu, or
the command palette). The tests appear in the results table as a run of their
own, with the trigger `gls` in the run history.

The Verdict cell of each row and its spoken name give the outcome and both
counts:

| Outcome | Meaning |
|---|---|
| **Equal** | The testbench passes at gate level and no port differs between RTL and gates. |
| **X-asymmetry only** | The only differences are places where the RTL was X (unknown) and the gates resolved to 0 or 1. Common and often harmless: an output the RTL never assigns, an `x * 0`, a mux with an unknown select. It passes unless `strict_x` is on, and the count is always shown. |
| **Differs** | The testbench fails at gate level, or a port is known on both sides and unequal, or the gates are X where the RTL is known (a register with no reset the RTL gave an initial value). On a completed run this is a finding, not an error. |
| **Did not run** | The comparison could not be made, and the row says why. |

A difference is counted per port per sample: one port that differs at one clock
edge is one difference. The comparison reads each port just before each rising
edge of the clock, never at the edge itself, where the RTL has already updated
and the unit-delay gates have not.

**Open Gate-Level Waveform in WaveCrux…** hands the port dump of the selected
result to WaveCrux. The inspector's Gate level section states which netlist was
simulated, the clock, the first difference and anything unusual about the PDK.

### Why a test did not run {#reasons}

| Reason | What to do |
|---|---|
| The test fails at RTL | Fix it first. A gate-level verdict on a failing test answers nothing, so it is not rerun. |
| The RTL did not build under Icarus | Gate-level simulation uses Icarus. A test written for Verilator may need changes to build there. |
| A VHDL test | The netlist is Verilog; mixed-language gate-level simulation is not supported. |
| The netlist's ports do not match the design | The testbench connects ports by name. A netlist whose bus ports were split into bits (a `splitnets -ports` step) cannot be bound; SimCrux does not reshape it. |
| The cell models were not found | Set the PDK root in Settings > Engines, or install the PDK with ciel. |
| No clock, or more than one | Name it in the entry's `gls: clock`. |
| The testbench's instance of the design was not found | The testbench must instantiate the design's top module by name. |

## From the command line {#cli}

```
simcrux flow gls <run-dir> [--entry <name>] [--test <name>]...
                 [--netlist nl|pnl] [--strict-x] [--clock <port>]
                 [--project <simcrux.yaml>] [--allow-project-tooling]
                 [--junit <out>] [--json]
```

The tests come from `--test`, or from the entry's `gls: tests`. `--entry`
names the LibreLane entry whose block supplies the defaults; with one
LibreLane entry in the project it is chosen for you.

| Exit code | Meaning |
|---|---|
| `0` | Every test that ran is equal, or X-asymmetry only without `--strict-x` (the count is still printed). |
| `1` | A test differs, or is X-asymmetry only under `--strict-x`. |
| `2` | No test could run: the netlist or models are missing, the ports do not bind, or every test fails at RTL. |
| `64` | The command line could not be honoured. |
| `65` | A run record or port dump could not be read. |

`--json` and `--junit` carry each test's outcome and both counts. Results go to
stdout, diagnostics to stderr, and nothing is transmitted.

## What it does not do {#limits}

- No timing: no setup or hold checks, and no delays from the run's SDF file. Static
  timing analysis is the flow's own result, read on the [Flow Runs
  panel](flow-runs.md).
- No Verilator, and no comparison across simulators.
- No synthesis and no netlist reshaping.
- On gf180mcuD and ihp-sg13g2 a result carries a banner: the models resolve and
  the netlist binds, but gate-level simulation is not yet measured on a design
  Icarus can judge there. Read such a result as unmeasured.
