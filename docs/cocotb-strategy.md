# Cocotb driver: Makefile-wrap vs. Python runner

> **Status:** SimCrux ships strategy A — wrap Cocotb's standard `Makefile.sim`. This document records why and what would trigger adding strategy B.

## Strategy A — Makefile wrap (current)

`CocotbDriver.execute` spawns:

```
make SIM=<sim> TOPLEVEL=<top> COCOTB_TOPLEVEL=<top> [TOPLEVEL_LANG=…] [MODULE=<m> COCOTB_TEST_MODULES=<m>]
```

inside the per-test working directory the scheduler allocates, with `SIM`, `RANDOM_SEED` and `COCOTB_RANDOM_SEED` also set in the environment. Both spellings of the toplevel, module and seed variables are passed because Cocotb 2.x renamed them and warns when only the old name is set, while 1.x knows only the old one — one argument list runs warning-free on 1.9, 2.0 and 2.1. The user's Makefile is the same one they run by hand outside SimCrux — typically a few `=` assignments followed by `include $(shell cocotb-config --makefiles)/Makefile.sim`.

How the pieces are chosen:

- `SIM` — the test's `parameters.sim`, else `simulators.cocotb.options.sim`, else `icarus`.
- `TOPLEVEL_LANG` — the test's `parameters.TOPLEVEL_LANG`, else derived from the dominant HDL language of the test's `sources:` (`verilog` or `vhdl`), else omitted so Cocotb's default applies.
- `MODULE` — only when the test sets `parameters.MODULE`.
- Cocotb 2.1's regression controls, only when asked for: `max_failures` → `COCOTB_MAX_FAILURES`, `random_order: true` → `COCOTB_RANDOM_TEST_ORDER`, `preview` → `COCOTB_PREVIEW` (per-test `parameters` first, then `simulators.cocotb.options`).

**Why this is the default.**

- **Zero cognitive distance from upstream.** Engineers already debug their Cocotb tests by running `make` in the test directory. SimCrux running the *exact same* command means a green run in the dashboard is a green run on the command line and vice-versa. No translation layer to suspect when something diverges.
- **No reimplementation of Cocotb's compile rules.** Cocotb's `Makefile.sim` already knows every wrinkle for Icarus, Verilator, GHDL, Questa, VCS, Riviera-PRO, etc. — what flags to pass, where to find the VPI shared object, how to wire `PYTHONPATH`, `LD_LIBRARY_PATH`, `COCOTB_RESULTS_FILE`. SimCrux inherits all of that for free.
- **Works with every simulator Cocotb supports.** No per-simulator branching in the SimCrux driver itself.
- **Per-test isolation via per-test workdir.** The scheduler allocates a fresh working directory under `{runRoot}/runs/{runId}/{testIdSafe}/`; before invoking `make`, the driver copies every file listed in the test's `sources:` into it, flattened by basename — so the Makefile, the Python test module and the HDL sources must all be listed there. Cocotb's `sim_build/` and `results.xml` artifacts land inside that directory and get retained or cleaned per the scheduler's dump-retention policy.

**Pass/fail.** The driver computes its own verdict — from Cocotb's `results.xml` (xUnit) when present and parseable, else from the `TESTS= PASS= FAIL= SKIP=` summary table, else from `make`'s exit code — and surfaces per-case status, simulated time and (from the report) the failure message and type as `cocotb.*` metrics on the one SimCrux result. The scheduler then classifies the run through the test's configured `pass_fail:` detector, and the driver's verdict stands only when that detector returns `unknown`. The default detector is `exit_code`, and Cocotb 1.9's `make` exits 0 when tests fail, so when the driver's verdict is not a pass and `make` exited 0 the driver reports a **null** exit code (the raw value goes to the `cocotb.process_exit_code` metric) — the `exit_code` detector then returns `unknown` and the driver's failure stands. The report reader counts outcomes from the `<testcase>` children, because only Cocotb 2.1 writes `tests`/`failures` attributes on `<testsuite>`.

**Cost.** Each test pays `make`'s startup tax (a few hundred milliseconds on modern hosts). For a 500-test regression that's a couple of minutes of pure-`make` time. We accept it because it's small relative to a real Cocotb run's compile + simulate time.

## Strategy B — Cocotb's Python runner

Cocotb ships a Python runner API (`cocotb_tools.runner` in 2.x; `cocotb.runner` in 1.8/1.9) that you can call from a `pytest` test or a plain Python script, bypassing `make`. The third-party `cocotb-test` package offers a similar pytest-driven flow. Either way the runner builds and runs the simulation from Python instead of from `Makefile.sim`.

**Why we did NOT pick this.**

1. **Two source-of-truth surfaces.** Many Cocotb projects in the wild use the Makefile flow exclusively; running them through the Python runner requires the user to author a parallel runner script. SimCrux would either need to generate that script (then explain when it diverges from the user's Makefile) or refuse to consume the project.
2. **Newer / less battle-tested.** The Makefile flow is older and more widely used; sticking with it minimizes the "SimCrux works but `make` doesn't, why?" support burden.
3. **The savings are small.** ~300 ms × N tests; not material until N is in the thousands and the per-test simulation time is itself small.

## When to revisit (add B)

Add a `CocotbRunnerDriver` (and keep this one as `CocotbMakeDriver`) only if **at least one** of the following becomes true:

- A real regression hits the `make` startup tax as a measurable scheduling problem (`make` per-test cost ≥ 10% of total wall-clock).
- Cocotb upstream deprecates `Makefile.sim`.
- A simulator whose Cocotb integration is runner-only (no Makefile rules) needs supporting.

At that point the new driver ships *alongside* strategy A — projects would opt in through a new `simulators.cocotb.options` key (none exists today). The Makefile flow remains the default, because reproducing a SimCrux failure on the command line by typing `make` is too valuable to give up.

## Where the implementation lives

- `lib/services/simulator/cocotb_driver.dart` — strategy A, plus the summary-table and per-test-row parsers.
- `lib/services/simulator/cocotb_junit.dart` — the `results.xml` reader.
- `test/services/simulator/cocotb_driver_test.dart` — unit tests with a scripted `_FakeProcess` for `make`.
- `test/fixtures/projects/cocotb_dff/` — end-to-end fixture, run by `test/integration/fixture_pipeline_test.dart` and skipped when `cocotb-config`, `make` or `iverilog` is missing.
