# LibreLane runs, from 1.2

From SimCrux 1.2, a project can run an ASIC flow with
[LibreLane](https://github.com/librelane/librelane) on the open PDKs, or read a
LibreLane run it already has, and see what LibreLane's own checks and OpenSTA
report: the verdict, every step, the metrics, the worst setup paths and a
nearest-register link from a path to your RTL. SimCrux shows what the tools
write. It adds no analysis of its own to the verdict. This page is part of
[Implementation flow](flow.md).

<!-- vocabulary-guard: disclaimer begin -->
Results are findings, not signoff.
<!-- vocabulary-guard: disclaimer end -->

Everything on this page is open core and free in every tier.

## The entry {#entry}

A LibreLane run is a `flow:` entry of kind `librelane` that names the design's
LibreLane configuration:

```yaml
flow:
  entries:
    - name: counter_sky130
      kind: librelane
      config: librelane/config.yaml
      pdk: sky130A
      tag_prefix: simcrux
```

| Key | What it does |
|---|---|
| `name` | The entry's name; its test id is `flow/<name>`. See [the `flow:` block](flow.md#flow-block). |
| `kind` | `librelane`. |
| `config` | The LibreLane configuration file, inside the project directory. Required. |
| `pdk` | The PDK name passed to LibreLane as `--pdk`, for example `sky130A`, `gf180mcuD` or `ihp-sg13g2`. Without it LibreLane uses the configuration's own choice. |
| `tag_prefix` | The start of each run's tag. Default `simcrux`. One plain name of letters, digits, `_`, `.` and `-`. |
| `launcher` | `path`, `nix` or `docker`. Without it, the choice in Settings. [Needs project tooling](#tooling). |
| `librelane_binary` | The `librelane` executable, for the `path` launcher. [Needs project tooling](#tooling). |
| `docker_image` | The image the `docker` launcher runs. [Needs project tooling](#tooling). |
| `handoff` | A custom viewer command. See [Hand-off to viewers](flow-handoff.md#custom). |
| `gls` | The tests to rerun at gate level. See [Gate-level simulation](flow-gate-level.md#entry). |

An unknown key, or a key that belongs to a nextpnr entry, is an error that names
the line. Run the entry with **Run Regression** or **Tools → Run Flow Entry**,
or `simcrux flow run --entry <name>`. See [CI gate](flow-ci.md).

## How LibreLane is started {#launchers}

Choose the launcher under **Settings → Engines → Implementation flow → LibreLane
launcher**. Each entry can override it when
[project tooling](#tooling) is allowed.

| Launcher | What SimCrux runs |
|---|---|
| **Executable** | `librelane` from the **librelane** row of the same card (a directory that holds it, or the executable itself), the entry's `librelane_binary`, or `librelane` on `PATH`. |
| **Nix** | `nix develop <checkout> --command librelane …`, where the checkout is the directory the **librelane** row names: the LibreLane checkout that holds its flake. LibreLane under Nix is the recommended install. |
| **Docker** | `docker run --rm --name simcrux-<tag> …` with the design directory (and the PDK root, when set) mounted at the same paths, the design directory as the working directory, and the image from **LibreLane Docker image** or the entry's `docker_image`. |

A Docker run is cancelled by stopping its named container with `docker stop` as
well as the client, and every launcher's cancel kills the whole process tree
(Yosys, OpenROAD, Magic, KLayout and Netgen are its children). A Docker run has
no display, so [Open in KLayout and Open in OpenROAD](flow-handoff.md#librelane)
read the run's files directly for it.

The card's other LibreLane rows:

| Setting | What it is |
|---|---|
| LibreLane launcher | Executable, Nix or Docker |
| LibreLane Docker image | The image the Docker launcher runs; empty until you set it |
| PDK root | The directory that holds the installed PDKs. SimCrux passes it as `--pdk-root` and as `PDK_ROOT`. Empty uses your environment's. |
| **Check flow tools** | Probes LibreLane, Nix, Docker, OpenROAD, Yosys, KLayout and the PDK root, and lists the PDKs it found |

## Project tooling {#tooling}

`launcher`, `librelane_binary` and `docker_image` choose what SimCrux executes,
so they take effect only when project tooling is allowed (**Settings → Engines →
Let project files choose simulator binaries and environment**, or
`--allow-project-tooling`). Without it they are ignored, with one advisory naming
them, and the Settings choice is used. See [the `flow:` block](flow.md#flow-block).

## Where a run goes {#runs}

SimCrux starts LibreLane in the directory that holds the configuration and gives
every run its own tag, `<tag_prefix>-<UTC time>` such as
`simcrux-20261021T120000Z`, so the run is `runs/<tag>/` beside the configuration.
A tag whose directory already exists is never reused: SimCrux adds `-2`, `-3` and
so on.

SimCrux never passes `--overwrite` or `--last-run` to LibreLane, and never
deletes or resumes a run directory. An earlier run is always still there to
[compare](flow-runs.md).

## How a run is read {#reading}

SimCrux reads a LibreLane run, whether it launched it or you
[ingested](flow-ingest.md) it, with the reader for the run's release. The release
comes from the run's own `resolved.json`.

The readers are verified for exactly these releases:

--8<-- "librelane-verified.md"

Any other release is still read, by the nearest older reader, and marked **reader
not verified**: a banner says so before the verdict, the run's `flow.reader_verified`
metric is `false`, and the reason is recorded as `flow.reader_unsupported`.

| Reason | Meaning |
|---|---|
| `version_unknown` | The run states no release, or one no reader was verified against |
| `layout_unknown` | The directory is not laid out as a LibreLane run |
| `schema_unknown` | A record in the run is not the shape the reader expects |

Read an unverified run's result as best-effort. Pro screens mark it too, on the
run and on a trend point.

## The verdict {#verdict}

The verdict follows LibreLane's own checks, read from the run's records and
never from the exit status. LibreLane exits non-zero when a checker flags a
finding, and SimCrux records that code without using it.

- **The checks are LibreLane's.** SimCrux judges the metric of each LibreLane
  checker (setup and hold violation counts, slew and capacitance, routing, Magic
  and KLayout DRC, density, LVS, antenna, XOR, illegal overlaps, disconnected
  pins, power grid, wire length, unmapped cells, synthesis checks and lint
  errors) the way that checker does, with the run's own `ERROR_ON_*` settings and
  corner lists.
- **A waived check is a note.** A finding LibreLane's configuration only warns
  about, for example a corner outside the checked corner list or an `ERROR_ON_*`
  setting turned off, is kept and shown, written to SARIF as a note, and leaves
  the verdict alone.
- **Negative slack alone is not a violation.** The setup and hold checks count
  violating paths for the corners LibreLane is told to check. A negative worst
  slack in a corner outside that list shows under **Metrics** and decides
  nothing by itself.
- **Antenna counts count.** The two antenna counts no LibreLane checker fails on
  still make a run **Violated**.
- **A check that did not run is not zero.** A run with no result for a check
  (a gf180mcuD run has no KLayout DRC result by default, for example) leaves
  that check out, and SimCrux does not read the gap as a pass.

A run that stopped names its step, and the run is **Stopped**. A violated run is a
finding about your design, not a tool error. See [The verdict](flow.md#verdict).

## Worst paths and the RTL link {#paths}

The worst paths are the setup paths OpenSTA reported in the run's post-route
timing step, for the corner the setup check covers, worst first. A run without
that listing says so and keeps its worst slack and violation counts under
**Metrics**. The table and its dialogs are described on
[The Flow Runs panel](flow-runs.md#paths).

Each end of a path is mapped to your RTL through the netlist Yosys wrote at
synthesis, and on an ASIC run the label is **nearest register**:

- A register named here is the nearest register the synthesised design records,
  not a proof of where in your source a signal comes from. Most flip-flops carry
  no source span of their own, so SimCrux finds the register by the name of the
  net on the flip-flop's output.
- A register-file bit maps to the memory (`cpuregs` in a design that has a
  register file built from flip-flops), not to one word of it.
- A cell that place and route added, such as a buffer or a clock-tree cell, has
  no entry from synthesis and is shown unmapped.
- An end that is an output port has no register. The path shows the port's name.

On one design measured for this release (a 1,597 flip-flop core on sky130A), 98
of the worst 100 setup endpoints mapped to a register; the other two were output
ports. One design, one PDK and one LibreLane release is not a rate for yours.

## Opening a run {#open}

**Tools → Open in KLayout…** and **Open in OpenROAD…** work on a LibreLane run.
See [Hand-off to viewers](flow-handoff.md#librelane): SimCrux starts LibreLane's
own open flows into a new run tag, so the measured run is never written to.

## Pro {#pro}

<span class="tier tier-pro">Pro</span> Comparison, trends and the PPA dashboard
read LibreLane runs as they read nextpnr runs. See [Implementation
flow](flow.md#pro).
