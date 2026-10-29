# LibreLane fixtures: provenance

Captured LibreLane run directories, one set per release line, plus the designs
and configurations that produced them. Consumers: the LibreLane run, step and
metrics readers, the STA path report reader, the RTL mapping of an ASIC path,
the flow verdict, and the gate-level and equivalence work that needs a real
LibreLane netlist.

## Tools and date

Captured on 2026-10-22 on an Apple M4 Mac mini (darwin arm64), Nix 2.35.3
(Determinate) with the FOSSi Foundation binary cache, each LibreLane release
entered through its own checkout's `shell.nix`:

| LibreLane | Tag commit |
|---|---|
| 3.0.16 (current) | `01ddb25e4424f6f5aaf6b951b14a2b6fdcf737c0` |
| 3.0.15 (previous) | `d7538eca6b526387ebba3bbcdce0a86aee7cffd7` |

Both shells carry the same tools: Yosys 0.62 (git `7326bb7d`), OpenROAD
`dcf36133a369abc8f3c5e5738cd4d82e4903c0e0` (Nix package dated 2026-02-17),
KLayout 0.30.7, Magic 8.3.623, Verilator 5.044, ciel 2.4.0.

PDKs come from ciel under LibreLane's default PDK root (`~/.ciel`), at the
versions both releases pin in `librelane/pdk_hashes.yaml`:

| Family | Version (open_pdks commit) | Variant used | Standard cells |
|---|---|---|---|
| sky130 | `8afc8346a57fe1ab7934ba5a6056ea8b43078e71` | sky130A | `sky130_fd_sc_hd` |
| gf180mcu | `54435919abffb937387ec956209f9cf5fd2dfbee` | gf180mcuD | `gf180mcu_fd_sc_mcu7t5v0` |
| ihp-sg13g2 | `c4b8b4e5e7a05f375cca3815d51b3a37721fbf5c` | ihp-sg13g2 | `sg13g2_stdcell` |

`resolved.json` records `PDK_ROOT` as the ciel version directory itself,
`<home>/.ciel/ciel/<family>/versions/<version>`, with the variant directory
(`sky130A/`) beneath it. No enable step or symlink is involved.

The 3.0.17 set was captured on 2026-10-29 by that workflow itself, on
GitHub's `ubuntu-latest` (Linux x64), Nix with the FOSSi Foundation binary
cache, LibreLane entered through its checkout's `shell.nix`:

| LibreLane | Tag commit |
|---|---|
| 3.0.17 (current) | `64ef80802d3d189b476636d2a6b17888c03304ee` |

3.0.17 changes no LibreLane Python source against 3.0.16 (`git diff
3.0.16 3.0.17 -- librelane/` is empty) and pins the same three PDK versions;
its Nix shell adds one patch to Magic 8.3.623 (upstream commit `d083bef0`,
a memory fix). Run `40901974610` of `flow-live.yml` ran every case and the
mapping gate on it, checked each against expectations seeded from 3.0.16's
(the release field changed, nothing else), and kept the trimmed captures as
the `librelane-captures-3.0.17` artifact; those files are `3.0.17/` here
unchanged. The 3.0.17 expectations' exact values (metric values, and the
timing case's hold checker) were then written from LibreLane's own records in
that capture. Metric values differ from the darwin 3.0.16 capture (the DRC
case's counts, the timing case's slack); the live check compares their
signs, which agree.

The weekly workflow (`.github/workflows/flow-live.yml`, job `librelane`)
installs Nix, checks LibreLane out at the commits above, fetches the PDKs
with ciel (cached per family under the version hash LibreLane pins), reruns
every case of the current release and the sky130A reference case of each
older release on Linux x64, and checks each expectation.

## Command

Inside LibreLane's Nix shell, from the repository root:

```
tool/flow/regen_librelane_fixtures.sh [--case <name>]... [--work <dir>]
```

Per case, in a scratch copy of `designs/<design>/`:

```
librelane --pdk <variant> --run-tag <case> <config>
python3 -I tool/flow/trim_run_fixture.py runs/<case> <out>/<version>/<case>/run \
    --scrub <design copy>=<design> --keep-corner 'nom_t*' [--no-final-views]
```

