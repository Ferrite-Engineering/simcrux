# nextpnr runs, from 1.2

From SimCrux 1.2, a `flow:` entry of `kind: nextpnr` synthesises your RTL with
Yosys and places and routes it with [nextpnr](https://github.com/YosysHQ/nextpnr)
for an open FPGA family: Lattice iCE40, Lattice ECP5, Gowin and Cologne Chip
GateMate. The run's timing report is read into the [Flow Runs panel](flow-runs.md),
and the run's verdict is read from that report. This page is part of
[Implementation flow](flow.md).

<!-- vocabulary-guard: disclaimer begin -->
Results are findings, not signoff.
<!-- vocabulary-guard: disclaimer end -->

## Tools {#tools}

An [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build) carries Yosys
and every nextpnr SimCrux runs. Set **Settings → Engines → Implementation flow →
nextpnr** to its `bin/` directory, or put it on `PATH`. SimCrux runs
`nextpnr-ice40` and `nextpnr-ecp5` for those families, and `nextpnr-himbaechel`
for Gowin and GateMate. **Check flow tools** reports which of them it found.

## A direct entry {#entry}

```yaml
flow:
  entries:
    - name: blinky_ice40
      kind: nextpnr
      family: ice40          # ice40 | ecp5 | gowin | gatemate
      device: up5k
      package: sg48
      top: top
      sources: [rtl/top.v]
      constraints: board/icebreaker.pcf
      freq_mhz: 12
      detailed_timing: true
```

| Key | Meaning |
|---|---|
| `name` | Required. The entry name; the test id is `flow/<name>`. |
| `kind` | Required. `nextpnr` here. |
| `family` | Required. `ice40`, `ecp5`, `gowin` or `gatemate`. |
| `device` | Required. The device as nextpnr names it: `up5k` for iCE40, `25k` for ECP5. SimCrux writes `--<device>` for those two families and `--device <device>` for the others. |
| `package` | Required for iCE40 and ECP5. |
| `top` | Required. The top module, a plain HDL identifier. |
| `sources` | Required. The RTL files to synthesise, relative to the project file. |
| `constraints` | Optional. The pin constraint file: `.pcf` for iCE40, `.lpf` for ECP5, `.cst` for Gowin, `.ccf` for GateMate. [LintCrux](https://docs.lintcrux.app/pin-constraints) can check a `.pcf`, `.lpf` or `.cst` file against your top module's ports before you run. |
| `freq_mhz` | Optional. The clock target in MHz, passed to nextpnr as `--freq`. |
| `detailed_timing` | Optional. `true` asks nextpnr for its detailed timing report, which adds each register's net delays. |
| `netlist` | Optional. Which file in the run directory is the synthesised netlist, for [mapping worst paths to your RTL](projects-and-simulators.md#flow-netlist). |
| `extra_args` | Optional. Extra arguments appended to the nextpnr command line. Needs [project tooling](flow.md#flow-block). |
| `handoff` | Optional. A viewer's whole command line; see [Hand-off](flow-handoff.md#custom). Needs project tooling. |

What a run does:

1. **Synthesis.** Yosys runs `synth_<family> -top <top>` and writes `synth.json`
   into the run directory. A synthesis that fails stops the run at
   `synthesis`.
2. **Place and route.** nextpnr runs from the run directory with
   `--json synth.json --report report.json --write post.json --log pnr.log`
   (plus `--freq` and `--detailed-timing-report` when you set them). The
   timing report is `report.json`; `post.json` is the placed and routed netlist.

The run directory is `<project>/runs/<entry>/<tag>/`, with a fresh tag made from
the UTC time at each run. It is created inside your project, with symbolic links
resolved, and a directory that would land outside is refused and nothing is
spawned. Nothing already there is overwritten or deleted.

## The verdict {#verdict}

The verdict comes from `report.json`:

- **Met** when every clock reaches its constraint.
- **Violated** when a clock misses its constraint. nextpnr exits `1` on this
  and still writes the report, so a miss is a finding about your design and
  not a tool failure.
- **Did not run** when nextpnr (or Yosys, or FuseSoC) could not be started, or
  exited `0` without writing a report.
- **Stopped** at `synthesis` when Yosys failed.

For each clock the panel also shows a worst slack derived from the report:
`1000/constraint - 1000/achieved` nanoseconds, with the constraint and the
achieved clock in MHz, and the run's worst slack is the minimum across clocks.
`simcrux flow gate --json` names that derivation. It is a period slack, so it
is not the path slack OpenSTA would print for the same design.

## Through FuseSoC {#fusesoc}

An entry may hand the whole build to [FuseSoC](https://github.com/olofk/fusesoc)
instead. FuseSoC and its Edalize backend run Yosys and nextpnr with their own
options, so the keys that describe the build (`family`, `device`, `package`,
`constraints`, `top`, `sources`, `freq_mhz`, `detailed_timing`, `extra_args`)
are an error beside `fusesoc`.

```yaml
flow:
  entries:
    - name: servant_icebreaker
      kind: nextpnr
      fusesoc:
        core: award-winning:serv:servant
        target: icebreaker
```

| Key | Meaning |
|---|---|
| `fusesoc.core` | Required. The core, as `fusesoc run` names it. |
| `fusesoc.target` | Required. The core's target. |
| `fusesoc.binary` | Optional. A `fusesoc` executable for this entry. Needs [project tooling](flow.md#flow-block). |

The whole `fusesoc` block needs project tooling, because its core and target
become the command line. SimCrux runs `fusesoc run --build-root <run directory>
--target=<target> <core>` from the project directory, so your `fusesoc.conf`
applies, and then reads the shallowest `report.json` it left under the run
directory. When Edalize passed no `--report`, SimCrux reads nextpnr's own log
instead. The worst paths come from the report, so a run read from the log has
none to list. FuseSoC itself is found at **Settings → Engines → Implementation flow → FuseSoC
path**, or on `PATH`.

## Run it {#run}

In the app, **Run Regression** runs flow entries with your tests, and
**Tools → Run Flow Entry** runs one. From a terminal:

```bash
simcrux flow run --entry blinky_ice40 simcrux.yaml
```

The command prints one line for each entry, `flow/<name>: <verdict>` and the run
directory, and exits by the [exit codes](flow-ci.md#exit-codes). `Ctrl+C`
cancels the run and kills the whole process tree.
