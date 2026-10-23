# Hand-off to viewers, from 1.2

From SimCrux 1.2, a run can be opened in the tool that is made to look at it,
with the right file already loaded: KLayout for a layout, OpenROAD's GUI for a
design database, and nextpnr's own viewer for a placed and routed FPGA design.
SimCrux starts the viewer and steps aside. This page is part of
[Implementation flow](flow.md).

<!-- vocabulary-guard: disclaimer begin -->
Results are findings, not signoff.
<!-- vocabulary-guard: disclaimer end -->

## The three viewers {#viewers}

| Viewer | Opens | Which runs |
|---|---|---|
| **KLayout** | The run's final GDS layout, from the run's `final/gds/` folder. Layouts here come from flows on the open PDKs sky130, gf180mcu and ihp-sg13g2. | LibreLane runs |
| **OpenROAD** | The run's final database, from `final/odb/`, through a one-line read script SimCrux writes to its own scratch directory, never into the run. | LibreLane runs |
| **nextpnr GUI** | The placed and routed netlist, `post.json`, with the device the entry names. | nextpnr runs |

How a LibreLane run is produced and read is on [LibreLane
runs](flow-librelane.md). A viewer that is given the wrong kind of run says so in
a toast ("KLayout opens LibreLane runs. Select a LibreLane run first.") instead of
starting.

### LibreLane runs in KLayout and OpenROAD {#librelane}

For a LibreLane run that belongs to a project entry, SimCrux opens the viewer
through LibreLane's own `OpenInKLayout` or `OpenInOpenROAD` flow, because that
flow supplies the PDK's layer properties and the run's own views. SimCrux starts
it from the run's newest step state, `--with-initial-state`, into a **new run
tag**, `simcrux-view-<UTC time>`, beside the run. The run you measured is never
written to, and SimCrux never passes `--overwrite` or `--last-run`. This needs the
Executable or Nix launcher and a run in the entry's own `runs/` folder.

Otherwise, for example for a Docker launcher (a container has no display), an
ingested run or a run outside the entry's `runs/` folder, KLayout opens the run's
final GDS directly, with the run's DRC markers when it has them, and OpenROAD
reads the final database. The layout is whatever the flow produced on one of the
open PDKs, sky130, gf180mcu or ihp-sg13g2.

## Open a run {#open}

Select the run in [Flow Runs](flow-runs.md), then choose **Tools → Open in
KLayout…**, **Open in OpenROAD…** or **Open in nextpnr GUI…**. The same actions
are in the command palette and on the panel's buttons, and the inspector offers
them on a selected flow result. With no run selected, SimCrux says to select
one first.

The viewer starts **detached**: it is your window, it outlives SimCrux, and
SimCrux neither waits for it nor closes it. SimCrux starts it with the extra
search directories an app needs (an app opened from the Finder does not see your
shell's `PATH`), and it finds every file it names inside the run directory, with
symbolic links resolved.

When the viewer is not installed, SimCrux does not treat that as an error. It
says so in a toast that names **Settings → Engines → Implementation flow**, where
the KLayout and OpenROAD paths go (see [Settings](flow.md#settings)). A run with
nothing the viewer opens, for example one with no final layout, says that.

## A custom command {#custom}

A `handoff:` block on a flow entry replaces a viewer's command line with your
own. The keys are `klayout`, `openroad_gui` and `nextpnr_gui`, each a command
as a list. Four placeholders are filled in before it starts:

| Placeholder | Filled with |
|---|---|
| `{run_dir}` | The run directory |
| `{gds}` | The first `.gds` file under `final/gds/`, or empty |
| `{odb}` | The first `.odb` file under `final/odb/`, or empty |
| `{json}` | The run's `post.json`, or empty |

```yaml
flow:
  entries:
    - name: blinky_ecp5
      kind: nextpnr
      # ...
      handoff:
        nextpnr_gui: [nextpnr-ecp5, --gui, --25k, --json, '{json}']
```

Because a `handoff:` command chooses a whole program and its arguments, it needs
[project tooling](flow.md#flow-block) to be allowed: without it the project does
not load.
