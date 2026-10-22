# Implementation flow, from 1.2

From SimCrux 1.2, a project can run an FPGA or ASIC implementation flow next to
its simulations, or point SimCrux at runs it already has, and read what the open
tools report: every step, every metric and the worst timing paths, with a jump
from a path to the RTL that drives it. SimCrux shows what the tools write. It
adds no analysis of its own to the verdict.

<!-- vocabulary-guard: disclaimer begin -->
Results are findings, not signoff.
<!-- vocabulary-guard: disclaimer end -->

Everything on these pages is open core and free in every tier, except the
comparison and trend screens listed under [Pro](#pro).

## The pages {#pages}

| Page | What it covers |
|---|---|
| This page | What a flow run is, the `flow:` block, the verdict, settings |
| [nextpnr runs](flow-nextpnr.md) | FPGA place and route, directly or through FuseSoC |
| [Ingesting runs](flow-ingest.md) | Runs SimCrux did not launch, and zipped CI artifacts |
| [The Flow Runs panel](flow-runs.md) | Run list, steps, metrics, worst paths, RTL mapping and fidelity labels |
| [Hand-off to viewers](flow-handoff.md) | Opening a run in KLayout, OpenROAD or nextpnr's own viewer |
| [Gate-level simulation](flow-gate-level.md) | Rerunning tests against a LibreLane run's netlist, the outcomes, `simcrux flow gls` |
| [CI gate](flow-ci.md) | `simcrux flow`, thresholds, the exit-code table and recipes |
| [Troubleshooting](flow-troubleshooting.md) | macOS `PATH`, Windows, `XDG_DATA_HOME` |

A LibreLane run that SimCrux lists is labelled **reader not
verified**: SimCrux reads the run directory best-effort and says so before the
verdict, so read its result as such.

## The `flow:` block {#flow-block}

A `simcrux.yaml` gains a top-level `flow:` block. It lists the runs SimCrux
launches (`entries:`) and the runs it reads without launching (`ingest:`):

```yaml
flow:
  entries:
    - name: blinky_ecp5
      kind: nextpnr
      family: ecp5
      device: 25k
      package: CABGA256
      top: top
      sources: [rtl/top.v]
      constraints: board/ulx3s.lpf
      freq_mhz: 25
  ingest:
    - runs/earlier/simcrux-20261020T090000Z
```

- **One entry is one test.** Each entry becomes a test in a suite SimCrux makes
  for you, named `flow`, so its id is `flow/<name>`. It has a four-hour timeout
  and is never retried. A project with a `flow:` block and no `suites:` loads.
  A suite you name `flow` beside flow entries is refused.
- **Entry names** are one plain name of letters, digits, `_`, `.` and `-`, at
  most 64, because the name is a directory and a test id.
- **The block is not inherited** through `defaults:` or a suite, and an
  unknown key, or a key that belongs to the other kind of entry, is an error that
  names the line, so a misspelt key cannot quietly fall back to a default.
- **`ingest:`** is a list of run directories and `report.json` files. See
  [Ingesting runs](flow-ingest.md).

The keys of a `nextpnr` entry are on [nextpnr runs](flow-nextpnr.md#entry). Keys
that choose a program or a command line need project tooling to be allowed:

| Key | Without permission |
|---|---|
| `fusesoc`, `extra_args`, `handoff` on any entry | The project does not load |
| `fusesoc.binary`, and the LibreLane launcher and binary keys | Ignored, with one advisory naming them; the Settings choice, or the conventional name on `PATH`, is used |

In the app, turn on **Settings → Engines → Let project files choose simulator
binaries and environment**. Headless, pass `--allow-project-tooling`. See
[Projects and simulators](projects-and-simulators.md#schema).

## The verdict {#verdict}

Every flow run has one verdict, read from the run's own report or records and
never from the process exit code:

| Verdict | Meaning | Test status |
|---|---|---|
| **Met** | The run completed and its constraints are met. | Pass |
| **Violated** | The run completed and a constraint or a check is not met. | Fail |
| **Stopped** | The run stopped before it finished; the step it stopped at is named. | Fail |
| **Did not run** | A tool was missing, or the run produced no report. | Fail |
| **Unrecognised** | SimCrux could not read the run's result. | Fail |

A violated run is a finding about your design, and the table shows it that way,
not as a tool error. The exit code is recorded as `flow.process_exit_code` and
decides nothing: nextpnr exits `1` on a timing miss and still writes its report,
and that report is what makes the run **Violated**.

## Run flow entries {#run}

- **In the app:** **Run Regression** runs the flow entries with the simulation
  tests, and **Esc** cancels either. **Tools → Run Flow Entry** runs the entry of
  the selected run, or all of them when none is selected.
- **From a terminal:** `simcrux flow run [--entry <name>]... [<project>]`. See
  [CI gate](flow-ci.md).

SimCrux never deletes, reuses or resumes a run directory. Every run gets a fresh
one inside the project, so an earlier run is still there to compare.

## Settings {#settings}

**Settings → Engines → Implementation flow** (from 1.2) holds the tool paths
for flows. Leave a path empty to use `PATH`.

| Setting | What it is |
|---|---|
| nextpnr | A directory holding the nextpnr executables and Yosys (an OSS CAD Suite `bin/` is the usual choice), or one executable |
| KLayout path | The KLayout executable used by [Open in KLayout](flow-handoff.md) |
| OpenROAD path | The OpenROAD executable used by [Open in OpenROAD](flow-handoff.md) |
| FuseSoC path | The FuseSoC executable used by a [FuseSoC entry](flow-nextpnr.md#fusesoc) |

The same card holds the settings for LibreLane runs, which are described
separately. **Check flow tools** probes every tool and lists which were found
and which were not, with the platform's guidance for each missing one. An app
opened from the Finder does not see your shell's `PATH`; see
[Troubleshooting](flow-troubleshooting.md).

## Pro {#pro}

<span class="tier tier-pro">Pro</span> Comparison and history over many runs:
**Tools → Flow Metric Trends…**, **Compare Flow Runs…**, **PPA Dashboard…**,
**Design-Space Sweep…** and **Write Flow Baseline…**, and from a terminal
`simcrux-pro flow compare` and `simcrux-pro flow baseline write`. They read the
same runs the free panel lists and change no verdict. In an open core build each
menu item stays enabled, badged, and answers that it requires SimCrux Pro.

<span class="tier tier-enterprise">Enterprise</span> A signed policy file can set
[thresholds for every implementation run](administration.md#flow-thresholds).
