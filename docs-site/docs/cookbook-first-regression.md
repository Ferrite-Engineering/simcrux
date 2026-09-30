# Run your first regression

From zero to a results dashboard with a test you can click into. This recipe
writes a minimal `simcrux.yaml`, runs it, reads the dashboard, and opens a
failure's log and waveform.

| | |
|---|---|
| **Goal** | Run a small regression and triage a failure down to its log and waveform. |
| **Time** | About 10 minutes |
| **Tier** | Open Core throughout. |
| **You will use** | [`simcrux.yaml`](projects-and-simulators.md), [Run Regression](running-tests.md), the [dashboard](results-dashboard.md), the [Log Viewer](results-dashboard.md#inspector), and [Debug in WaveCrux](waveforms-and-debug.md). |

## Before you start {#before}

You need at least one simulator on your `PATH` — Icarus is the quickest to get
going (see [Supported simulators](getting-started.md#simulators)). This recipe
uses Icarus; swap the `simulator:` value for another. To see the waveform step,
have WaveCrux installed too.

## Steps {#steps}

1. **Write a minimal config.** Create `simcrux.yaml` at the root of your
   project:

    ```yaml
    version: '1'

    defaults:
      simulator: icarus
      timeout: 30s
      pass_fail:
        type: string_match
        pass_string: TEST PASSED
        fail_string: TEST FAILED
      waveform:
        capture: on_failure

    suites:
      smoke:
        tests:
          - name: alu_basic
            top: alu_tb
            sources: [rtl/alu.v, tb/alu_tb.v]
    ```

    The testbench should print `TEST PASSED` or `TEST FAILED`, and call
    `$dumpfile` / `$dumpvars` so there is a waveform to open.

2. **Open the project.** Click **Open Config…** on the start screen (or
   **File → Open Config…**, ++cmd+o++ / ++ctrl+o++) and pick the `simcrux.yaml`.
   The test appears in the **Tests** panel. If the file does not load, the tab
   shows the error with its line number — fix it before running.

3. **Run the regression.** Press ++f5++. The result appears in the table when
   the test finishes, and the status bar at the bottom tracks the totals.

4. **Read the dashboard.** The status icon tells you pass from fail. Click the
   row to fill the **Details** panel with the test's details and the tail of its
   log.

5. **Open the full log on a failure.** If the test failed, click **Open full
   log** in the Details panel. Type `TEST FAILED` into **Search log…** to jump
   to the line your `fail_string` matched.

6. **Debug it in WaveCrux.** With `capture: on_failure`, the failing test kept
   its dump — the Details panel shows its **Waveform** path. Start WaveCrux, then
   click **Debug in WaveCrux** to open the dump there. (No dump? Click
   **Re-run with waveform** first, and check the testbench dumps.)

!!! tip "Keep the config short early"
    As the suite grows, lift shared settings into `defaults:`, shared sources
    onto the suite, and split per-block configs with `includes:` — see
    [Defaults & inheritance](projects-and-simulators.md#inheritance).

## Where to go next {#next}

[Triage failures & open the waveform](cookbook-triage-failures.md) goes deeper
on the failure workflow, and [Pass/fail detection](pass-fail-detection.md)
covers detectors beyond a simple string match.

[← All recipes](cookbook.md) · [Next recipe: Triage failures & open the waveform →](cookbook-triage-failures.md)
