# The interface

SimCrux is built around one screen: a results dashboard you run regressions
into and click your way around. This tour names every region — the toolbar,
the results table, the heatmap, the Details panel, the Log Viewer — and the menu
bar, command palette, settings and diagnostics that sit behind them.

## Workspace, tabs, and split panes {#workspace}

Each project opens in a **tab**; a window can hold several. **View → Split Pane
Right** (++cmd+backslash++ / ++ctrl+backslash++) splits the workspace into two
panes side by side; drag a tab onto the other pane to move it there. Close the
active tab with ++cmd+w++ / ++ctrl+w++; **Close Project**
(++cmd+shift+w++ / ++ctrl+shift+w++) closes the same tab under its project
label. **File → Close All Tabs** closes every tab after a confirmation.

Around the results table, each tab has three docked panels that toggle
individually:

| Panel | Shortcut | What it holds |
|---|---|---|
| **Tests** (left) | ++cmd+1++ / ++ctrl+1++ | The suite/test tree for the open project, with each test's latest status. Click a test to select it. |
| **Details** (right) | ++cmd+2++ / ++ctrl+2++ | Details, recent log lines, run history and actions for the selected test. The **Cross-Probe** panel opens as a second tab here. |
| **Log** (bottom) | ++cmd+3++ / ++ctrl+3++ | The captured output of the selected test, updating live while it runs. |

A hidden panel leaves a slim strip along its window edge; click it to bring the
panel back. Resize a panel by dragging its edge, or from the keyboard: with focus
inside the panel, ++cmd+shift+arrow-right++ / ++ctrl+shift+arrow-right++ widens
the Tests panel, ++cmd+shift+arrow-left++ / ++ctrl+shift+arrow-left++ widens
Details, and ++cmd+shift+arrow-up++ / ++ctrl+shift+arrow-up++ grows the Log panel
(the opposite arrow shrinks each).

## The toolbar {#toolbar}

The toolbar runs full width across the top of the tab, directly under the tab
bar — the same layout as the other EDACrux apps. Buttons that do not apply
right now are greyed out; the overflow menu at the end holds every menu command.

| Button | Shortcut | Action |
|---|---|---|
| Open Config… | ++cmd+o++ / ++ctrl+o++ | Open a `simcrux.yaml` in a new tab. |
| Close Project | ++cmd+shift+w++ / ++ctrl+shift+w++ | Close the active tab. |
| Search… | ++cmd+f++ / ++ctrl+f++ | Open **Search Tests** — search by test, suite or simulator; ++enter++ selects the hit. |
| Cross-Probe Panel | ++cmd+shift+x++ / ++ctrl+shift+x++ | Show or hide the Cross-Probe panel. The badge counts connected peers. |
| Settings… | ++cmd+comma++ / ++ctrl+comma++ | Open Settings. |
| Import FuseSoC .core File… | ++cmd+i++ / ++ctrl+i++ | Convert a FuseSoC `.core` file and open the result. |
| Run Regression / Cancel Regression | ++f5++ / ++esc++ | One button that shows the run state: it runs when idle and cancels while a regression is running. |
| Re-run Selected Test | ++cmd+shift+r++ / ++ctrl+shift+r++ | Re-run only the selected test. |
| Re-run failures only <span class="tier tier-pro">Pro</span> | — | Re-run every failing test from the latest run. |
| Show Seed Failure Heatmap… <span class="tier tier-pro">Pro</span> | — | Open the per-seed pass/fail grid. |
| Compare to baseline <span class="tier tier-pro">Pro</span> | — | Open the **Regression Comparison** screen. |
| Compatibility / Formal proofs <span class="tier tier-pro">Pro</span> | — | RISC-V analysis screens; each appears only when the run holds rows of its kind. |

When a baseline is set, a **Baseline:** chip <span class="tier tier-pro">Pro</span>
follows the buttons.

## The results dashboard {#dashboard}

The results table is virtualized — it draws only the rows in view, so a
10,000-row regression scrolls as smoothly as a 50-row one. Each row is one test
(one expanded instance for a sweep). Columns: **Status**, **Suite**, **Test**,
**Simulator**, **Duration** and **Started**, with a check box on the left of
each row. Click a column header to sort by it. With Pro, a flakiness chip
appears at the right end of flaky rows.

Above the table sit the saved presets (**Failures**, **Passing**), the
**Filter by test name…** field, **Clear filters**, and chips for **Status**,
**Suite** and **Simulator**. Filters change what the table shows, not what a run
executes. The full reference is on
[The results dashboard](results-dashboard.md).

The **status bar** runs across the bottom of the window: the open file's name on
the left, then the run totals — **Total**, **Passed**, **Failed**,
**Running**, and **Skipped**, **Timed out** and **Error** when any occur. The
totals always cover the whole run, ignoring filters.

## The Results Grid heatmap {#grid}