The exit status goes to `exit_code.txt` and the last 60 console lines to
`console.tail.txt`. `trim_run_fixture.py` keeps every JSON file, log, report
and metric, the synthesis step's netlist and sidecar, and (for the completed
`*_met` cases) the text views in `final/nl`, `final/pnl`, `final/sdf`. It
replaces layout and binary views (GDS, ODB, DEF, SPEF, Magic, renders,
per-step netlist copies), tool environment scripts, the path listings of the
pre-PnR and mid-PnR STA steps, and the post-PnR path listings of every corner
but the nominal typical one (`nom_tt_*`, IHP `nom_typ_*`) with zero-byte
placeholders of the same name. It drops `tmp/`. `run/TRIMMED.json` lists each
placeholder and dropped file with its size and SHA-256. Home and scratch paths
are rewritten to `<home>`, `<design>` and `<run>`. Every kept file is under
5 MB.

## Cases

The small design is the designed-path adder of the nextpnr set
(`designs/path_adder/path_adder.v`, byte-identical to
`../nextpnr/rtl/path_adder.v`): 73 flip-flops, one deep register-to-register
path, `src_a + src_b` into `sum_q`.

| Version | Case | Config | Exit | Class |
|---|---|---|---|---|
| 3.0.16 | `sky130A_met` | `config.yaml` (10 ns) | 0 | completed, met |
| 3.0.16 | `gf180mcuD_met` | `config.yaml` (25 ns for gf180mcu) | 0 | completed, met |
| 3.0.16 | `ihp-sg13g2_met` | `config.yaml` (10 ns) | 0 | completed, met |
| 3.0.16 | `sky130A_stopped` | `config_stopped.yaml`: a 30 by 30 um die | 2 | stopped at `OpenROAD.GeneratePDN` (`PDN-0185`) |
| 3.0.16 | `sky130A_timing` | `config_timing.yaml`: 2 ns clock | 2 | completed, setup violations |
| 3.0.16 | `sky130A_drc` | `config_drc.yaml`: 70% density, `DRT_OPT_ITERS: 0`, `ERROR_ON_TR_DRC: false` | 2 | completed, routing, Magic and KLayout DRC errors, LVS errors |
| 3.0.16 | `sky130A_antenna` | `config_antenna.yaml`: 800 by 800 um die, antenna repair and diodes off, IR drop report off | 0 | completed, one antenna violation |
| 3.0.15 | `sky130A_met` | `config.yaml` | 0 | completed, met |

3.0.17 holds the same seven cases as 3.0.16, with the same exit statuses and
classes.

The mapping-gate design (PicoRV32, `designs/picorv32/`) is not trimmed into
the fixtures: its run is regenerated by the weekly workflow.
`MAPPING-GATE.md` has its result.

## Where each expectation comes from

Nothing named `*.expected.json` is produced by the regenerator or by the
product's readers. Each `case.expected.json` was written by hand from the
configuration's intent and from LibreLane's own records read with `jq` and
`ls`: the exit status, `resolved.json` `meta.librelane_version`, `PDK` and
`STD_CELL_LIBRARY`, which step directories hold no `state_out.json`,
`flow.log`'s `Running '<Step.Id>' at '<dir>'` and `Skipping step '<name>'`
lines, `error.log`, and `final/metrics.json`. `mapping.expected.json` is
written from `path_adder.v`: the worst register-to-register setup path starts
at `src_a` or `src_b` and ends at `sum_q` (line 16).
`test/static/flow_librelane_facts.dart` extracts the same facts independently
of the product's readers; `flow_librelane_fixtures_test.dart` compares them
exactly against the commit and `flow_librelane_live_test.dart` compares them
(metric signs, not values) against a fresh run.

A case's `differs_by_platform` names the facts the Linux x64 and darwin arm64
tool builds were seen to disagree on, with why: they are held exactly against
the commit and left out of the live comparison. Only `3.0.16/sky130A_timing`
has one: its hold result (no violation on the darwin capture, violations on
the Linux rerun of 2026-10-28) is incidental to a case about setup.
`3.0.17/sky130A_timing` carries the same note; its capture is the Linux one,
with the hold checker's deferred error in it.

