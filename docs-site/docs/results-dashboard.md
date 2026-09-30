# The results dashboard

The dashboard is where you live during a regression. This page is the full
reference for the results table, its filters, the presets, the status bar, the
heatmap view, and the Details panel and Log Viewer you drill into a failure
with.

## The table {#table}

The table is virtualized — only the rows in view are drawn, so a 10,000-row
regression scrolls as smoothly as a 50-row one. Each row is one finished test,
or one expanded instance of a seed or parameter sweep; rows appear as tests
finish. Columns:

| Column | Contents |
|---|---|
| *(check box)* | Adds the row to the multi-selection. |
| Status | An icon for **Pass**, **Fail**, **Timeout**, **Cancelled**, **Unknown** and the other [statuses](pass-fail-detection.md#statuses). Hover for the status name. |
| Suite | The suite the test belongs to. |
| Test | The test name. Instances of a sweep share their template's name; their seed and parameter values are in the test id (`alu/random+WIDTH=8+seed=1`), which the name filter matches. |
| Simulator | The simulator id: `icarus`, `verilator`, `ghdl`, `cocotb`, … |
| Duration | Wall-clock runtime. |
| Started | When the test started, as `HH:MM:SS`. |

With <span class="tier tier-pro">Pro</span>, a chip at the right end of the row
marks tests classified **FLAKY**, **HIGHLY FLAKY** or **BROKEN** — see
[Flaky-test detection](trends-and-flaky.md#flaky).

## Sorting {#sorting}

Click any column header to sort by it; click again to reverse. Sort by
**Duration** to find the slowest tests, by **Status** to group failures
together, or by **Started** to read the run in execution order.

## Filtering {#filtering}

The filter area above the table narrows what is shown without changing the
underlying results — or what the next run executes:

- **Presets** — **Failures** (fail, timeout and unknown) and **Passing** (pass
  and vacuous) apply a status filter in one click.
- **Filter by test name…** — see [Test-name search](#search).
- **Status** chips — one chip per status; select several to show any of them.
- **Suite** chips — restrict to one or more suites.
- **Simulator** chips — restrict to one or more simulators.

**Clear filters** resets everything at once. When the chips outgrow half the
pane, the filter area scrolls so the table keeps the rest.

## Test-name search {#search}

Two ways to find a test:

- **Filter by test name…** above the table narrows the rows to test ids
  containing the text, ignoring case. It is a plain substring match — no globs
  or regular expressions — and it combines with the chips, so you can look at
  "failed Verilator tests in the `dma` suite whose id contains `burst`".
- **Search Tests** (++cmd+f++ / ++ctrl+f++, or **Search → Search…**) searches the
  loaded project's test names, suite names and simulator ids. Move through the
  hits with ++arrow-up++ / ++arrow-down++ and press ++enter++ to select one.

## Presets {#presets}

The two built-in presets — **Failures** and **Passing** — sit above the filter
field; the one matching the current filter is highlighted. You cannot save your
own presets yet.

## The status summary bar {#summary}

The bar at the bottom of the window always reflects the whole run, ignoring
filters: the config file name, then **Total**, **Passed**, **Failed** and
**Running**, followed by **Skipped**, **Timed out** and **Error** (unknown) when
they are non-zero. A busy indicator shows while the regression runs.

## The Results Grid heatmap {#heatmap}

Switch the control above the table from **Table** to **Heatmap** for a grid
where each cell is a test, colored by status. For a few-thousand-test regression
it shows the *shape* of the result — a red block in one suite, a run of timeouts
— that a scrolling table hides. The heatmap shows the same filtered set as the
table. Hover a cell for the test and its status; click it to select the test.
Cell colors follow the active color theme.

## The Details panel & Log Viewer {#inspector}

Selecting a row fills the **Details** panel (right; toggle with
++cmd+2++ / ++ctrl+2++): the actions **Open full log**, **Re-run**, **Re-run with
waveform**, **Open testbench source** and **Debug in WaveCrux**; the details
**Suite**, **Simulator**, **Duration**, **Exit code**, **Started**,
**Working dir** and **Waveform**; the **Recent log**; and **Recent runs**, a
sparkline of the test's last 10 results.

**Open full log** opens the Log Viewer over the captured output: **Search log…**
with next / previous match and a match counter, a **Line** field with **Go**,
and **Copy all to clipboard**. Use it to find the exact line a detector matched.
The same output streams into the **Log** panel at the bottom while a test runs.

**Re-run** and **Re-run with waveform** run only the selected test, as
**Re-run Selected Test** (++cmd+shift+r++ / ++ctrl+shift+r++) does.

## Keyboard navigation {#keyboard}

Each results row is one ++tab++ stop — its check box. With a row focused,
++enter++ opens the test in the Details panel (what a click on the row does) and
++space++ toggles the check box. The table does not move its selection with the
arrow keys. You can also select a test in the **Tests** panel (++tab++ to a
test, then ++enter++) or with **Search Tests** (++cmd+f++ / ++ctrl+f++); the
Details panel follows the selection. ++cmd+shift+r++ / ++ctrl+shift+r++ re-runs
whatever is selected.

!!! note "Next"
    A failing row with a captured waveform leads straight to
    [Waveforms & debug](waveforms-and-debug.md); the trend charts behind the
    Recent runs sparkline are on [Trends, flaky tests & seeds](trends-and-flaky.md).
