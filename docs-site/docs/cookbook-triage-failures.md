# Triage failures & open the waveform

A run finished red. This recipe walks from a dashboard full of failures to the
signal that broke a real test — filtering to failures, separating flaky from
real, and dropping into WaveCrux with the waveform loaded.

| | |
|---|---|
| **Goal** | Triage a failing run: isolate real failures, get a waveform, and trace the bug. |
| **Time** | About 10 minutes |
| **Tier** | Open Core. The trend chart in step 2 is <span class="tier tier-pro">Pro</span>. |
| **You will use** | [Filter chips](results-dashboard.md#filtering), the [trend chart](trends-and-flaky.md#trends), [Re-run with waveform](waveforms-and-debug.md#rerun), and [Debug in WaveCrux](waveforms-and-debug.md#debug). |

## Steps {#steps}

1. **Filter to failures.** Click the **Failures** preset (fail, timeout and
   unknown). The table now shows only what went wrong. Click the **Suite**
   column header to see whether the damage is concentrated in one area.

2. **Tell flaky from real.** Select a failure and look at **Recent runs** in the
   Details panel — the last 10 results. A test that has been flipping green and
   red is likely flaky; one that was solid green until this run is a real
   regression — chase it first. With <span class="tier tier-pro">Pro</span>,
   right-click the row → **Show Trend Chart** for its full history, and look for
   a **FLAKY** chip on the row.

3. **Get a waveform.** If the Details panel shows a **Waveform** path, you have a
   dump. If not, check that the testbench calls `$dumpfile` / `$dumpvars`, then
   click **Re-run with waveform** (or **Re-run Selected Test**,
   ++cmd+shift+r++ / ++ctrl+shift+r++, when the test already uses
   `capture: on_failure`).

4. **Read the failing log.** Click **Open full log** and search for the assertion
   or error that marked the test failed. Note the simulation time it fired — you
   will navigate to it in the waveform.

5. **Open it in WaveCrux.** With WaveCrux running, click **Debug in WaveCrux**.
   WaveCrux opens the dump with the suggested signals. Jump to the failure time
   from the log and trace the bad value back to its driver.

6. **Open the testbench source.** Back in SimCrux, **Open testbench source**
   opens the test's testbench in your editor (**Settings → Editors**) so you can
   correlate the waveform with the stimulus that produced it.

!!! tip "Re-run only what failed"
    After a fix, **Re-run failures only** <span class="tier tier-pro">Pro</span> on
    the toolbar re-runs just the failing set instead of the whole project — the
    fastest confirm loop.

## Where to go next {#next}

If step 2 kept turning up flaky tests, the
[flaky-test recipe](cookbook-flaky-tests.md) shows how to find them
systematically. The full waveform workflow is on
[Waveforms & debug](waveforms-and-debug.md).

[← Previous recipe: Run your first regression](cookbook-first-regression.md) · [Next recipe: Hunt down flaky tests →](cookbook-flaky-tests.md)
