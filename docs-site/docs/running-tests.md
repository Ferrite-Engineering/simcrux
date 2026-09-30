# Running tests

This page covers actually executing a regression: the run controls, how SimCrux
parallelizes work while respecting resource constraints, per-test timeouts, and
how results and logs come back as the run progresses.

## Run, cancel, re-run {#controls}

| Action | Where | What it does |
|---|---|---|
| **Run Regression** | ++f5++, the toolbar run button, **Tools** | Re-reads `simcrux.yaml` and runs every test in the project. |
| **Cancel Regression** | ++esc++, the same toolbar button while running, **Tools** | Stops starting new tests and terminates the running ones. Tests that were running end **Cancelled**; tests that had not started produce no result. |
| **Re-run Selected Test** | ++cmd+shift+r++ / ++ctrl+shift+r++, toolbar, **Tools** | Re-runs only the selected test. |
| **Re-run** / **Re-run with waveform** | Details panel | Re-runs the selected test; the second forces `waveform.capture` to `always`. |
| **Re-run failures only** <span class="tier tier-pro">Pro</span> | Toolbar | Re-runs every test that ended **fail**, **timeout** or **unknown** in the latest run. |
| **Re-run with seed N** / **Re-run all in this parameter group** <span class="tier tier-pro">Pro</span> | Results-row menu | Re-runs one seed, or every instance of a sweep. |

Run and Re-run are greyed out while a regression is running; Cancel is greyed
out when none is.

**Run Regression always runs the whole project.** The dashboard filters change
what the table shows, not what a run executes; to run a subset from the command
line, use `--filter` with [`--ci`](cli.md#arguments).
**Re-run with waveform** is the workhorse for the failure-to-waveform loop — see
[Waveforms & debug](waveforms-and-debug.md).

**Re-run** and **Re-run with waveform** in the Details panel run only the
selected test, like **Re-run Selected Test**; the table then shows just that
result, and the next **Run Regression** runs the whole project again.

!!! tip "Config is re-read on every Run"
    Each ++f5++ re-parses `simcrux.yaml` from disk before running, so an edit you
    made since opening the tab — a changed `timeout:`, an added or removed test —
    takes effect on the next run with no app relaunch. If the edited YAML no
    longer loads, the error appears in the tab instead of the run silently
    proceeding on the stale config.

Opening a config does not start a run unless you turn on **Settings → General →
Run the regression when a config is opened** (off by default).

## Parallel execution & concurrency {#parallel}

SimCrux runs tests concurrently with proper output isolation — each test gets
its own working directory, and its `stdout`/`stderr` are captured separately,
so parallel logs never interleave. A run started from the app uses 4 parallel
slots; concurrency is not a `simcrux.yaml` key. Set it on the command line in
`--ci` mode:

```bash
# Run at most 8 tests at once
simcrux simcrux.yaml --ci --max-parallel 8
```

A simulator's process tree is terminated as a whole — including cocotb's
`make → python → simulator` grandchildren — so cancelling or timing out a test
does not leave orphans behind.

## Per-test timeouts {#timeouts}

Give a test a wall-clock budget with `timeout:` at the `defaults:`, suite or
test level — a bare number of seconds, or a number with `ms`, `s`, `m` or `h`.
A test with no timeout anywhere gets 300 seconds. When the budget expires,
SimCrux sends `SIGTERM`, waits 5 seconds, then `SIGKILL`, and marks the test
**timeout** — distinct from a fail. A runaway test cannot stall the rest of the
suite.

```yaml
tests:
  - name: long_sim
    top: long_tb
    sources: [tb/long_tb.sv]
    timeout: 5m
```

`defaults.timeout` carries into [included files](projects-and-simulators.md#includes)
like the other defaults; an included file's own `defaults.timeout` wins.

## Resource locks {#locks}

Some tests cannot run at the same time — they bind the same TCP port, touch a
shared file, or hold a floating simulator license. Name a lock with
`resources:` and SimCrux never runs two tests holding the same name
concurrently, while still parallelizing everything else. Suite-level and
test-level `resources:` are merged.

```yaml
tests:
  - name: net_a
    top: tb_net_a
    resources: [tcp_5000]
  - name: net_b
    top: tb_net_b
    resources: [tcp_5000]   # never runs concurrently with net_a
```

## Results & the live log {#streaming}

Results appear in the dashboard as each test finishes — you do not wait for the
whole run to see the first failures. Select a test and the **Log** panel
(++cmd+3++ / ++ctrl+3++) shows its captured output, updating live while the test
is still running. The status bar's **Running** count and a busy indicator show
the run in progress.

`simcrux --ci` additionally streams one JSON line per finished test to
`results.ndjson` — see [Streaming results](baselines-ci-exports.md#streaming-results).

## File watching & auto-reload {#watching}

SimCrux watches the source files the loaded tests declare. When one changes,
the behaviour follows **Settings → General → Auto-reload**:

| Mode | Behaviour on change |
|---|---|
| **Prompt** (default) | A **Sources changed** notice asks whether to re-run the suite; **Re-run now** does. |
| **Auto** | The regression re-runs immediately, reloading `simcrux.yaml` first. |
| **Off** | Nothing happens; run by hand. |

With two tabs open on the same project, only one of them reacts, so one edit
triggers one re-run.

!!! tip "Edit-run-edit loop"
    With **Auto** on, the inner loop is tight: edit the RTL, read the result as
    it arrives, and on a failure click **Re-run with waveform** and then
    **Debug in WaveCrux**.
