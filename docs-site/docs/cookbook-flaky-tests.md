# Hunt down flaky tests <span class="tier tier-pro">Pro</span>

A flaky test — one that passes most of the time and fails occasionally for no
code change — poisons a regression: every red run might be real or might be
noise. This recipe finds your flaky tests, confirms what they are, and pins a
failure down to a reproducible seed.

| | |
|---|---|
| **Goal** | Identify flaky tests, understand their failure pattern, and reproduce a failure deterministically. |
| **Time** | About 5 minutes |
| **Tier** | <span class="tier tier-pro">Pro</span> — flaky detection is a Pro feature. |
| **You will use** | The [Flaky Tests panel](trends-and-flaky.md#flaky), the [trend chart](trends-and-flaky.md#trends), and [Re-run with seed N](trends-and-flaky.md#sweeps). |

## Before you start {#before}

Flakiness is computed over history, so SimCrux needs several runs of the project
to score it — it looks at each test's last 50 runs. If you have only just started
running this project, let a few regressions accumulate first.

## Steps {#steps}

1. **Open the Flaky Tests panel.** Choose **Tools → Show Flaky Tests…**, or find
   it in the command palette (++cmd+shift+p++ / ++ctrl+shift+p++). Tests are
   ranked by **Score** — the recency-weighted share of recent runs that failed.

2. **Confirm it is actually flaky.** Expand a high-scoring test to see its
   **Pass / Fail** counts and **Flips**, then right-click its row in the results
   table → **Show Trend Chart**. An intermittent green/red pattern with no
   correlating code change is flakiness; a clean break from green to red on a
   specific date is a real regression that belongs in
   [triage](cookbook-triage-failures.md), not here.

3. **Find the failing seeds.** If the test is a [seed sweep](cookbook-seed-sweep.md),
   click the **Failures** preset and type `+seed=` into **Filter by test
   name…**: each row's test id carries its seed. A single consistently-failing
   seed is a reproducible bug hiding behind a mostly-green test.

4. **Reproduce one seed.** Right-click a failing instance → **Re-run with seed
   N** to run exactly that seed again. A failure that reproduces is a real bug
   you can debug; one that does not is genuine non-determinism.

5. **Read the row chips.** Back in the dashboard, flaky tests carry a **FLAKY**,
   **HIGHLY FLAKY** or **BROKEN** chip at the right end of their row, so you read
   every future result in context — a red flaky test is a known quantity, not a
   fire drill.

!!! tip "Retry flaky failures automatically"
    Turn on **Retry failed tests automatically** in
    **Settings → Flaky Test Detection** and choose **Retry attempts**: a failing
    test already scored flaky is re-run in the same regression before it counts
    as a failure. See [Flaky-test detection](trends-and-flaky.md#flaky).

## Where to go next {#next}

When a flaky test turns out to fail on specific seeds, reach for the
[seed-sweep recipe](cookbook-seed-sweep.md) to pin it down. The full feature
reference is on [Trends, flaky tests & seeds](trends-and-flaky.md).

[← Previous recipe: Triage failures & open the waveform](cookbook-triage-failures.md) · [Next recipe: Run a seed sweep →](cookbook-seed-sweep.md)