Switch the segmented control above the table from **Table** to **Heatmap** for
a grid where each cell is one test, colored by status. It makes the shape of a
regression obvious at a glance — a cluster of red in one suite, a run of
timeouts — where a 5,000-row table would not. Hover a cell for the test name
and status; click it to select the test.

## The Details panel {#inspector}

The **Details** panel docks on the right and reflects the selected test:

- **Actions** — **Open full log**, **Re-run**, **Re-run with waveform**,
  **Open testbench source** (in your editor) and **Debug in WaveCrux**.
- **Details** — **Suite**, **Simulator**, **Duration**, **Exit code**,
  **Started**, **Working dir** and, when one was captured, **Waveform**.
- **Recent log** — the last 50 lines of output (change the count with
  **Settings → General → Log preview lines**).
- **Recent runs** — a sparkline of the test's last 10 results from the local
  SQLite history. <span class="tier tier-pro">Pro</span> adds full trend charts;
  see [Trends, flaky tests & seeds](trends-and-flaky.md).

**Re-run** and **Re-run with waveform** run only the selected test — the same
as **Re-run Selected Test** (++cmd+shift+r++ / ++ctrl+shift+r++), with
**Re-run with waveform** forcing `capture: always`.

## The Log Viewer {#log-viewer}

**Open full log** opens the Log Viewer over the test's captured
`stdout`/`stderr`: **Search log…** with next / previous match and a match
counter, a **Line** field with **Go** to jump to a line, and
**Copy all to clipboard**.

## Menu bar & command palette {#menus}

The menu bar carries **File**, **View**, **Search**, **Tools** and **Help**; on
macOS the **SimCrux** application menu holds **About SimCrux**,
**Check for Updates**, **Settings…** and **Quit SimCrux**. On Windows and Linux,
Settings and Exit sit at the bottom of the File menu. Actions that need a paid
tier carry a tier suffix in the menu.

Every command is also in the **command palette**
(++cmd+shift+p++ / ++ctrl+shift+p++) — type to find it, and see its shortcut and
any tier badge inline. The palette lists only commands that can run right now.

## Settings {#settings}

Open Settings with ++cmd+comma++ / ++ctrl+comma++. The sections:

| Section | What it controls |
|---|---|
| General | **Auto-reload** (Prompt / Auto / Off), **Log preview lines**, **Run the regression when a config is opened**, **Automatically check for updates**, and in release builds **Enable diagnostics** (turns on **Tab Diagnostics…**; debug builds always have it). |
| Appearance | **Language**, color theme **Presets**, **Color overrides** and **Theme packs**. See [Appearance & themes](appearance-and-themes.md). |
| Privacy | **Send anonymous usage statistics** and the **Installation ID**. Shown only on builds that can send usage statistics: the 0.8.x beta builds collect nothing, so the section is absent from them and appears from 1.0. See [Usage statistics](integrations/updates-and-feedback.md#usage-statistics). |
| Simulators | A **Binary path** per simulator id. |
| Editors | The **Editor command** for *Open testbench source*, with VS Code, Sublime Text, Vim, Emacs and Custom presets. |
| CXP Cross-Probe | **Enable CXP server**, **CXP port** (default `54325`), **Request attention on cross-probe**, **Broadcast selection automatically**, and the CXP status. |
| Detectors | The reusable pass/fail detector library — add, edit, delete. |
| Keyboard Shortcuts | View and rebind every shortcut. |

The SimCrux download adds **License**, and the paid-tier sections **Flaky Test
Detection**, **Test Execution — Parameterization**, **Custom Driver Plugins**,
**PR Annotations**, **Trend Retention** <span class="tier tier-pro">Pro</span> and
**Team Database** <span class="tier tier-enterprise">Enterprise</span>.

## Diagnostics {#diagnostics}

**Tools → App Diagnostics…** (++cmd+shift+m++ / ++ctrl+shift+m++) shows a
plain-text report — the same session state the issue reporter attaches (counts,
simulator ids and versions, run state; never a path or design name) — plus the
trend store's size and schema history and a check of the RISC-V toolchain. Its
copy button is **Copy Full Diagnostics Report**. If the local trend database was damaged, this is where SimCrux offers
to rebuild it.

**Tools → Tab Diagnostics…** (++cmd+shift+i++ / ++ctrl+shift+i++) opens a drawer
for the active tab: **Config info** (path, schema version, suite and test
counts, last run wall time), **Simulator backend** (the registered drivers) and
**Scheduler state** (total tests, completed, finished), with **Copy tab
diagnostics report**.

In release builds **Tab Diagnostics…** is greyed out until you turn on
**Settings → General → Enable diagnostics**.

The **Cross-Probe** panel lists connected suite peers and recent cross-probe
activity — see [Cross-probe & the suite](integrations.md#peers). The
**About SimCrux** box shows the version, build and platform, and offers **Visit
Website**, **Documentation**, **Submit Issue…**, **Check for Updates**,
**Privacy Policy**, **Terms of Service** and **Copy Version Info**.