## Measured layout

**Run-root records.** `runs/<tag>/` holds `resolved.json`, `flow.log`,
`warning.log`, `error.log`, `tmp/`, one `NN-<tool>-<step>/` directory per step
that ran, and `final/` (one directory per view, `metrics.json`,
`metrics.csv`). Same on all three PDKs and both releases; both releases write
the same 76 step directories for the met case.

**`resolved.json`.** 411 keys. `meta` is
`{"version": 2, "flow": null, "substituting_steps": null, "step": null,
"librelane_version": "3.0.16"}`: the flow name is not recorded (the console's
"Starting a new run of the 'Classic' flow" line is the only place it
appears). `DESIGN_DIR` and `PDK_ROOT` are absolute paths of the machine that
ran the flow; `PDK`, `STD_CELL_LIBRARY`, `DESIGN_NAME`, `CLOCK_PORT` and
`CLOCK_PERIOD` are plain values.

**Version detection.** `resolved.json` `meta.librelane_version` reads `3.0.15`,
`3.0.16` and `3.0.17` on the three releases. It is the field to key readers
on. 3.0.17 writes the same 76 step directories for the met case.

**Composite steps.** `OpenROAD.RepairAntennas` runs its own sub-steps in
numbered directories inside its step directory
(`42-openroad-repairantennas/1-openroad-diodeinsertion/`,
`.../2-openroad-checkantennas/`), and `flow.log` has a `Running` line for
each, so a step directory is a top-level `NN-slug` only.

**`flow.log` paths.** Step directories are written relative to the directory
LibreLane was started from (`runs/<tag>/06-yosys-synthesis` when started in
the design directory, a `../` chain otherwise); the final "Saving views to"
line is absolute. A reader keys on the last segment, never the prefix.

**Synthesis sidecar.** `06-yosys-synthesis/<design>.nl.v.json`, beside
`<design>.nl.v`, at the same step number on all three PDKs and both releases.
Rebuilding `write_verilog`'s `_NNN_` names joined every cell: 238 of 238 for
the adder, 6,704 of 6,704 for PicoRV32.

**Step status evidence.**

- A completed step has `config.json`, `state_in.json`, `state_out.json` and
  `runtime.txt`.
- A step that failed and stopped the flow has `config.json`, `state_in.json`
  and its logs, no `state_out.json`, no `runtime.txt`; it is the last
  directory, `error.log` holds the tool's error line (`[PDN-0185] ...`), there
  is no `final/`, and LibreLane exits 2.
- A checker that fails with a deferred error (setup violations, Magic DRC,
  KLayout DRC, LVS) also leaves no `state_out.json` or `runtime.txt`, but the
  flow continues, writes `final/` and exits 2 at the end. The Magic, KLayout
  and LVS checkers write `<N> ... errors found. - deferred` to `error.log`.
  The setup-violation checker writes nothing to `error.log`: the corners it
  fails on appear only in the console summary, and `flow.log` and
  `warning.log` list only the corners outside `TIMING_VIOLATION_CORNERS`.
  So a deferred failure is read as "a checker directory without
  `state_out.json`, followed by later steps".
- A step turned off by a flow variable gets no directory at all; numbering
  continues without a gap, and `flow.log` says `Skipping step '<name>'` with
  the step's display name, not its id. Every met run skips four this way
  (Repair Design (Post-Global Routing), Heuristic Diode Insertion, Resizer
  Timing Optimizations (Post-Global Routing), Equivalence Check); the antenna
  case adds Antenna Repair and IR Drop Report, so its last directory is
  `74-misc-reportmanufacturability` instead of `76-`. Smaller dies did not
  violate (300, 400 and 560 um were tried), and on the 800 um die the
  per-instance IR drop tables exceed 5 MB, hence the report is off.
- A step that decides at run time to do nothing gets a directory with
  `state_out.json` and says so only in `flow.log`
  (`'PDN_OBSTRUCTIONS' is not defined. Skipping 'Odb.AddPDNObstructions'`).
  On gf180mcuD, `KLayout.DRC` skips this way ("KLAYOUT_DRC_RUNSET is unset"),
  so `klayout__drc_error__count` is absent from its metrics: a reader treats it
  as not run, never as zero.

