# Troubleshooting implementation runs, from 1.2

The usual reasons a flow run does not start, does not map, or does not open. This
page is part of [Implementation flow](flow.md). Start with **Settings → Engines
→ Implementation flow → Check flow tools**, which lists every tool it found and
the platform's guidance for each one it did not.

<!-- vocabulary-guard: disclaimer begin -->
Results are findings, not signoff.
<!-- vocabulary-guard: disclaimer end -->

## A tool was not found {#tool-missing}

The run's row reads **Did not run** and names the tool: Yosys, nextpnr or FuseSoC.

- Install the [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build),
  which ships Yosys and nextpnr together, and set **nextpnr** in Settings to its
  `bin/` directory, or put that directory on `PATH`.
- FuseSoC is a separate install (`pip install fusesoc`). Set **FuseSoC path** in
  Settings, or give the entry its own `fusesoc.binary` when project tooling is
  allowed.
- KLayout and OpenROAD are needed only to [open a run](flow-handoff.md). A
  missing viewer is a toast, never a failed run.

## macOS: an app opened from the Finder does not see your `PATH` {#macos}

A Mac app started from the Finder, the Dock or Spotlight gets the system's
`PATH`, not the one your shell sets up in `.zshrc`. A tool you can run in a
terminal can still be "not found" in SimCrux. Set the path in **Settings →
Engines → Implementation flow** (the nextpnr row to an OSS CAD Suite `bin/`
directory, and the KLayout, OpenROAD and FuseSoC rows to their executables), or
start SimCrux from a terminal. A headless `simcrux flow` run uses the shell it was
started from, so it is not affected.

## Windows {#windows}

The OSS CAD Suite has a Windows build, and SimCrux runs `nextpnr-*.exe` and Yosys
from the directory you set. If a native tool is the problem, run the
tools, and the headless `simcrux flow` commands, under WSL2 instead, with Linux
paths. LibreLane runs are described on [LibreLane runs](flow-librelane.md);
ingesting a run directory works natively on Windows.

## `XDG_DATA_HOME` {#xdg}

nextpnr needs `XDG_DATA_HOME` to point at a writable directory. SimCrux sets it
to a directory inside the test's own work directory when neither the project's
environment nor yours defines one. If you set it yourself, SimCrux leaves it
alone, and a directory that is not writable shows up as a failure from nextpnr
in the run's log. An empty `XDG_DATA_HOME` counts as unset.

## The run says Violated, and the exit code was `1` {#violated}

That is a finding, not a tool failure. nextpnr exits `1` when a clock misses its
constraint and still writes its report, and SimCrux reads the report. Open the
run in [Flow Runs](flow-runs.md) to see which clock and which path. The exit code
itself decides nothing; see [The verdict](flow.md#verdict).

## **Did not run** with an exit code of `0` {#no-report}

nextpnr exited `0` and wrote no `report.json`, so there is nothing to read. Open
the run log (**Open Run Log** in the Steps section): it holds nextpnr's own
output. If the entry sets `extra_args`, check that none of them changes where
nextpnr writes its report.

## Worst paths are all unmapped {#unmapped}

The run holds no synthesised netlist SimCrux can read, or holds more than one
and SimCrux does not guess. Name the file with the entry's
[`netlist:`](projects-and-simulators.md#flow-netlist) key. A `report.json`
ingested on its own has no netlist at all, and the panel says so. See
[the fidelity labels](flow-runs.md#mapping) for what each end of a path can say.

## An ingest path was refused {#ingest}

A path in `flow: ingest:` must be inside the project directory, with symbolic
links resolved, and a zipped artifact is checked whole before anything is written.
The panel's problems line counts the refusals and its tooltip names them. See
[Ingesting runs](flow-ingest.md#zip).

## A run says "reader not verified" {#unverified}

That label is on a LibreLane run from a release the readers are not verified for.
SimCrux reads the run directory best-effort and says so before the verdict, and
records why as `version_unknown`, `layout_unknown` or `schema_unknown`. The
verified releases are listed on [LibreLane runs](flow-librelane.md#reading). Treat
the result of any other release accordingly.

## A LibreLane run does not start {#librelane}

The row reads **Did not run** and names the tool: `librelane`, `nix` or `docker`.
Check **Settings → Engines → Implementation flow**: the launcher, the
**librelane** path (for Nix, the LibreLane checkout that holds its flake), the
Docker image and the PDK root, then **Check flow tools**. See [LibreLane
runs](flow-librelane.md#launchers).

## The project does not load {#load}

An unknown key in a `flow:` entry, a key that belongs to the other kind of
entry, a `handoff:`, `extra_args` or `fusesoc` block without project tooling, or
two entries with one name all stop the load, and the message names the file and
line. Fix the line it names. See [the `flow:` block](flow.md#flow-block).
