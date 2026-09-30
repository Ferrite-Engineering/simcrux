# Trends, flaky tests & seeds <span class="tier tier-pro">Pro</span>

SimCrux persists every run, so it can tell you more than "this run passed." It
charts a test's history, flags the ones that pass intermittently, and runs
constrained-random seed sweeps as a first-class config. This page is the Pro
track; the persistent history and the last-10 sparkline behind it are open
core.

## History: Open Core vs Pro {#history}

Open core keeps a persistent SQLite history of every run started from the app
(`trends.db` in SimCrux's application-support folder) and surfaces:

- **Recent runs** — a sparkline of each test's last 10 results in the Details
  panel.
- A **run-delta strip** under the results table: counters for new failures,
  fixed tests, new tests and other changes since the previous run. It is hidden
  when nothing changed.

Old history is pruned after every run by the default retention policy: data
older than 30 days, beyond 50,000 data points, or beyond the 10 most recent
runs' waveforms.

<span class="tier tier-pro">Pro</span> keeps a separate history per project
(`.simcrux/trends.db` inside the project directory), lets you configure
retention, and adds the charts, alerts and flakiness scoring below.

## Trend tracking <span class="tier tier-pro">Pro</span> {#trends}

Open the charts from **Tools**, the command palette, or a results row's
right-click menu (**Show Trend Chart**).

- **Tools → Show Test Trend Chart…** — a **Test Trend** for one test id over a
  **Time window** (last 7, 30 or 90 days, or last year), with the run count,
  pass rate, mean runtime, and whether runtime is trending slower or faster.
- **Tools → Show Suite Trend Chart…** — a **Suite Trend** with total runs, pass
  rate and days with failures.
- **Tools → Show Calendar Heatmap…** — a day-by-day grid of pass and fail
  counts, for **All tests**, **Per suite** or **Per test**, so a bad week is
  obvious.
- **Regression alerts** — a banner above the results table when a test's recent
  runtime is at least 25 % slower than its prior baseline (mean of the last 3
  runs against the 10 before), when a test that passed its previous 5 runs has
  failed the last 3, or when a test flip-flopped at least 4 times in its last
  10 runs. Each alert offers **Show Trend** and **Dismiss**.
- **Trend retention** — **Settings → Trend Retention** (also
  **Tools → Configure Trend Retention…**) sets **Maximum age (days)**,
  **Maximum data points**, **Waveform runs to keep** and the **Prune strategy**
  (**Oldest first** or **Sparse history**), with **Apply now**. An organization
  can fix these thresholds centrally — see
  [Result retention](administration.md#retention).

## Flaky-test detection <span class="tier tier-pro">Pro</span> {#flaky}

A test that passes eight times out of ten is flaky, not broken — and treating it
as a hard failure wastes time. SimCrux scores every test over its last 50 runs:
the **score** is the share of those runs that failed, weighted towards recent
runs, and the number of pass ↔ fail **flips** separates noise from a clean
break.

| Classification | When | Row chip |
|---|---|---|
| Stable | No failures in the window | — |
| Intermittent | Failures and at least one flip, score below 0.05 | — |
| Flaky | Score 0.05 or higher | **FLAKY** |
| Highly flaky | Score 0.40 or higher | **HIGHLY FLAKY** |
| Consistently failing | Every run in the window failed | **BROKEN** |

- **Flaky Tests panel** — **Tools → Show Flaky Tests…** lists every scored test,
  highest score first; expand a row for its **Score**, **Pass / Fail** counts,
  **Flips**, **Last failure** and **Window**.
- **Row chips** — the chip at the right end of a results row, so you read a
  result in context.

1. **Open the Flaky Tests panel** from **Tools → Show Flaky Tests…** or the
   command palette. Tests are ranked by score.
2. **Inspect a flaky test's history.** Open its **Test Trend** (right-click the
   row → **Show Trend Chart**) to see the pass/fail pattern over time.
3. **Reproduce a failing seed.** If the test belongs to a seed sweep, right-click
   a failing instance → **Re-run with seed N**.

**Automatic retry** — **Settings → Flaky Test Detection** has a **Retry failed
tests automatically** switch (off by default) and a **Retry attempts** stepper
(0 to 5, default 3). With it on, a test scored flaky, intermittent or highly
flaky that fails is re-run up to that many more times in the same regression —
the first retry with the same seed, later ones with fresh seeds. A stable,
broken or unscored test is never retried. Both settings are remembered across
launches; `simcrux --ci` does not retry.

Flakiness needs history: let a few regressions accumulate before expecting
scores.

## Parameterization & seed sweeps <span class="tier tier-pro">Pro</span> {#sweeps}

Constrained-random verification means running the same testbench across many
seeds. With SimCrux that is one config line, not a Makefile loop. Declare
`seeds:` and/or list-valued `parameters:` on a test and SimCrux expands them
into one concrete test — one results row — per combination.

```yaml
tests:
  - name: crc_random
    top: crc_tb
    sources: [tb/crc_tb.sv]
    seeds: ["1..100"]        # or [1, 2, 3]
    parameters:
      WIDTH: ['8', '16', '32']   # a list value is a sweep axis
```

This expands into 300 tests with ids such as
`crc/crc_random+WIDTH=8+seed=1`. Seeds expand first, then parameter axes in
declaration order. `seeds:` must be a list — a range goes in quotes inside it
(`["1..100"]`). A single-element list behaves like a scalar, and one entry may
expand to at most 10,000 tests by default (**Settings → Test Execution —
Parameterization → Max expansion size** raises it for project loads in the
app; `--ci` always uses the default); a larger product fails to load.

The seed reaches the simulator as `+seed=N` for Icarus, `+verilator+seed+N` for
Verilator, and `RANDOM_SEED` / `COCOTB_RANDOM_SEED` in the environment for
cocotb; your testbench must read it. GHDL is report-only: the seed is recorded,
not injected. `seed: N` pins one seed without expanding and works in every tier;
a test with no seed gets a clock-derived one, recorded on the result so the run
can be reproduced.

`parameters:` values form the test id and drive the sweep, but are **not**
passed to Icarus, Verilator or GHDL — use `defines:` where elaboration needs the
value.

- Instances share their template's name in the **Test** column; the seed and
  parameter values are in the test id, which **Filter by test name…** matches
  (for example `+seed=17`).
- Right-click an instance for **Re-run with seed N** or **Re-run all in this
  parameter group**.
- **Show Seed Failure Heatmap…** (toolbar, or **Tools → Show Seed Failure
  Heatmap**) plots pass/fail per **Seed** against each **Parameter combination**
  for a chosen **Run** and **Parameterized test**, with the fail rate, the worst
  seed and the worst combination — so you can tell one bad seed from a
  systematic edge.

In CI, `simcrux --ci` has no access to the license stored in the app. It
expands sweeps at the tier of the license it is given: `--license-file <path>`,
else the file named by `SIMCRUX_LICENSE_FILE`, else the license in your
organization's policy file — see [Command line & CI](cli.md#license-in-ci).

!!! note "Sweeps need Pro from 1.0"
    Through the 0.8.x public beta every build expands sweeps, whatever license
    it holds. From 1.0 an open-core build runs a `seeds:` list or a list-valued
    parameter once and says so: the app shows a **This project loaded with 1
    warning** banner above the results table, naming the file and line of each
    sweep it did not expand (**Dismiss** hides it until a load brings different
    warnings), and `simcrux --ci` prints the same advisory as a `warning:` line
    on stderr. In Pro, the banner follows the warnings switch in
    **Settings > Test Execution — Parameterization**.

!!! note "Next"
    The [flaky-test](cookbook-flaky-tests.md) and
    [seed-sweep](cookbook-seed-sweep.md) recipes walk these features end to end.
    To gate CI on regressions, see [Baselines, CI & exports](baselines-ci-exports.md).