**Checker exit statuses.** 0 when the flow completes without a deferred
error, including with antenna violations (reported by
`Misc.ReportManufacturability`, not by a failing checker). 2 for a step
failure and for one or more deferred checker errors. The verdict therefore
comes from the records above and the metrics, never from the exit status
alone.

**STA reports.** `55-openroad-stapostpnr/` has one directory per corner (nine
on sky130A and gf180mcuD, three on IHP) and a `summary.rpt` table of every
corner. Each corner holds `max.rpt` and `min.rpt` (OpenSTA `report_checks
-sort_by_slack -group_path_count 1000 -format full_clock_expanded`, one path
per endpoint, at most 1,000 per path group), `wns`, `ws`, `tns`, `skew`,
`checks`, `power`, `clock` and `violator_list` reports, and `sta.log`.

## STA text reports: parseable

Every path of every corner's `max.rpt` and `min.rpt` was split into rank,
startpoint, endpoint, path group and type, slack, and segments (the pin rows
from the startpoint to the data arrival line): 25,104 paths across the seven
local runs of this set's designs (the adder on three PDKs and both releases,
the timing and DRC cases, and PicoRV32's 18,000 paths), none unparsed, and on
every path the slack equals required minus arrival (arrival minus required for
hold) to within 5e-6 ns and the last pin's time equals the arrival. Three
details a reader needs: the order is by slack only to the printed six
decimals (two adjacent paths can invert at the last digit); a listing is cut
at 1,000 endpoints per path group (PicoRV32's 1,597 flip-flops do not all
appear); and one corner's `max.rpt` reached 8 MB on PicoRV32, so it is read as
a stream. `test/static/flow_librelane_fixtures_test.dart` reparses every kept
listing on every run.

## Hand-off commands

Read from LibreLane 3.0.16's source and the tools' own `--help`; no GUI was
opened while measuring.

- **LibreLane's own flows:** `librelane --run-tag <tag> --flow OpenInKLayout
  <config>` and `--flow OpenInOpenROAD` (also `OpenInMagic`), started in the
  design directory or with `--design-dir`. Without `--with-initial-state`
  LibreLane loads the newest `state_out.json` of the run and appends a new
  step directory to it: it writes into the run and deletes nothing. With
  `--with-initial-state <run>/<last step>/state_out.json --run-tag <new tag>`
  the measured run is left untouched. LibreLane's documentation shows
  `--last-run`, which picks the newest run by modification time.
- **What those flows start:** `klayout -rm <librelane>/scripts/klayout/open_design.py`
  with the GDS (or DEF) and the PDK's technology and layer properties passed
  in `KLAYOUT_ARGV`; `openroad -no_splash -gui <librelane>/scripts/openroad/gui.tcl`
  with the ODB, Liberty files and SPEF passed in the environment.
- **Direct:** `klayout <run>/final/gds/<design>.gds`, and with DRC markers
  `klayout <gds> -m <run>/NN-klayout-drc/reports/drc.klayout.lyrdb` (or
  `NN-magic-drc/reports/drc.magic.lyrdb`); KLayout 0.30.7 documents `-m` as
  "Load RDB (report database) file (into previous layout view)".
  `openroad -gui -db <run>/final/odb/<design>.odb` (OpenROAD lists `-gui`,
  `-db`, `-no_splash`, `-minimize`, `-no_settings`).
- **OpenROAD web viewer:** not available in the OpenROAD that LibreLane 3.0.16
  ships: no `-web` option, and no command matching `*web*` in its Tcl
  interpreter.
- **nextpnr GUI:** `nextpnr-ice40`, `nextpnr-ecp5` and `nextpnr-himbaechel`
  list `--gui` (and `--gui-no-aa`) in the darwin-arm64 OSS CAD Suite builds of
  2026-08-21, 2026-09-21 and 2026-10-21. The Linux builds were not checked
  here.

Hand-offs need the binary views, so they work on a real run directory, not on
these trimmed fixtures. `state_out.json` paths are absolute to the machine
that ran the flow, so a run copied from CI needs its paths rebased before
LibreLane's own flows can load it.
