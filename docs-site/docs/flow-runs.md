# The Flow Runs panel, from 1.2

From SimCrux 1.2, **View → Flow Runs** opens a dock tab that lists a project's
implementation runs: the ones SimCrux launched, the ones the project's
[`ingest:`](flow-ingest.md#project) list names, and the ones you ingested. This
page covers the run list, the steps, the metrics, the worst timing paths and how
a path is mapped back to your RTL. It is part of
[Implementation flow](flow.md).

<!-- vocabulary-guard: disclaimer begin -->
Results are findings, not signoff.
<!-- vocabulary-guard: disclaimer end -->

The panel opens in the bottom dock beside the Log, and can be dragged to the
right dock. Its close button hides it. With no run it says "No flow runs yet. Add
a flow: entry or ingest a run directory." and offers **Ingest Run Directory…**.

## The run list {#runs}

The newest run is first. The columns are **Verdict**, **Design** (the flow
entry), **Tag** (the run's directory name) and **Flow** (LibreLane or nextpnr).
Select a run and the panel shows, above its details:

- **The heading**, the design and its verdict in words: Met, Violated, Stopped
  at a step, Did not run, or Unrecognised.
- **How it was read**: "Read by `<reader>` (`<version>`)". A LibreLane run
  also carries a banner before the heading, "Reader not verified for this run's
  LibreLane version. Results are read best-effort from the run directory."
- **The change since the last run**, compared with the same design's previous
  run on worst slack (otherwise the achieved clock), in words and an arrow, for
  example "Slack 0.412 ns worse than the previous run". It is never carried by
  colour alone.
- **Problems**, a count of ingest paths that named no run, with the paths in its
  tooltip.

The panel re-reads its runs every three seconds while a regression runs, and once
more when it ends. A change of the shown run's verdict is spoken.

A **Steps / Metrics / Worst paths** switch below the heading chooses what the
rest of the panel shows.

## Steps {#steps}

A flow that records its steps (LibreLane) lists each with its number, name,
tool, status (Completed, Failed, Skipped, Running or Not started) and time in
seconds. Open a step for a dialog with its status and the last 200 lines of its
largest log (at most 64 KiB), and **Open Full Log in Editor**. A nextpnr run
records no steps, and the section says so and offers **Open Run Log**.

## Metrics {#metrics}

One row for each metric the run reports, with the metric's label, its
design-wide value and one column for each corner, the corner names as the tool
wrote them. The raw metric key, such as `timing__setup__wns`, is on hover and is
what `--fail-on` takes. Verdict tokens and metric keys are never translated.

SimCrux has labels and units for the common ones: setup and hold worst slack
(`timing__setup__ws`, `timing__hold__ws`), worst and total negative slack
(`timing__setup__wns`, `timing__hold__wns`, `timing__setup__tns`,
`timing__hold__tns`), the counts of paths that miss setup or hold, the achieved
clock (`fmax__achieved__mhz`), cell area, utilisation and count, route DRC
errors, LVS errors, antenna counts, power, and the used and available
basic elements of an FPGA. A metric with no label is shown by its key. Integers
are shown whole and other numbers to four significant places.

## Worst paths {#paths}

For a nextpnr run, the table lists the paths its report names, worst first:
the rank, the clock, where the path starts and ends, its delay in nanoseconds
and how it [maps to your RTL](#mapping). Open a path for a dialog with each
segment of the path and the mapping of each end. A LibreLane run's paths are not
listed yet: the panel says so, and its worst slack and its counts of paths that
miss are under **Metrics**.

A run ingested without its netlists lists its paths and says "This run holds no
synthesised netlist, so its paths are not mapped to the RTL."

## Mapping to your RTL and the fidelity labels {#mapping}

Synthesis and place and route restructure logic, rename cells and merge them, so
a timing path is never tied to an exact line of your source. SimCrux maps each
end of a path as near as the netlist allows, and **says how near**. Each end
carries one of four labels, and a path is labelled by its weaker end:

| Label | What it says | Shown as |
|---|---|---|
| **Register** | The end is a register your RTL names. | "register `sum_q`" |
| **Statement** | The end is the statement that assigns a register, found through the netlist's source attributes. | "statement `top.v:12`", or "statement `top.v:12`, assigning `sum_q`" |
| **Block** | Only the block that contains it is known. | "block `top.v:9`" |
| **Unmapped** | No source location survives synthesis for this cell. | "no source location survives synthesis for this cell" |

An unmapped end is never given a place it was not found in. It is shown beside
its nearest mapped neighbour, "unmapped; nearest mapped: `<mapping>`", so you
can see where on the path the trail goes cold. A path labelled **Statement** is
not a **Register**, and SimCrux never upgrades one label to another.

The mapping reads the netlist Yosys wrote for the run: the entry's
[`netlist:`](projects-and-simulators.md#flow-netlist) file, else `synth.json`,
else the run's one Yosys netlist, and the placed netlist `post.json`. Register
names are rooted at the entry's `top` when it names one.

## Cross-probe from a path {#cross-probe}

Every send below is free in every tier.

- Move onto a path and press ++cmd+shift+enter++ / ++ctrl+shift+enter++
  (**Cross-probe Selection**) while Flow Runs is shown, or right-click the row
  (++shift+f10++ or the Menu key on the current row) and choose **Cross-probe to**.
  The target gets the one thing its kind uses: the mapped endpoint register as a
  signal for [WaveCrux](https://docs.wavecrux.app/automation-and-collaboration#cxp) and
  [NetCrux](https://docs.netcrux.app/integrations/cxp#formal-flow), a
  statement as a source for [LintCrux](https://docs.lintcrux.app/integrations), or the whole path
  as an opaque id when nothing else is known.
- With **Broadcast selection automatically** on, every send also announces the
  whole path to the other tools: its start and end registers and its statements,
  with the mapping label **as mapped**, never upgraded. From NetCrux 1.2 a
  NetCrux window highlights both registers and shows the path in its Inspector
  with its label.
- **Open statement in editor** opens the endpoint's first statement at its line
  in your editor, after resolving its file inside the project directory with
  symbolic links resolved. A file outside the project is named in a toast and
  never opened.
- **Show timing paths through this register.** When NetCrux sends a register
  that names its design, Flow Runs shows its **Worst paths**, filtered to the
  paths that start or end there, under "Paths that start or end at `<register>`"
  with **Show all paths** above the table. When none does, it says so.
- A peer can also ask for the run itself. SimCrux answers with the run it holds
  for that design, brings the project's tab forward and selects the run. A run
  the peer names is opened only when it is one of the project's own runs; any
  other is ignored.

## Keyboard and screen readers {#keyboard}

Each table is one Tab stop. The arrow keys, ++home++, ++end++, ++page-up++ and
++page-down++ move the current row, which is spoken as one sentence, for example
"Path 1, clock clk, from src_a to sum_q, 9.600 nanoseconds, mapping Register".
++enter++ or ++space++ opens the row, and a click selects and a second click
opens it. Units are spoken in full.

## Pro {#pro}

<span class="tier tier-pro">Pro</span> Flow Metric Trends, Compare Flow Runs, the
PPA Dashboard, the Design-Space Sweep and the flow baseline read these same runs.
A run read by a reader that is not verified is marked as such wherever those
screens show it, including on a trend point. See
[Implementation flow](flow.md#pro).

## NetCrux slack overlay {#netcrux}

<span class="tier tier-pro">Pro</span> NetCrux can colour the registers of the
open design by the slack a nextpnr run reports. See
[the slack overlay](https://docs.netcrux.app/slack-overlay).
