# Run a seed sweep <span class="tier tier-pro">Pro</span>

Constrained-random verification finds bugs by running the same testbench across
many seeds. This recipe turns a single test into a 100-seed sweep with one config
line, finds the seeds that fail, reproduces one deterministically, and reads the
heatmap that shows whether a failure is one bad seed or a systematic edge.

| | |
|---|---|
| **Goal** | Sweep a test over many seeds, isolate the failing seeds, and reproduce one deterministically. |
| **Time** | About 10 minutes |
| **Tier** | <span class="tier tier-pro">Pro</span> — seed sweeps are a Pro feature. |
| **You will use** | `seeds:` in [simcrux.yaml](trends-and-flaky.md#sweeps), [test-name filtering](results-dashboard.md#search), Re-run with seed N, and the [Seed Failure Heatmap](trends-and-flaky.md#sweeps). |

## Before you start {#before}

Your testbench must consume the seed SimCrux passes it — the `+seed=N` plusarg
for Icarus, `+verilator+seed+N` for Verilator, or `RANDOM_SEED` for cocotb. A
test that ignores its seed will report identical results across the sweep. GHDL
records the seed but does not pass it to the testbench.

## Steps {#steps}

1. **Add a seed range to the test.** Add `seeds:` to the test in
   `simcrux.yaml` — a list, with the range in quotes:

    ```yaml
    tests:
      - name: crc_random
        top: crc_tb
        sources: [tb/crc_tb.sv]
        seeds: ["1..100"]
    ```

    SimCrux expands this into 100 tests, with ids `crc/crc_random+seed=1` …
    `+seed=100`. Add list-valued `parameters:` to sweep parameters and seeds
    together.

2. **Run the sweep.** Press ++f5++. SimCrux runs the 100 instances in parallel;
   each appears as its own row.

3. **Find the failing seeds.** Click the **Failures** preset. To see which seeds
   failed, type `+seed=` into **Filter by test name…** — the seed is part of each
   test id — or open the heatmap in the next step.

4. **Read the Seed Failure Heatmap.** Click **Show Seed Failure Heatmap…** on the
   toolbar (or **Tools → Show Seed Failure Heatmap**) and pick the run and the
   parameterized test. A single isolated red cell is one unlucky seed; a band or
   cluster of red points at a systematic edge in the design or testbench. The
   summary names the worst seed.

5. **Reproduce one seed deterministically.** Right-click a failing instance →
   **Re-run with seed N** to run exactly that seed again. Then click
   **Debug in WaveCrux** on the result to trace it — a fully reproducible failure
   to debug against.

!!! tip "Keep the sweep cheap"
    If 100 dumps are too many, set `capture: on_demand` for the sweep and click
    **Re-run with waveform** on the one seed you are chasing.

!!! tip "Sweeps in CI"
    `simcrux --ci` expands the sweep at the tier of the license you give it —
    `--license-file`, `SIMCRUX_LICENSE_FILE` or your policy file. See
    [License tier in CI](cli.md#license-in-ci).

!!! note "Sweeps are Pro"
    The sweep is a Pro feature: an
    open-core build runs the test once and shows a warning banner naming the
    sweep. See [Parameterization & seed sweeps](trends-and-flaky.md#sweeps).

## Where to go next {#next}

The full reference for sweeps, parameterization and the heatmap is on
[Trends, flaky tests & seeds](trends-and-flaky.md#sweeps). To gate CI on new
failures from a sweep, see [Baselines, CI & exports](baselines-ci-exports.md).

[← Previous recipe: Hunt down flaky tests](cookbook-flaky-tests.md) · [Back to the Cookbook →](cookbook.md)
