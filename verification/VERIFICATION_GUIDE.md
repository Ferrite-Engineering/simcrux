# SimCrux (Open Core) — Verification Guide

> **Purpose.** Pre-release end-user verification reference for every Open Core SimCrux feature. Run the relevant sections before any tagged release.
>
> **Companion documents.**
> - `VERIFICATION_CHECKLIST.md` (sibling, this folder) — quick sign-off bullet list.
> - The Pro overlay's own verification guide — Pro overlay verification. Pro builds **inherit every Open Core check**; the Pro guide covers only the Pro/Enterprise delta.
>
> **Discipline.** This document grows alongside the implementation. Every shipped Open Core feature has a populated section here, and writing that section is a mandatory part of the same commit set that ships the implementation — see `CLAUDE.md` → "Verification Documentation Required."
>
> **Integration tests.** The Flutter `integration_test/` suite (harness: `integration_test/helpers/app_driver.dart`, `bootSimcrux`; seeded-run harness: `integration_test/helpers/seeded_run.dart`, `ScriptedDriver` + `writeSeededProject` + `tabContainerFor`) drives a real running app on macOS for: cold-boot empty-canvas (`workspace/empty_canvas_boot_test.dart`), workspace auto-save + restore round-trip (`workspace/restore_round_trip_test.dart`), named workspace save/reset/open round-trip (`workspace/named_workspace_test.dart`), split-pane + move-tab-between-panes (`workspace/split_pane_test.dart`), CLI multi-config open → tab structure (`tabs/cli_multi_config_test.dart`), theme preset switch (`theme/theme_switch_test.dart`), seeded run → dashboard filter/sort/select → inspector details + log preview (`dashboard/seeded_run_dashboard_test.dart` — the full ConfigLoader → scheduler → detector → result-store pipeline against a scripted in-process driver), inspector source navigation (`dashboard/inspector_open_source_test.dart` — Open Source button hand-off to a recording `editorLauncherProvider` fake), the dashboard view-mode toggle (`dashboard/dashboard_heatmap_view_mode_test.dart` — table → heatmap switch, per-test cell rendering, cell-tap selection), and the CXP server lifecycle (`remote/cxp_server_lifecycle_test.dart` — real socket on an OS-picked port; start / stop-on-disable / restart-on-re-enable). Coverage status is tracked in `integration_test/PENDING.md` (no open items).

---

## 1. How to use this document

### 1.1 Pre-release flow

1. Run §2 (fixture inventory) — confirm every fixture is present and current.
2. Run the per-feature sections for the features in the release.
3. Cross-check tier-gate scenarios for any feature promoted into / out of a tier.
4. Sign off via §99.

### 1.2 Per-test format and coverage taxonomy

Same conventions as WaveCrux's `wavecrux/verification/VERIFICATION_GUIDE.md` §1.2 and §1.4.

---

## 2. Fixture inventory

All fixtures live under `verification/fixtures/` and are committed to the repo. Generation scripts live under `tool/`.

| Folder | Files | Purpose |
|---|---|---|
| `test/fixtures/projects/iverilog_pass/` | `simcrux.yaml`, `tb_pass.v`, `.expected_results.json` | Smoke fixture: Icarus pass path |
| `test/fixtures/projects/iverilog_fail/` | `simcrux.yaml`, `tb_fail.v`, `.expected_results.json` | Smoke fixture: Icarus fail path |
| `test/fixtures/projects/verilator_pass/` | `simcrux.yaml`, `tb_pass.v`, `.expected_results.json` | Verilator pass path; the integration test skips without the Verilator C++ toolchain |
| `test/fixtures/projects/verilator_timing/` | `simcrux.yaml`, `delay_bench.v`, `.expected_results.json` | Verilator 5: `#` delays, `-Wall` style warnings and a define passed through `simulators.verilator.options.args` must still pass |
| `test/fixtures/projects/vhdl_pass/` | `simcrux.yaml`, `tb_pass.vhd`, `.expected_results.json` | Smoke fixture: GHDL pass path |
| `test/fixtures/projects/vhdl_fail/` | `simcrux.yaml`, `tb_fail.vhd`, `.expected_results.json` | Smoke fixture: GHDL fail path |
| `test/fixtures/projects/cocotb_dff/` | `simcrux.yaml`, `dff.v`, `test_dff.py`, `Makefile`, `.expected_results.json` | Cocotb fixture: tiny DFF + pytest-style Python testbench |
| `verification/fixtures/golden_compare/<case>/` | `case.json`, dump files, `expected.json` | `golden_compare` corpus: clean pass, first-word / mid-file / length divergence, empty DUT, missing DUT, and the format-variance profile pair. Regenerate with `dart run tool/generate_golden_compare_fixtures.dart` |

Fixture families:

- **Simulator drivers** (Icarus, Verilator): minimal testbench source + expected pass/fail signature. **Status:** Icarus shipped; Verilator stub shipped.
- **GHDL, Cocotb, FuseSoC, mixed language**: GHDL fixture, Cocotb fixture, FuseSoC consumption fixtures, mixed-language fixture. **Status:** all shipped. GHDL pass/fail under `test/fixtures/projects/vhdl_pass`/`vhdl_fail`; Cocotb DFF under `test/fixtures/projects/cocotb_dff`; FuseSoC `.core` import fixtures under `test/fixtures/fusesoc/{simple,multi_target,unsupported}.core`; mixed-language under `test/fixtures/projects/mixed_language`.
- **CXP receive scenarios** (incoming `request_filter_to_test`, `request_filter_to_failures_in`): not built — those message kinds are not part of CXP v1 (§7).
- **RISC-V**: `golden_compare` signature pairs. **Status:** shipped, hand-authored so no third-party attribution obligation is created. The `riscv_arch` driver's demo mode replays the same corpus (§18.2).

---

## 3. Foundation

> **Status.** Shipped: the tri-platform CI matrix, the SQLite-backed persistent trend store, and the localized empty-canvas launch surface are all in place. (The current-run `ResultStore` is deliberately in-memory — durable SQLite persistence lives in the `TrendStore`, not the result store.)

### 3.1 CI matrix (Linux / macOS / Windows)

**What it does (plain language).** `.github/workflows/ci.yml` (workflow `CI`, triggered on `pull_request` + `workflow_dispatch`) is the automated gate every change passes before merge: static analysis + format on Linux, the test suite on all three desktop OSes, then release + web builds.

**Setup.** None for the reviewer beyond an open PR. To reproduce locally, run the same commands the workflow runs (below).

**Step-by-step expected behavior.**

1. The `analyze` job (ubuntu) runs `flutter pub get` → `dart run build_runner build` → `flutter gen-l10n` → `flutter analyze --fatal-infos --fatal-warnings` → a format check (`git ls-files -z '*.dart' | xargs -0 -r dart format --output=none --set-exit-if-changed`).
2. The `test` job runs on the OS matrix `[ubuntu-latest, macos-latest, windows-latest]` with `fail-fast: false`, invoking `flutter test --reporter github`.
3. `build-desktop` (needs analyze + test) produces linux/macos/windows release builds and uploads 7-day-retention artifacts; `build-web` produces `flutter build web --release`.

**Diagnostics-assisted verification.** The GitHub Actions run summary shows a per-OS test result and, on a format failure, the offending file via the `--set-exit-if-changed` diff.

**Edge cases.**

- Format-only drift (correct code, wrong whitespace) fails the `analyze` job — formatting is CI-enforced, not advisory.
- A test failing on one OS does not cancel the other two (`fail-fast: false`), so a platform-specific failure is visible in isolation.
- Analyze/format run only on Linux; a Linux-green PR whose tests fail on Windows is still red overall.

**Tier-gate scenarios.** N/A — Open Core infrastructure.

**Automation Assessment.** The matrix *is* the automation. `Coverage: AUTOMATED — GitHub Actions (analyze + test × 3 OS + desktop/web build)`. The only manual step is confirming the PR check is green.

### 3.2 SQLite trend-store round-trip (the persistent store)

**What it does (plain language).** The `TrendStore` interface (`lib/domain/interfaces/trend_store.dart`) records per-test trend points; the SQLite-backed `SqlTrendStore` (`lib/services/trend_store/sql_trend_store.dart`, with `sql_trend_store_io.dart` on desktop via `sqflite_common_ffi` and `sql_trend_store_web.dart` on the web viewer) persists them to `<applicationSupportDirectory>/trends.db` (`trend_store_provider.dart`). "Round-trip" = write points, close the DB, reopen at the same path, read them back. The current-run `ResultStore` (`lib/services/result_store/in_memory_result_store.dart`) is in-memory by design — durability is the trend store's job.

**Setup.** A desktop build (the io backend uses `sqflite_common_ffi`). No external service; the database is a local file. Tests pass a directory override and use `inMemoryDatabasePath`.

**Step-by-step expected behavior.**

1. Run a regression (any fixture) so trend points are recorded.
2. Quit and relaunch SimCrux.
3. Open a per-test trend chart (or the App Diagnostics storage-stats view) — prior runs' points are present, proving persistence survived the restart.

**Diagnostics-assisted verification.** The App Diagnostics dialog surfaces `TrendStore.storageStats` (row count + min/max timestamps); confirm the count matches the runs recorded.

**Edge cases.**

- The first trend point for a run implicitly creates the run row (no separate "begin run" call).
- A first-time test reports `previousStatus = null` (no phantom prior).
- A batched insert fires exactly one `dataChanged` notification; an empty batch is a no-op.
- The store opens at the latest schema version, applying migrations (`sql_migrations.dart`) on an older file.

**Tier-gate scenarios.** N/A — the store is Open Core. (Pro layers retention UI and per-project scoping on top.)

**Automation Assessment.** `test/services/trend_store/sql_trend_store_test.dart` (group `'persistence across reopen'` → `'writes survive close + reopen at the same path'`, plus implicit-run-row, batch-notification, and schema-version cases), with `sql_recovery_test.dart` and `sql_migrations_test.dart` alongside (`Coverage: AUTOMATED — flutter test`). Manual spot-check: relaunch and confirm history is retained.

### 3.3 Empty-canvas launch surface — theme + locale sweep

**What it does (plain language).** On cold boot with no project loaded, SimCrux shows `EmptyCanvasContent` (`lib/features/workspace/widgets/empty_canvas_content.dart`, backed by `empty_canvas_content_provider.dart`) — the primary actions (Open Config…, Open Session…, Open Workspace…) plus a recent-configs list — localized in all four locales and themed by the active preset. (There is no separate "welcome" screen; the empty canvas is the launch surface.)

**Setup.** Launch with an empty workspace (or clear the persisted workspace first).

**Step-by-step expected behavior.**

1. Cold-boot lands on the empty-canvas state: zero tabs, and "No recent configs yet." when settings carry no recents.
2. Switch locale (`en` / `zh_CN` / `ja` / `ko`) — every label re-renders without overflow.
3. Switch theme preset (Settings → Appearance) — the chrome brightness flips live.

**Diagnostics-assisted verification.** The integration test drives the real app on macOS; the widget test asserts no render overflow across the locale sweep.

**Edge cases.**

- No recent configs → the placeholder text renders; recent configs present → the recent-configs section renders instead.
- The four primary action labels are asserted in English so a missing ARB key fails the test.

**Tier-gate scenarios.** N/A — Open Core.

**Automation Assessment.** `test/features/workspace/widgets/empty_canvas_content_test.dart` (group `'EmptyCanvasContent — locale sweep'` across `en`/`zh_CN`/`zh`/`ja`/`ko`: overflow, recent-configs, action labels) (`Coverage: AUTOMATED — flutter test`). Theme-preset switch: `integration_test/theme/theme_switch_test.dart` (`'switching presets flips MaterialApp brightness'`); cold-boot: `integration_test/workspace/empty_canvas_boot_test.dart` (`Coverage: AUTOMATED — flutter test --tags integration` / macOS integration run).

## 4. Icarus + Verilator + Dashboard

> **Status.** Shipped: the `SimulatorDriver` contract with the Icarus and Verilator process-backed drivers, the `LocalJobScheduler` happy path (bounded concurrency, resource locks, timeout, retry), the regression dashboard (pass/fail/skip counts + inspector drill-in), and the `simcrux.yaml` config load path.

### 4.1 SimulatorDriver contract — Icarus + Verilator

**What it does (plain language).** `SimulatorDriver` (`lib/domain/interfaces/simulator_driver.dart`) is the driver contract: `id`, `displayName`, `capabilities`, `detectVersion`, `compile`, `execute` (a stream of `TestExecutionEvent`), `cancel`. `IcarusDriver` (`lib/services/simulator/icarus_driver.dart`) wraps `iverilog` + `vvp`; `VerilatorDriver` (`verilator_driver.dart`) wraps `verilator`. Both extend the shared `process_backed_simulator_driver.dart`. A missing binary throws `SimulatorNotAvailableException` (`simulator_not_available_exception.dart`), which the scheduler catches and surfaces as a `fail` row with a remediation hint — never an opaque `?`.

**Setup.** `iverilog` + `vvp` (Icarus) or `verilator` on `$PATH`, or a custom path via Settings → Simulators.

**Step-by-step expected behavior.**

1. Open `test/fixtures/projects/iverilog_pass/` → the driver compiles (`iverilog`), runs (`vvp`), and the dashboard row goes green.
2. `iverilog_fail` → the run exits nonzero → the row goes red.
3. Rename/uninstall the binary → the row reads `fail` with `"… binary \`iverilog\` not available (system)."` plus "Install … on the host PATH or configure a custom binary path in Settings → Simulators".

**Diagnostics-assisted verification.** The inspector's log viewer streams stdout/stderr as `TestLogLine` events; the failure message names the missing binary and its `source`.

**Edge cases.**

- `iverilog` present but `vvp` missing → the driver emits a finished event with `unknown`.
- `cancel` kills the in-flight `vvp` / `verilator` process and escalates `SIGTERM` → `SIGKILL` after a grace period.
- **Settings → Simulators path vs the project file.** A project `simulators:` entry with `source: custom` + `path` wins; an entry that only sets `options:` / `env:` keeps them and takes the Settings path; no entry takes the Settings path. **Manual check:** set a Settings path for cocotb, add `simulators: {cocotb: {options: {sim: icarus}}}`, run — the log shows the Settings `make`. (`Coverage: AUTOMATED — regression_runner_test.dart → Settings > Simulators binary path`)
- **Verilator warnings, delays and flags.** Open `test/fixtures/projects/verilator_timing/` with Verilator 5: its testbench uses `#` delays, has a module name that differs from its file name and an unused wire, and reads a define that only `simulators.verilator.options.args` supplies. Expected: the log shows the `%Warning-DECLFILENAME` / `%Warning-UNUSEDSIGNAL` lines and the row is green (the driver passes `--timing -Wall -Wno-fatal` and the args). With Verilator 4 no `--timing` is passed. A Verilator 5 testbench that runs out of events without `$finish` exits `1` with `simulation ran out of events before $finish`. (`Coverage: AUTOMATED — verilator_driver_test.dart; flutter test --tags integration (fixture_pipeline_test.dart, verilator_timing)`)

**Tier-gate scenarios.** N/A — Open Core.

**Automation Assessment.** `test/domain/interfaces/simulator_driver_test.dart`, `test/services/simulator/icarus_driver_test.dart`, and `verilator_driver_test.dart` cover the version banner, command-line construction, the missing-binary exception, and cancel/escalation (`Coverage: AUTOMATED — flutter test`). Real-binary end-to-end runs through `test/integration/fixture_pipeline_test.dart`, which `skip:`s when the tool is absent (`Coverage: AUTOMATED — flutter test --tags integration`).

### 4.2 JobScheduler happy path

**What it does (plain language).** `LocalJobScheduler` (`lib/services/job_scheduler/local_job_scheduler.dart`) runs a `RegressionRequest`'s specs bounded by `RegressionRequest.concurrency`, honors resource locks (tests sharing a lock run strictly serially), enforces a per-test timeout (cancel + `timedOut`), and applies a `RetryPolicy` with a scheduler-side ceiling. It emits `TestStarted` / `TestLog` / `TestFinished` events in order.

**Setup.** Any multi-test fixture; set `concurrency` in the run request.

**Step-by-step expected behavior.**

1. Run an 8-test suite with concurrency N → at most N run in parallel (the dashboard's running count reflects it).
2. Two tests declaring a shared resource lock run strictly serially.
3. A hung test is cancelled at its timeout and reported as `timeout`.
4. Exit codes classify pass / fail.

**Diagnostics-assisted verification.** The dashboard's running/passing/failing counts track live parallelism; the log panel streams per-test lines.

**Edge cases.**

- The default `NoopRetryPolicy` emits no retries on failure.
- A policy returning `true` reruns until the first pass; the scheduler-side ceiling caps runaway policies.

**Tier-gate scenarios.** N/A — Open Core.

**Automation Assessment.** `test/services/job_scheduler/local_job_scheduler_test.dart` covers exit-code classification, event ordering, the concurrency bound (`'bounds parallel runs by RegressionRequest.concurrency'`), resource-lock serialization, timeout, and the `RetryPolicy` paths (`Coverage: AUTOMATED — flutter test`). Deterministic end-to-end orchestration is covered by the golden fixture corpus under `test/fixtures/orchestration/` (see ARCHITECTURE §8.9).

### 4.3 Regression dashboard — counts + inspector drill-in

**What it does (plain language).** `DashboardView` (`lib/features/dashboard/widgets/`) plus the window-bottom `RegressionStatusBar` (`lib/features/workspace/widgets/`) render aggregate total / pass / fail / running counts, and skipped / timed-out / error counts when those are non-zero (via `dashboardTotalsProvider` / `DashboardTotals.fromRun` in `dashboard_providers.dart`); `DashboardResultsTable` filters and sorts; selecting a row drives the inspector (`InspectorPane` / `InspectorDetails`, `lib/features/inspector/widgets/`) with the test's metrics, exit code, and log preview.

**Setup.** A completed (or running) regression.

**Step-by-step expected behavior.**

1. The status bar counts reflect the run. With no run active the four headline counts read zero; skipped / timed-out / error are absent rather than zero (the suite's zero-suppression rule).
2. Filter by status / sort by duration — the results table updates.
3. Select a row → the inspector shows details + log preview; a missing exit code renders a dash rather than a blank.

**Diagnostics-assisted verification.** The locale sweep asserts the status bar renders without exceptions in every locale.

**Edge cases.**

- No active run → localized zeros, not an empty/blank bar.
- Optional inspector rows are omitted when the underlying value is absent.

**Tier-gate scenarios.** N/A — Open Core. (Pro contributes the toolbar extension buttons via `extraDashboardActionsProvider`, rendered by `SimcruxToolbar`.)

**Automation Assessment.** `test/features/workspace/widgets/regression_status_bar_test.dart` (`'surfaces the run summary once totals arrive'`, the zero-suppression pair), `test/features/dashboard/providers/dashboard_providers_test.dart` (`DashboardTotals.fromRun` `'counts by status'`, `filterAndSortDashboardRows`), and `test/features/inspector/widgets/inspector_details_test.dart` (`Coverage: AUTOMATED — flutter test`). End-to-end drill-in: `integration_test/dashboard/seeded_run_dashboard_test.dart` (`'seeded run populates the dashboard; filter, sort, and select drive the table and the inspector'`). The inspector's "Open Source" button hand-off to the user's configured editor is covered end-to-end in `integration_test/dashboard/inspector_open_source_test.dart` (`editorLauncherProvider` overridden at the root container with an `EditorLauncher` wired to a recording `processStarter` fake — no real editor process is spawned; asserts the resolved absolute testbench source path and default `1:1` line/column). The `DashboardViewModeToggle` table↔heatmap switch (`DashboardHeatmapView`, one cell per test keyed by status, cell tap driving the same `selectedTestIdProvider` selection as a table row) is covered end-to-end in `integration_test/dashboard/dashboard_heatmap_view_mode_test.dart` (`Coverage: AUTOMATED — flutter test --tags integration` for both).

### 4.4 Test config YAML round-trip (load → model)

**What it does (plain language).** `ConfigLoader` (`lib/services/config/config_loader.dart` and its section-parser part files — `config_loader_readers` / `_sources` / `_sweeps` / `_pass_fail` / `_sections`) parses `simcrux.yaml` into a `RegressionConfig`: schema validation, defaults inheritance (project → suite → test, test wins), `includes:` resolution, `.f` filelist expansion, and parameter/seed sweep expansion. "Round-trip" here is **load → model** fidelity with source-span error reporting — there is no YAML serialize-back path.

**Setup.** A `simcrux.yaml` (any fixture under `test/fixtures/projects/`).

**Step-by-step expected behavior.**

1. Load a valid config → the model reflects the merged defaults; parameterized templates expand to deterministic, stable test ids.
2. Malformed YAML → a structured error carrying a `file:line:col` span; all errors accumulate rather than failing fast.
3. A test with no resolvable simulator → a structured error naming the three places `simulator:` can be set.

**Diagnostics-assisted verification.** Errors surface with their source spans in the config-error surface; the accumulation behavior means one bad file reports every problem at once.

**Edge cases.**

- An `includes:` cycle is detected and reported.
- An included file with no `defaults.timeout` inherits the including file's (its own wins when set) — `Coverage: AUTOMATED — config_loader_includes_test.dart`.
- A sweep that would expand past the max (10 000) is rejected before any process spawns, with the actual size in the message.
- Post-beta Open Core (`--dart-define=BETA_PERIOD=false`), a `seeds: [1, 2, 3]` test loads as one test with an advisory: the dashboard shows **This project loaded with 1 warning** above the results table with `path:line:col: … requires SimCrux Pro …`, a screen reader hears the heading, **Dismiss** hides it; `--ci` prints `warning: …` on stderr. (`Coverage: AUTOMATED — config_load_warnings_banner_test.dart, ci_runner_test.dart`)
- An unknown `pass_fail.type` is reported with the allowed set.
- A `regex` `pass_pattern` / `fail_pattern` that does not compile (e.g. `(?i)error`) is reported at its line, with a hint to use `(?i:…)`; so is one inside a composite, or inside a Settings library detector a project references with `type: use`. Before this check the detector returned `unknown` and a failing exit-0 test passed. **Manual check:** set `fail_pattern: "(?i)error"` in a fixture project and open it — the load fails naming `fail_pattern` (`Coverage: AUTOMATED — test/services/config/config_loader_regex_validation_test.dart`).

**Tier-gate scenarios.** N/A at the load layer — Open Core. (Multi-value `seeds:` / `parameters:` sweep *expansion* is Pro-gated post-beta; see the Pro guide's parameterization section.)

**Automation Assessment.** `test/services/config/config_loader_test.dart` (groups `'ConfigLoader.parse — happy paths'`, `'— error reporting'`, `'ConfigLoader.load — file I/O'`) plus the includes / parameterization / mixed-language / use-detector / expansion-fuzz suites (`Coverage: AUTOMATED — flutter test`).

## 5. GHDL, Cocotb, FuseSoC, Web Dashboard

> **Status.** Shipped: GHDL driver, Cocotb driver (Makefile wrap), UVM report parser + detector, the Flutter Web read-only dashboard, the streaming SARIF-like JSON writer, the composite-detector UI improvements, the mixed-language design routing, and the FuseSoC `.core` importer have all shipped.

### 5.1 GHDL driver

**What it does (plain language).** Runs VHDL simulations through GHDL. SimCrux invokes the standard three-stage flow inside the per-test working directory the scheduler allocates: `ghdl -a <sources>` (analyze) → `ghdl -e <top>` (elaborate) → `ghdl -r <top> [--vcd=…|--fst=…|--wave=…]` (run). Pass/fail follows the configured `PassFailDetector`; the driver's best-guess is exit code 0 ⇒ pass.

**Setup.** `ghdl --version` must be on `$PATH`. Either backend (mcode / llvm / gcc) works; the SimCrux user signals their preferred backend via `simulators.ghdl.options.backend` in `simcrux.yaml`. VCD/FST/GHW waveform capture is wired automatically per the project's `waveform.format`.

**Step-by-step expected behavior.**

1. Open `test/fixtures/projects/vhdl_pass/` in SimCrux (or run the integration test `test/integration/fixture_pipeline_test.dart::vhdl_pass smoke fixture reports pass end-to-end (ghdl)`).
2. The smoke suite's `pass_basic` test resolves to GHDL via `defaults.simulator: ghdl`.
3. The scheduler allocates a per-test workdir, invokes `ghdl -a tb_pass.vhd` then `ghdl -e tb_pass` then `ghdl -r tb_pass`.
4. The TB writes `TEST PASSED` to stdout and the `string_match` detector classifies the run as pass.
5. The dashboard row updates to green.
6. The corresponding fail-path (`vhdl_fail`) fires VHDL `report ... severity failure`, the run exits nonzero, and the dashboard row updates to red.

**Diagnostics-assisted verification.** The driver streams stdout/stderr through `TestLogLine` events — the inspector pane's log viewer shows analyze errors (`tb_pass.vhd:N:M: error...`) alongside run output. Confirm `Working directory:` displays the scheduler-allocated path.

**Edge cases.**

- `ghdl` not installed: the driver throws `SimulatorNotAvailableException`; the result row reads `unknown` with a remediation hint pointing at `simulators.ghdl.source`.
- Analyze fails: compile-stage exit code surfaces in the `CompileResult`; the run reaches `fail` without entering execute.
- Elaborate fails: same, with the elaborate stderr captured.
- `simulators.ghdl.options.backend` set: the value is preserved and a future iteration can flag mismatch between selected and installed backend; for now the option is opaque and the user's installed `ghdl` decides.

**Tier-gate scenarios.** N/A — Open Core feature.

**Automation Assessment.** Unit tests in `test/services/simulator/ghdl_driver_test.dart` cover every code path (`Coverage: AUTOMATED — flutter test`). The end-to-end integration tests `vhdl_pass` and `vhdl_fail` exercise the real GHDL binary and `skip:` when ghdl is absent (`Coverage: AUTOMATED — flutter test --tags integration`).

### 5.2 Cocotb driver (Makefile wrap)

**What it does (plain language).** Runs Python-coroutine testbenches via Cocotb's standard Makefile flow. SimCrux invokes `make SIM=<sim> TOPLEVEL=<top>` inside the per-test workdir; Cocotb's `Makefile.sim` handles compile and execute against the underlying HDL simulator (Icarus / Verilator / GHDL). The driver parses Cocotb's end-of-run summary table (`** TESTS=N PASS=N FAIL=N SKIP=N **`) for pass/fail classification and surfaces structured metrics (`cocotb.tests`, `cocotb.pass`, `cocotb.fail`, `cocotb.skip`, plus `cocotb.test.<name>.status` and `cocotb.test.<name>.sim_time_ns`) onto `TestResult.metrics`.

**Setup.** `cocotb-config --version` and `make` must be on `$PATH`. Underlying simulator: `simulators.cocotb.options.sim` (default `icarus`); per-test override via `parameters: { sim: verilator }`.

**Step-by-step expected behavior.**

1. Open `test/fixtures/projects/cocotb_dff/` in SimCrux (or run the integration test `cocotb fixture loads when cocotb-config + make are available`).
2. The `smoke/dff` test resolves to Cocotb via `defaults.simulator: cocotb`; the project's `simulators.cocotb.options.sim = icarus` selects Icarus as the underlying simulator.
3. The scheduler allocates a workdir; the driver copies `dff.v`, `test_dff.py`, `Makefile` into it; spawns `make SIM=icarus TOPLEVEL=dff MODULE=test_dff TOPLEVEL_LANG=verilog`.
4. Cocotb's Makefile invokes Icarus, runs the Python testbench, prints the summary table.
5. Driver parses `** TESTS=1 PASS=1 FAIL=0 SKIP=0 **` ⇒ classifies pass; emits `cocotb.tests=1`, `cocotb.pass=1`, `cocotb.test.test_passes.status=PASS`, etc., onto `TestResult.metrics`.

**Diagnostics-assisted verification.** The inspector's Metrics tab displays the structured `cocotb.*` rows.

**Edge cases.**

- Cocotb's exit code disagrees with the report or summary (Cocotb 1.9's `make` returns 0 despite FAILs). With no `pass_fail:` block the test is still a **fail**: the driver reports a null exit code so the default `exit_code` detector returns `unknown`, and records the raw 0 as `cocotb.process_exit_code`. To check by hand, change `test_dff.py` to `assert False` and run with cocotb 1.9 (or with a Makefile that ends in `|| true`) — the row reads FAIL, and `--ci` exits 1. `Coverage: AUTOMATED — test/services/job_scheduler/cocotb_default_verdict_test.dart`.
- A cocotb 1.9 / 2.0 `results.xml` carries no `failures=` count on `<testsuite>`; failures are counted from the `<failure>` children (`Coverage: AUTOMATED — test/services/simulator/cocotb_junit_test.dart`).
- Summary line absent (Make killed early, broken Makefile). Driver falls back to make's exit code; the scheduler then routes through `PassFailDetector`.
- `make` missing: driver throws `SimulatorNotAvailableException`.
- `max_failures: "abc"` (or `0`) in `simulators.cocotb.options` or a cocotb test's `parameters:` fails the load at its line. A driver that throws while building its command line (any driver) now ends the test at once as `unknown` with `driver error: …` instead of waiting out the timeout, or killing the standalone binary with exit 255. (`Coverage: AUTOMATED — config_loader_cocotb_options_test.dart, process_backed_simulator_driver_test.dart, cocotb_driver_test.dart`)
- Underlying simulator missing (e.g. `SIM=ghdl` but ghdl not installed): make returns nonzero with simulator-specific error in stderr; driver classifies fail and surfaces the stderr in the inspector log viewer.

**Strategy A vs B.** SimCrux ships strategy A (Makefile wrap) deliberately — see [`docs/cocotb-strategy.md`](../docs/cocotb-strategy.md) for the decision log and the trigger conditions for switching to strategy B (`cocotb_test` runner).

**Tier-gate scenarios.** N/A — Open Core feature.

**Automation Assessment.** Unit tests in `test/services/simulator/cocotb_driver_test.dart` cover the launch invocation, the SIM override, summary/per-test parsing, and metrics emission (`Coverage: AUTOMATED — flutter test`). The Cocotb fixture's integration test `skip:`s when `make` or `cocotb-config` are missing (`Coverage: AUTOMATED — flutter test --tags integration`).

### 5.3 UVM report parser + UvmReportDetector

**What it does (plain language).** Counts `UVM_FATAL` / `UVM_ERROR` / `UVM_WARNING` / `UVM_INFO` messages in a testbench's stdout (either from the end-of-run `--- UVM Report Summary ---` table or per-message lines), then applies configurable thresholds:

- `fatalThreshold` (default `1`): N or more fatals ⇒ fail. Set to `0` to disable.
- `errorThreshold` (default `1`): N or more errors ⇒ fail. Set to `0` to disable.
- `warningThreshold` (default `null`): warnings never fail by themselves. Set to N to fail when crossed.

YAML schema:

    pass_fail:
      type: uvm_report
      fatal_threshold: 0       # optional, default 1
      error_threshold: 5       # optional, default 1
      warning_threshold: 100   # optional, default null (warnings never fail)

Composable through `CompositePassFailConfig` — common pattern is `all_of: [exit_code, uvm_report]`.

**Setup.** No external binary requirement — the detector consumes stdout / stderr already collected by the scheduler. Typically paired with the Cocotb driver running a UVM-Python testbench, or with the GHDL/Verilator driver running a native-UVM testbench.

**Step-by-step expected behavior.**

1. Configure a test with `pass_fail: { type: uvm_report }`.
2. Run the test under any simulator driver.
3. The detector reads the captured stdout + stderr, parses the UVM summary table when present (preferred), otherwise scans per-message lines.
4. Returns pass / fail / unknown per the threshold rules above.

**Edge cases.**

- No UVM signal at all: returns `unknown` so the composite / scheduler can fall back to the exit-code default.
- Summary table present but empty: parser tolerates partial summaries (missing rows count as 0).
- Per-message and summary both present: summary wins (authoritative).
- Lines like `UVM_INFOXY` are not counted — the parser requires a non-identifier follower after the severity token.

**Tier-gate scenarios.** N/A — Open Core feature.

**Automation Assessment.** Unit tests cover the parser (`test/services/pass_fail_detector/uvm_report_parser_test.dart`) and detector (`test/services/pass_fail_detector/uvm_report_detector_test.dart`), plus registry-level dispatch + composite chaining (`test/services/pass_fail_detector/pass_fail_detector_registry_test.dart`) (`Coverage: AUTOMATED — flutter test`).

### 5.4 SimulatorDriverRegistry: GHDL and Cocotb alongside Icarus and Verilator

**What it does (plain language).** Adds GHDL and Cocotb to the in-memory `simulatorId → SimulatorDriver` map that the scheduler consults when dispatching tests. Backwards-compatible: every Icarus / Verilator `simcrux.yaml` continues to load and run unchanged.

**Verification.** Unit test `test/services/simulator/simulator_driver_registry_test.dart::holds the Icarus, Verilator, GHDL and Cocotb drivers side-by-side` asserts all four drivers are reachable via `driverFor()` and exposed via `simulatorIds`.

**Automation Assessment.** `Coverage: AUTOMATED — flutter test`.

### 5.5 Streaming SARIF-like JSON writer

**What it does.** Writes one JSON object per line to a `results.ndjson` file as each test finishes (instead of accumulating the full result list in memory). Also writes a `results.summary.json` aggregate at run completion. The CI runner enables streaming by default; interactive runs opt in via `output: { streaming: true }` in `simcrux.yaml`. The existing JUnit / JSON / CSV / HTML exporters can read from the NDJSON file via `StreamingResultsReader` + `StreamingResultsHydrator` instead of the in-memory store, so very-large regressions complete with bounded RSS.

**Schema.** `version: 1`. Forward-compatible: unknown line types and unknown keys are silently ignored.

```json
{"type":"meta","version":1,"run_id":"…","started_at":"…","config_path":"…"}
{"type":"result","id":"…","name":"…","suite":"…","simulator":"…","status":"pass",…}
{"type":"summary","total":N,"totals":{"pass":…,"fail":…,…},"finished_at":"…"}
```

**Setup.**

1. Add `output: { streaming: true }` to a `simcrux.yaml`, or run with `--ci`.
2. Run a regression.
3. Inspect `<project-dir>/results.ndjson` and `<project-dir>/results.summary.json`.

**Expected behavior.**

- The NDJSON file grows as tests finish (one new line per `TestFinished`).
- On graceful completion, the final line is a `summary` record and the standalone summary file is written.
- An interrupted run leaves the NDJSON file readable up to the last fully-flushed line; the reader tolerates a missing trailing summary and reports `summary == null`.
- The bounded-memory benchmark test (`bounded memory 100K rows complete without retaining row JSON in memory` in `streaming_results_writer_test.dart`) confirms the writer's in-memory footprint is the counts map only.

**Edge cases.**

- Zero-result runs: the writer still emits the `meta` + `summary` lines on completion.
- Calling `recordRow` before `start()` or after `recordRunCompletion()` throws `StateError`.
- Custom paths via `output: { results_path: '…', summary_path: '…' }`, resolved against the directory holding `simcrux.yaml`.
- A custom path must stay inside that directory, because `--ci` creates and truncates both files. `results_path: ../../victim.txt`, an absolute path elsewhere, or `build/results.ndjson` where `build` is a symbolic link out of the project each stop the load with the file, line and column of the value; the same project loads with `--allow-project-tooling` (or the Settings → Simulators project-tooling switch) and writes where it says. The writer re-checks both paths immediately before opening each, so a config built in code, or a directory that became a link after the load, fails the run with nothing created or truncated.

**Automation Assessment.** `Coverage: AUTOMATED — flutter test` (`streaming_results_writer_test.dart` covers writer, reader, hydrator, bounded-memory and project-containment cases; `ci_runner_test.dart` verifies the writer is invoked under `--ci`, where the paths resolve and what `--allow-project-tooling` lifts; `config_loader_output_paths_test.dart` and `project_output_path_test.dart` cover the load-time refusal for the `../`, absolute and symbolic-link shapes).

**Seam note — `--ci` driver registry resolution.** The non-interactive `--ci` bootstrap path (`lib/app.dart`) resolves its simulator-driver registry through the same transient `ProviderContainer` (built from `extraOverrides`) it already reads `failOnRegressionPolicyProvider` from, via `simulatorDriverRegistryProvider`. Open-core builds resolve the stock four built-in drivers **plus** the plugin registry (the previously-hardcoded construction dropped the plugin registry, so Pro plugin-contributed drivers now work under `--ci` too); a Pro overlay override — or a test's scripted-driver override — reaches the CI scheduler exactly as it reaches the interactive scheduler. Covered by `test/app_ci_driver_injection_test.dart` (injected pass/fail driver drives the real `--ci` code path and surfaces `dart:io`'s `exitCode`) (`Coverage: AUTOMATED — flutter test`).

**Seam note — the regression policy is told the run's tier.** `CiRunner` passes `licenseTier:` — the tier `--ci` resolved with `HeadlessLicenseTierResolver`, the one the project also loads at — to every `FailOnRegressionPolicy` decision, from both the desktop `--ci` path and the standalone binary. The open-core no-op ignores it; the overlay's policy, which carries the paid comparison engine, uses it to refuse the gate at a tier that does not include it. Covered by `test/services/ci/ci_runner_test.dart` (every tier reaches the policy; a runner built without one hands it Open Core), `test/app_ci_driver_injection_test.dart` (the resolver's Pro reaches the policy through `bootstrap`) and `test/core/cli/simcrux_cli_test.dart` (a licence file's Enterprise reaches the policy in the standalone binary) (`Coverage: AUTOMATED — flutter test`).

### 5.6 Web dashboard (read-only static export)

**What it does.** Builds a Flutter Web bundle that renders the
read-only dashboard for a single regression's `simcrux-results.json`
(or `results.ndjson`). Hosted as a static site — GitHub Pages, S3,
nginx, any HTTP server. The desktop build never opens; the web app
fetches the JSON next to the served `index.html` (or from a
`?results=<url>` query parameter for deep-linkable runs).

**Components.**

- `lib/main_web.dart` — entry point; `flutter build web --target
  lib/main_web.dart` produces the bundle.
- `simcrux export-dashboard <out-dir>` — CLI subcommand that writes
  `simcrux-results.json` and (with `--web-bundle <dir>`) copies the
  pre-built bundle alongside.
- `.github/workflows/web-deploy.yml` — `workflow_dispatch`-only
  pipeline that publishes to GitHub Pages with the
  `dashboard.simcrux.com` `CNAME`.

**Setup.**

1. `flutter build web --target lib/main_web.dart --release`.
2. `simcrux simcrux.yaml --ci` (produces `results.ndjson`).
3. `simcrux export-dashboard ./out --web-bundle ./build/web`.
4. Serve `./out/` from any static host.

**Expected behavior.**

- Opening the served URL renders the read-only dashboard with the
  exported results table, filter chips, inspector dialog, and
  status-bar summary.
- The locale follows the browser's language preference (en / zh_CN /
  zh / ja / ko).
- Adding `?results=<absolute-url>` to the URL fetches a remote
  document instead of the bundled one.
- Auto-reload, file watcher, settings, scheduler, and diagnostics
  surfaces do not render — the web build is read-only by design.

**Edge cases.**

- Empty document: empty-state widget rendered with the
  `webDashboardEmpty*` strings.
- Fetch failure: error message via the `webDashboardLoadFailed`
  string.
- NDJSON-only sites: `WebFetchResultsLoader` automatically falls
  back to `results.ndjson` when `simcrux-results.json` 404s.
- No CXP in the browser: `lib/main_web.dart`'s import closure reaches
  neither `crux_cxp` nor SimCrux's CXP providers (whose manifest-directory
  resolver throws on web), and `cxpDiscoverySupportedProvider` is false on
  web so the desktop entrypoint run in a browser never resolves it
  (`test/web/web_entrypoint_import_closure_test.dart`,
  `cxp_discovery_provider_test.dart`).

**Automation Assessment.** `Coverage: AUTOMATED — flutter test +
flutter build web smoke job` (`test/web/` covers the document
decoder, dashboard widgets, and locale sweep;
`.github/workflows/web-deploy.yml` smoke-tests `build/web/` end-to-end
on dispatch). End-to-end "deploy then load in a browser" remains
`Coverage: MANUAL` until the hosted `dashboard.simcrux.com`
infrastructure is wired up.

### 5.7 Composite pass/fail detector UI

**What it does.** Lets the user define **named reusable detectors** in
Settings → Detectors and reference them from `simcrux.yaml`
`pass_fail:` blocks via `{type: use, name: <name>}`. The visual
builder is a recursive tree editor: each node picks a kind via a
chip row (`exit_code` / `string_match` / `regex` / `uvm_report` /
`composite` / `use`) and surfaces per-kind fields. Composite nodes
nest the same editor for every child.

**Setup.**

1. Open Settings → Detectors.
2. Click **Add detector…**, give it a name (e.g. `strict-uvm`), pick
   `UVM report`, set `fatal_threshold: 0` and `error_threshold: 0`.
3. Save.
4. In your `simcrux.yaml`:

```yaml
defaults:
  pass_fail:
    type: use
    name: strict-uvm
```

**Expected behavior.**

- The detector renders in the Settings → Detectors list with its
  kind summary; clicking the pencil reopens the editor; clicking
  the trash deletes it.
- A `simcrux.yaml` referencing a known name resolves transparently
  — the loader expands `use: <name>` into the underlying tree.
- An unknown name produces a structured `ConfigLoaderError`
  (`unknown reusable detector "X"`).
- Cycles (`a` references `b` references `a`) produce a structured
  cycle-detected error before runtime.
- Existing `simcrux.yaml` files using inline detector definitions
  continue to work unchanged — `use:` is purely additive.

**Edge cases.**

- Renaming a detector removes the old key and writes the new one in
  the same `save()`.
- Empty name field shows a `Name is required` validation error.
- The `use` editor surfaces a dropdown of existing names (excluding
  the detector being edited) when at least one other detector is
  defined; falls back to a free-text field otherwise.

**Automation Assessment.** `Coverage: AUTOMATED — flutter test`
(`pass_fail_config_codec_test.dart`, `config_loader_use_detector_test.dart`,
`settings_detectors_section_test.dart`).

### 5.8 Mixed-language designs (Verilog + VHDL routing)

**What it does (plain language).** Real HDL projects routinely mix
Verilog/SystemVerilog and VHDL — for instance, a CPU core in
SystemVerilog with a legacy VHDL DRAM controller wrapper. SimCrux's
config-load path validates that each test's source list is compatible
with its configured simulator, surfaces a clear actionable error when
it isn't, and routes Cocotb-wrapped tests to the right
`TOPLEVEL_LANG` automatically based on the dominant source language.

**Schema additions.** `sources:` accepts both legacy bare strings and an
object form:

```yaml
sources:
  - rtl/cpu.v
  - { path: rtl/legacy.txt, language: verilog }
  - { path: rtl/auto.v, language: auto }     # explicit no-override
```

Recognized `language:` values: `auto`, `verilog`, `systemverilog` (or
`system_verilog` / `sv`), `vhdl` (or `vhd`), `python`. Unknown values
raise a structured config-load error.

**Simulator language catalog (open-core).**

| Simulator | Languages admitted |
|---|---|
| `icarus` | Verilog, SystemVerilog |
| `verilator` | Verilog, SystemVerilog |
| `ghdl` | VHDL |
| `cocotb` | Verilog **and** SystemVerilog **and** VHDL **and** Python |

**Setup.** Open the mixed-language fixture at
`test/fixtures/projects/mixed_language/` (Verilog testbench + VHDL
companion package + Cocotb Python testbench) and run:

```
flutter test test/services/config/config_loader_mixed_language_test.dart
flutter test test/services/config/mixed_language_validator_test.dart
flutter test test/services/simulator/cocotb_driver_test.dart
flutter test test/integration/fixture_pipeline_test.dart
```

**Step-by-step expected behavior.**

- The mixed-language fixture loads through `ConfigLoader().load()`
  with no errors and produces a single suite with one test whose
  `simulator` is `cocotb`.
- Edit the fixture's `simulator: cocotb` to `simulator: icarus` and
  re-load: `ConfigLoader().load()` throws a `ConfigLoaderException`
  whose single error message names the offending VHDL source, the
  detected language ("VHDL"), the configured simulator (`icarus`), and
  the candidate simulators (`ghdl`, `cocotb`).
- Run the Cocotb driver unit tests: `TOPLEVEL_LANG=verilog` is auto-
  derived for a `.v`-dominant source list, `TOPLEVEL_LANG=vhdl` for a
  `.vhd`-dominant list. `parameters.TOPLEVEL_LANG: vhdl` overrides
  auto-derivation regardless of source mix. A pure-Python source list
  emits no `TOPLEVEL_LANG=` arg.

**Edge cases.**

- Per-source `language: auto` is equivalent to a bare string and stores
  no override on the `TestSpec.sourceLanguages` map.
- Per-source `language:` overrides are merged across suite-level and
  test-level `sources:` lists; later wins (mirrors the existing
  defines/sources merge semantics).
- Sources with an unrecognized extension and no explicit `language:`
  override are skipped by the mixed-language validator (the simulator
  itself will reject them at compile time if it cannot parse them).
- The validator runs *after* filelist (`.f`) expansion so files
  brought in by a filelist participate in the language check.

**Automation Assessment.** `Coverage: AUTOMATED — flutter test`
(`hdl_language_detector_test.dart`,
`mixed_language_validator_test.dart`,
`config_loader_mixed_language_test.dart`,
`cocotb_driver_test.dart::CocotbDriver — TOPLEVEL_LANG routing`,
`fixture_pipeline_test.dart::mixed-language fixture loads through ConfigLoader`).

### 5.9 FuseSoC `.core` import

**What it does (plain language).** Engineers coming to SimCrux from
FuseSoC drop a CAPI2 `.core` file into the importer (CLI flag, command
palette, or Welcome screen button); SimCrux writes a `simcrux.yaml`
next to it and surfaces any features that didn't translate cleanly as
non-fatal warnings. SimCrux reads but never writes CAPI2 — round-trip
is not a goal. The migration is one-way; the native YAML is the
canonical surface afterwards.

**Setup.** Open `test/fixtures/fusesoc/` — three committed `.core`
files exercise the importer:

- `simple.core` — single target, one fileset, vlogparam — clean import,
  zero warnings.
- `multi_target.core` — three targets routed to `icarus`, `verilator`,
  `ghdl`; one "default" packaging target without `toplevel:` (silently
  skipped); vlogparam + vlogdefine routing.
- `unsupported.core` — every "warn + continue" path: `vpi`, `generators`,
  `scripts`, vendor tool, file-typed parameter, unknown parameter,
  non-HDL `file_type`, include-file demotion, unknown fileset.

**Step-by-step expected behavior.**

- CLI: `simcrux --import-fusesoc test/fixtures/fusesoc/simple.core` writes
  `simplesimcrux.yaml` into `test/fixtures/fusesoc/`, prints
  `simcrux: wrote <path>` to stdout, and exits 0 with zero stderr lines.
- CLI: `simcrux --import-fusesoc test/fixtures/fusesoc/unsupported.core`
  writes the file, then prints one stderr line per warning code, and
  still exits 0 — warnings are non-fatal.
- GUI: Welcome screen `Import FuseSoC .core File…` opens the file
  picker filtered to `.core`. Picking a file produces a snackbar with
  either `Imported <filename>` or `Imported <filename> with N
  warning(s)`. The snackbar's "Open in SimCrux" action loads the
  synthesized YAML as the active project.
- The header of every synthesized `simcrux.yaml` carries
  `# Generated by SimCrux FuseSoC importer from <basename>.`, the
  source path, and the full warning list inline as `# [code] message`
  lines.

**Edge cases / negative paths.**

- A file without `CAPI=2:` as its first non-blank line: importer
  throws `FuseSoCImportException`; CLI exits 2; GUI shows
  `FuseSoC import failed: …` snackbar.
- An empty `targets:` block: same exit-2 behavior.
- A target whose only declared tool is `modelsim` / `questa` / `xsim`:
  warning logged (`unsupported_tool`), simulator falls back to `icarus`,
  import succeeds.
- `parameters.<n>` with `datatype: file`: warning logged
  (`complex_parameter`), parameter silently skipped, import succeeds.

**Schema-level validation.** The synthesized `simcrux.yaml` is
round-tripped through `ConfigLoader().parse()` by the integration
suite — every fixture's emit + parse cycle succeeds.

**Automation Assessment.** `Coverage: AUTOMATED — flutter test`
(`fusesoc_importer_test.dart` exercises 18 paths;
`fusesoc_fixture_test.dart` covers all three committed `.core`
fixtures + a write-to-disk roundtrip;
`cli_arg_parser_test.dart::--import-fusesoc is captured` covers the
CLI flag).

## 6. Workspace + Multi-Tab + Split-Pane

Open-core adoption of the `crux_workspace` cross-suite package. The app's `/`
route is the workspace shell — there is no Welcome screen, the
per-tab `.simcrux-session` becomes an *export* format under the
workspace model, and the workspace document
(`workspace.json` under app support dir) auto-saves on every
mutation.

### 6.1 Empty-canvas state

**What it covers.** The workspace startup state when the
workspace has zero tabs.

**Setup.** Fresh install (or delete
`{appSupportDir}/workspace.json` before launch). No CLI args.

**Expected behavior.**
- The window opens to the SimCrux empty-canvas card centred in the
  scaffold body — SimCrux headline + subtitle.
- Recent-configs section either renders the localized
  "No recent configs yet." placeholder or a list of recent project
  paths from `AppSettings.recentProjectPaths`.
- Four primary actions: Open Config… / Open Session… /
  Open Workspace… / New Config.
- No tab bar, no inspector pane.
- App settings + diagnostics surfaces (when enabled in debug) remain
  reachable.

**Edge cases.**
- After opening a config from the file picker, the empty-canvas
  state is replaced by the tab bar + the loaded dashboard.
- "New Config" opens a tab with an empty `configPath`; that tab's
  body renders the `projectScreenPlaceholder` instead of the
  dashboard until the user picks a config.

**Automation Assessment.** Widget-test `EmptyCanvasContent` covers
the locale sweep + presence of the four primary actions; the file-
picker / new-tab flows belong in integration tests once the CLI
end-to-end pass is in place.

### 6.2 Multi-tab workspace

**What it covers.** Multiple `simcrux.yaml` configs open as
independent tabs; switching tabs is instant; per-tab state stays
isolated.

**Setup.** `simcrux asimcrux.yaml bsimcrux.yaml csimcrux.yaml`.

**Expected behavior.**
- Three tab chips appear in the workspace tab bar, in CLI argument
  order; the leftmost tab is active and its dashboard is rendered.
- Each tab arms its own regression runner against its own config
  (per-tab `RegressionTabContent` reads the per-tab payload's
  `configPath` and dispatches to its tab's
  `regressionRunnerProvider`).
- Clicking any tab activates it instantly — the active tab's
  `currentRun` stream becomes visible without re-loading the file.
- The `+` button on the tab bar opens an empty new tab (placeholder
  content; "pick a config" prompt).
- Drag a chip left/right to reorder within the same pane.
- Right-click (or long-press) a chip → context menu with Close
  Tab / Close Other Tabs / Close Tabs to the Right; "Move to New
  Window" is rendered disabled with the multi-window-unavailable
  tooltip.
- Closing a tab does not interrupt other tabs' in-flight runs.

**Edge cases.**
- An in-progress regression in tab A keeps running when tab B is
  active. Verify via the active-pane statistics segments of the live
  statistics strip, or by re-activating tab A and watching the
  partial completion count.

Each tab's body mounts `SimcruxIdeLayout`, now a thin adapter over
the cross-suite `crux_ide_layout` package's `CruxIdeLayout`.
SimCrux is the suite's fraction-sizing case:
the test-browser / run-details / log panes' `double` fractions are
projected onto the shared widget as `PaneSize.fraction(...)`. Behavior
is unchanged — fraction sizing, min sizes (160/200/80 px), the four
toggle actions, and visibility-only persistence (no drag-resize size
persistence) all match the pre-migration hand-rolled controller.

**Automation Assessment.** Per-tab provider isolation is unit-
tested under `test/features/workspace/providers/simcrux_tab_overrides_test.dart`;
the `SimcruxIdeLayout` adapter (placeholders, caller-injected builders,
locale sweep) is covered by
`test/features/panel_layout/widgets/simcrux_ide_layout_test.dart`;
end-to-end multi-tab + drag-reorder remains manual until a
gesture-driver integration test layer lands.

### 6.3 Split-pane

**What it covers.** The workspace's PaneHost in dual-pane mode —
View → Split Pane Right (or Cmd/Ctrl+\\) creates a second pane;
tabs can move between panes; each pane retains its own active-tab
pointer.

**Setup.** Multi-tab workspace as in §6.2.

**Expected behavior.**
- Cmd/Ctrl+\\ splits the workspace into two side-by-side panes;
  the active tab moves into the right pane (or the right pane
  opens empty when the source pane had only one tab).
- The active pane is rendered with a subtle border accent so the
  user can see which pane the next file-open / command-palette
  action targets.
- Drag a chip from one pane's tab bar onto the other pane's tab
  bar → the tab moves; the source pane's active tab falls back to
  the prior tab in that pane.
- Command palette → "Close Pane" closes the active pane and
  merges its tabs into the surviving pane.
- Command palette → "Focus Other Pane" toggles the active-pane
  border accent.
- Command palette → "Move Tab to Other Pane" moves the active
  tab without going through drag.

**Edge cases.**
- Closing the last tab in a non-active pane auto-collapses back
  to single-pane.
- Closing the active pane: the surviving pane becomes active and
  inherits the moved tabs.

**Automation Assessment.** Pane-level provider isolation
(per-pane `paneRenderStatsProvider`) is unit-tested under
`test/features/workspace/providers/simcrux_pane_overrides_test.dart`.
The underlying mutation contract — split creates a second pane,
moving a tab reassigns its pane and the emptied source pane
collapses back to single-pane — is driven end-to-end against the
live `workspaceProvider` notifier in
`integration_test/workspace/split_pane_test.dart`
(`Coverage: AUTOMATED — flutter test --tags integration`). The
drag-tab-to-pane gesture itself and the active-pane border accent
remain manual.

### 6.4 Workspace persistence

**What it covers.** Auto-managed `workspace.json` and named
`.simcrux-workspace` documents.

**Setup.** Open multi-tab workspace with a few configs.

**Expected behavior.**
- Closing and re-launching the app restores the exact tab list +
  pane layout + active selection.
- File → Save Workspace As… writes a `.simcrux-workspace` JSON
  document the user can share or commit alongside their project.
- File → Open Workspace… (or `simcrux --workspace <path>`)
  replaces the current workspace with the named document.
- No "unsaved changes?" prompt under any tab/pane mutation — the
  workspace auto-saves continuously (debounced 2s).
- A corrupt `workspace.json` does not crash the app: the package's
  service falls back to `Workspace.empty()`, the user sees the
  empty-canvas state, and the broken document is preserved on
  disk (not deleted) for manual recovery.

**Automation Assessment.**
- `WorkspaceService` round-trip is unit-tested in the package.
- `SimcruxWorkspaceCodec` corrupt-payload recovery is tested in
  `test/features/workspace/services/simcrux_workspace_codec_test.dart`.
- Auto-managed `workspace.json` auto-save + restore is driven
  end-to-end (open tabs → flush the debounced save → re-read
  through a fresh `WorkspaceService`) in
  `integration_test/workspace/restore_round_trip_test.dart`
  (`Coverage: AUTOMATED — flutter test --tags integration`) — this
  approximates "close + restart" (a single Flutter process can't
  literally relaunch itself mid-test).
- The named `.simcrux-workspace` save/reset/open flow (File → Save
  Workspace As… / Open Workspace…) is driven end-to-end against the
  live `saveAs` / `resetWorkspace` / `loadFrom` notifier API in
  `integration_test/workspace/named_workspace_test.dart`
  (`Coverage: AUTOMATED — flutter test --tags integration`).
- The corrupt-`workspace.json` quarantine-and-recover-empty path
  remains manual.

### 6.4a Route-mounted dialogs resolve the ACTIVE TAB, not the root

**What it covers.** The silent failure mode of per-tab scoping. A
dialog route is a child of the Navigator, and the Navigator sits
**above** the per-tab `UncontrolledProviderScope` that
`simcruxTabOverrides` binds. So a `showDialog` builder that does not
re-bind the container hands the dialog the **root** container, where
`resultStoreProvider` is null and every per-tab derivation
(`fullInspectorLogProvider`, `dashboardRowsProvider`,
`selectedTestProvider`, …) resolves to its empty value. No exception,
no log line — the dialog just renders an empty state.

Fixed 2026-07-21 in `LogViewerDialog.show`, found by crux-shared's
`route_mounted_scope_leak_test` static guard (the same defect class the
guard caught in NetCrux). Before the fix, **Open full log** rendered "No
log output" over an inspector that was visibly streaming lines, and
search / jump-to-line / Copy all operated on an empty buffer.

**Setup.** Open a `simcrux.yaml` and run a regression that produces
log output. Select a test in the dashboard so the inspector populates.

**Expected behavior.**
- Inspector → **Open full log** shows the same lines the inspector
  tail is showing, not the "No log output" empty state.
- Search finds matches, the `n / m` match counter is non-zero,
  jump-to-line scrolls, and **Copy** puts the full log on the
  clipboard.
- With two tabs each running their own regression, the viewer opened
  from tab B shows tab B's log — tab A's is not blended in and does
  not replace it.

**Edge cases.**
- **Invisible in a single-tab session** for most of this class, because
  root and tab then hold equivalent state. `resultStoreProvider` is the
  exception that made this one visible immediately: nothing ever
  publishes a store at root scope, so the root buffer is *always*
  empty. Other members of the class need two tabs to reproduce.
- A test with genuinely no output still shows "No log output" — that is
  the correct empty state, distinguished by the inspector tail also
  being empty.

**Automation.**

| Check | Automatable? | How |
|---|---|---|
| The viewer binds the launching tab's container | **WIDGET** | `test/features/inspector/dialogs/log_viewer_dialog_test.dart` — "LogViewerDialog.show binds the CALLER tab container". Builds the real two-container shape (root `ProviderContainer` + a child from the app's own `TabContainerManager`, `MaterialApp` at root, the launching button inside the tab scope). Mutation-verified: reverting the fix gives `Found 0 widgets with text "hello from the tab"`. Every *other* test in that file pumps the dialog under one `ProviderScope`, which is why none of them could ever have caught it. |
| No route-mounted widget reads per-tab state unscoped | **STATIC** | crux-shared `packages/crux_workspace/test/static/route_mounted_scope_leak_test.dart`, pointed at this tree. Guards the whole class rather than this one site. Enforced in-repo once the `crux-shared` submodule pin carries `route_mounted_scope_leak_guard.dart`; until then run it by hand: `CRUX_ROUTE_SCOPE_ROOTS=<abs>/simcrux/lib CRUX_ROUTE_SCOPE_SEED_OVERRIDES=<abs>/simcrux/lib/features/workspace/providers/simcrux_tab_overrides.dart#simcruxTabOverrides flutter test test/static/route_mounted_scope_leak_test.dart` from `crux-shared/packages/crux_workspace`. |
| Cross-tab isolation end-to-end | **MANUAL** | Needs two configs, two tabs, two runs. |

### 6.5 Tab export as `.simcrux-session`

**What it covers.** `.simcrux-session` becomes an export format
for sharing a single tab's UI state (config + selection + filters
+ sort + view mode) with a teammate.

**Setup.** Multi-tab workspace; active tab has filter chips set
and a test selected in the inspector.

**Expected behavior.**
- File → Export Tab as Session… writes a `.simcrux-session` file
  the user can drop into another SimCrux install.
- Opening a `.simcrux-session` adds a new tab to the current
  workspace.

**Status.** The bare File→Open path for `.simcrux-session` opens
the underlying config; lifting selection / filter chips / sort
column from the session document into the per-tab payload is not
implemented.

**Automation Assessment.** Manual end-to-end until the
session-load tab-aware payload extraction lands.

### 6.6 CLI behavior

**What it covers.** The workspace CLI surface (multi-positional
configs + `--session` + `--workspace`).

**Setup.** Build the simcrux binary; run from a shell.

**Expected behavior.**
- `simcrux` (no args) → empty-canvas state.
- `simcrux a.yaml` → workspace with one tab.
- `simcrux a.yaml b.yaml c.yaml` → workspace with three tabs in
  argv order, leftmost active.
- `simcrux --workspace team.simcrux-workspace` → loads the named
  workspace before any positional configs are appended.
- `simcrux --workspace team.simcrux-workspace extra.yaml` → loads
  the workspace, then opens `extra.yaml` as an additional tab.
- `simcrux --session debug.simcrux-session` → opens the session
  as a single tab.
- `--ci` and `--json` continue to act on the first positional
  config only (CI is single-project by design).
- `--help` lists `--workspace` alongside the other options.
- **The desktop executable exits after headless work.** `SimCrux --ci proj.yaml`,
  `--help`, the imports and `export-dashboard` end the process with their exit
  code (`runSimcrux` flushes and exits: a desktop runner otherwise keeps its
  window and event loop alive after `main` returns). An unrecognized argument
  prints to stderr and exits `2` without a window. **Manual check** (on a
  runner without a user session, since the window would appear otherwise):
  `.../SimCrux --ci proj.yaml; echo $?` returns promptly with 0/1;
  `.../SimCrux --bogus; echo $?` prints the error and `2`.
  (`Coverage: AUTOMATED — test/app_ci_driver_injection_test.dart`)
- **License tier under `--ci`** (both the app's `--ci` and the standalone
  binary). The project loads at the tier resolved from `--license-file`, then
  `SIMCRUX_LICENSE_FILE`, then the policy file's `license` key, validated
  offline. Expected: a valid Pro license prints `simcrux: license: Pro from …`
  on stderr and, with `--dart-define=BETA_PERIOD=false`, a `seeds: [1, 2]`
  test runs twice; no license prints nothing and runs it once; a garbage file
  prints `… was not accepted (malformed …); running as Open Core`; a
  `--license-file` that does not exist exits `2` before any test runs. A
  machine file resolves to its tier when the suite's shared
  `crux/license/install.fingerprint` names the fingerprint it was issued for
  (or, before that file exists, when the legacy `simcrux.fingerprint` does —
  its value is adopted into the shared file), and prints `… (wrongMachine: …);
  running as Open Core` when it names another one or none can be read. A build
  agent with neither file gets one minted into the shared file.
  **Manual check:** `simcrux proj.yaml --ci --license-file missing.lic; echo $?`
  → error naming the path, `2`. (`Coverage: AUTOMATED —
  test/services/license/headless_license_tier_test.dart,
  test/core/cli/simcrux_cli_test.dart, test/app_ci_driver_injection_test.dart`)
- `type: use` under `--ci` fails the load (exit `2`) with a message saying
  `--ci` never reads the app's detector library.

**Automation Assessment.** CLI parser surface is unit-tested
under `test/core/cli/cli_arg_parser_test.dart`. The
bootstrap-side multi-config-open flow (`simcrux a.yaml b.yaml
c.yaml` → three tabs, one per file, tab structure asserted
against the live workspace) is driven end-to-end in
`integration_test/tabs/cli_multi_config_test.dart`
(`Coverage: AUTOMATED — flutter test --tags integration`).
`--workspace`/`--session` combined with positional configs and
the `--help`/`--ci`/`--json` paths remain manual.

### 6.7 Auto-reload under multi-tab

**What it covers.** Per-tab `AutoReloadNotifier` — a file-change
event in tab A re-runs tab A only.

**Setup.** Multi-tab workspace; Settings → Auto-reload set to
`auto`; each tab references its own source files.

**Expected behavior.**
- Editing a source file referenced by tab A re-runs only tab A.
- Tab B's in-flight or stale-completed regression is untouched.
- Settings change (off / prompt / auto) applies to every tab
  because the cross-suite AutoReloadMode lives on the root-scoped
  `appSettingsProvider`.
- A broken-YAML load error in tab A renders its diagnostic banner
  in tab A only; opening or reloading tab B neither shows A's
  banner nor clears it (`configLoadErrorProvider` is per-tab).
- In the Pro overlay's multi-project workspace the same guarantee
  is re-established per project — see the Pro verification guide's
  multi-project workspace section for the two-tab / two-project
  auto-reload scenario.

**Automation Assessment.** Per-tab isolation unit-tested under
`test/features/workspace/providers/per_tab_auto_reload_test.dart`;
config-load-error isolation under
`test/features/workspace/providers/simcrux_tab_overrides_test.dart`;
real file-change behavior is the existing auto-reload
section. The per-tab provider set itself is guarded by the static
scope-leak scanner
(`test/static/per_tab_provider_scope_leak_test.dart`), which
validates the OPEN-CORE effective override list — a root-scoped
provider that reads per-tab state (directly or transitively)
without being listed in `simcruxTabOverrides` fails the suite. The
Pro overlay runs a sibling scanner against the Pro-mode effective
list.

### 6.8 Scheduler concurrency under multi-tab

**What it covers.** How many simulator processes run at once when more
than one tab is running a regression.

**Setup.** Open two or more tabs whose regressions each have more tests than
the per-run concurrency, and run them at the same time.

**Expected behavior.**
- Each run is bounded on its own: an in-app run executes at most 4 tests at
  once, and a `--ci` run at most `--max-parallel` (default 4).
- Each tab has its own `regressionRunnerProvider` notifier and its own run
  state; a run in one tab never surfaces in another.

**Status / known limitation.** There is no process-wide cap. `LocalJobScheduler`
bounds each run with its own `Semaphore`, so N tabs running at once can spawn
up to 4N simulators. A cross-tab pool is not built.

**Automation Assessment.** Per-tab runner isolation is unit-tested in
`test/features/workspace/providers/per_tab_scheduler_isolation_test.dart`.
The combined process count across tabs is `[Coverage: MANUAL]`.

## 7. Cross-Probing & CXP Integration

CXP is the suite-wide cross-product cross-probe protocol shipped in the `crux_cxp` package under `crux-shared` and specified at `https://edacrux.app/cxp`. SimCrux is one of the four reference implementations. The implementation lives entirely in open-core; receivers and the "Debug in WaveCrux" originator both ride the v1 message vocabulary.

**Design constraint — v1 vocabulary only.** v1 CXP does not define a `request_open_waveform` message kind. SimCrux's "Debug in WaveCrux" flow models the waveform-open semantics through `ElementKind.source` with a waveform file extension (`.vcd` / `.fst` / `.ghw` / `.wavecrux`); receivers disambiguate via `SimCruxNameResolver.looksLikeWaveformPath`. The original-design custom messages (`notify_test_failed`, `request_filter_to_test`, `request_filter_to_failures_in`, `request_open_waveform`) are not part of CXP v1 and are not implemented.

### 7.1 CXP server lifecycle

**What it does.** On app launch with `cxpServerEnabled = true` (default), SimCrux binds a `LocalCxpServer` on `127.0.0.1:54325` (the SimCrux slot in the per-product port assignment). Toggling the setting off stops the server cleanly; changing the port restarts it.

**Setup.** Fresh launch with default settings. Other Crux apps optional (the lifecycle is verifiable in isolation).

**Steps & expected behavior.**
1. Open Settings → Remote Control. Confirm "Enable cross-probe (CXP)" is ON and the port reads 54325.
2. Run `lsof -i :54325` (or `netstat -an | grep 54325` on Windows): expect SimCrux listening on `127.0.0.1`.
3. Confirm `simcrux-<pid>-<startedAtMillis>.json` exists in the **suite-shared** manifest directory — `~/Library/Application Support/crux/cxp/peers/` on macOS, `%APPDATA%\crux\cxp\peers\` on Windows, `${XDG_DATA_HOME:-~/.local/share}/crux/cxp/peers/` on Linux (resolved by `sharedCxpManifestDirectory()`; **not** the per-app container, which peers in other apps cannot see). The file content is a JSON object with `identity.product_name = "simcrux"`, `host = 127.0.0.1`, `port = 54325`. Leave the app running > 1 minute and re-`cat` the file: `started_at` refreshes every ~30 s (manifest heartbeat — keeps peers from stale-pruning us at their 5-minute threshold).
4. Toggle the switch off. The lsof entry disappears within ~1s; the manifest file disappears.
5. Toggle on again. New manifest with a fresh `started_at` timestamp.
6. Change the port to 12345 (any free port in 1024–65535). Server rebinds; manifest file's `port` updates.
7. Enter `99999` in the port field → inline error "Enter a port between 1 and 65535." appears; no setting change.

**Automation assessment.** Lifecycle providers unit-tested in `test/features/remote/providers/cxp_server_provider_test.dart`. Discovery covered in `test/services/remote/cxp/simcrux_cxp_discovery_test.dart` and `test/features/remote/providers/cxp_discovery_provider_test.dart`. The socket-level lifecycle (steps 2/4/5: bind on boot, TCP-connectable, stop on disable, restart on re-enable) is end-to-end automated in the live app by `integration_test/remote/cxp_server_lifecycle_test.dart` (macOS; OS-picked port via the `cxpServerFactoryProvider` seam). Manual sign-off remains for the Settings-UI steps (1, 6, 7) and the peer-manifest inspection (3).

### 7.2 Peer discovery + cross-probe panel

**What it does.** SimCrux watches the suite-shared manifest directory, **dials every discovered peer** (the `CxpPeerConnector`; without it nothing opens a CXP socket, so the peer list gated on `connectedPeers` stays empty forever), and surfaces every connected non-simcrux peer in the cross-probe panel. The panel additionally shows a rolling log of the last ~50 cross-probe events (inbound + outbound) and lets the user manually `sendTo(<peer>, NotifySelection)` for the active test.

**Connector-link routing (2026-07-20, crux-shared pin `20b7305`).** Presence (`connectedPeers` showing the peer) is necessary but was not previously sufficient: with two symmetric dialers, a message SimCrux sends via `server.sendTo`/`broadcast` typically travels over the socket the OTHER side's own connector dialed, so the peer only ever observes it arriving on THEIR connector's outbound client link — never on their server's accept loop. `SimCruxCxpDiscoveryService.start()` now passes `server:` to `CxpPeerConnector` so link traffic SimCrux itself dials out on is merged into SimCrux's own `server.inbound`; every other Crux product needs the equivalent wiring on its own side for the round trip to complete (WaveCrux and SimCrux have both landed it as of this pin). Before this fix, `connectedPeers` looked correct while every directed request, ack, and notify_selection gossip arriving over a connector-dialed link was silently dropped — the worst symptom of the 2026-07-19 suite CXP audit (`sendTo`/`dispatch` reporting `true` with nothing actually received on the other end).

**Setup.** SimCrux running. Launch a second Crux peer on the same machine (WaveCrux at 54322, NetCrux at 54323, or LintCrux at 54324 — any build at or past its 2026-07-18 CXP fix; a pre-fix build publishes into its per-app container and cannot be discovered). Open SimCrux's command palette → "Open Cross-Probe Panel" (or Tools menu).

**Steps & expected behavior.**
1. Panel header shows the green status indicator + "Cross-probe running on port 54325".
2. Under the Peers section header, the **Discovery directory** line (monospace) names the suite-shared path from §7.1 step 3 — this is the self-debug surface when peers aren't appearing: inspect that directory's manifests directly. SimCrux's own manifest is in that directory but SimCrux must never be listed as its own peer (self-filter).
3. Connected peers section lists the other Crux peer with its productName + version + host:port + peerId — within ~5 s of both apps running (manifest discovered → symmetric connectors dial → inbound Hello on both servers). Leave both running **> 5 minutes**: the row persists (heartbeat defeats the stale prune).
3a. **Unreachable-peer indicator.** Simulate a peer whose manifest exists but whose server can't be dialed: while the other peer is discovered, block/close its CXP port (e.g. quit only the peer's server while a stale manifest is still on disk, or hand-write a manifest naming a closed port into the discovery directory). Within ~5 s (one dial retry tick) a persistent warning line — amber warning icon + "Couldn't reach <peer>" (product name, or `host:port` when the manifest is gone) — appears directly under the connected-peers list. It clears once the peer becomes reachable (its dial succeeds) or its manifest is removed. When every peer is reachable the indicator renders nothing (no empty box, no header). Confirm the line is localized in each locale (en, zh_CN, zh, ja, ko).
4. Click "Send selection to WaveCrux" (or NetCrux/LintCrux) — a `notify_selection` event with direction "→ out" appears in Recent activity.
5. Trigger an inbound message from the other peer (e.g. tap a signal in WaveCrux to broadcast NotifySelection). Direction "← in" appears in the panel within ~2 scan ticks.
6. Click "Clear" — events buffer empties. Verify the button disables when the buffer is already empty.
7. Quit the other peer's process. Within ~2 scan ticks the peer row disappears from the panel and a "← in: goodbye" event (or silent disconnect) is recorded. Kill it with `kill -9` instead (crash, manifest left behind): the row lingers until ~5 minutes after its last heartbeat, then is pruned and the stale manifest deleted.

**Automation assessment.** Panel widget tests cover empty-state, event rendering, Clear, and the five-locale sweep (`test/features/remote/widgets/cross_probe_panel_test.dart`). The unreachable-peer indicator is pinned in the same file (renders the warning naming the peer product, falls back to `host:port` when the manifest is unknown, hides failures for SimCrux's own product to match the foreign-only peer list, and renders nothing when there are no failures); the provider that feeds it — `cxpDialFailuresProvider` — is covered in `test/features/remote/providers/cxp_discovery_provider_test.dart` (empty when reachable; surfaces a real refused dial to a closed port), and the service getters (`dialFailures` / `lastDialFailures`) in `test/services/remote/cxp/simcrux_cxp_discovery_test.dart` (empty while stopped; records a refused dial). Discovery file-watching covered by integration tests (`simcrux_cxp_discovery_test.dart` injects a foreign manifest into a temp dir and asserts the added/removed event flow). The mutual-connect case — SimCrux + a WaveCrux-style peer sharing one manifest directory ending up mutually CONNECTED — is pinned by `simcrux_cxp_discovery_test.dart` ("SimCrux and a WaveCrux-style peer sharing one … MUTUALLY CONNECTED") and, at the shared-package level, by `crux-shared/packages/crux_cxp/test/conformance/peer_connectivity_test.dart` (shared-dir resolver, heartbeat-vs-stale-prune, two-server mutual connect, retry-until-listening). The connector-link routing fix above is pinned by the same file's "end-to-end product traffic over the connector-dialed link…" test: it stands up a full SimCrux stack alongside a full WaveCrux-style peer stack (server + manifest writer + discovery + connector, not a raw client) and asserts the peer's OWN `server.inbound` receives the request and SimCrux's OWN `server.inbound` receives the ack — presence alone is asserted first and shown insufficient. Manual sign-off needed for the visual presentation and the real multi-process flow (incl. the >5-minute persistence and crash-prune checks).

### 7.3 notify_selection emit on test + source selection

**What it does.** When the user changes the selected test in the dashboard or navigates to a test's source file via the inspector's "Open testbench source" action, SimCrux broadcasts a `NotifySelection` to every subscribed peer.

**Setup.** SimCrux + at least one peer running and connected. Open a project with at least 2 tests; have a `peer` subscribed to `notify_selection` (a WaveCrux or NetCrux instance is fine).

**Steps & expected behavior.**
1. Click test A in the dashboard. The peer receives a `NotifySelection` with `elements[0].kind = test` and `path = <suite>/<name>[+param=value...][+seed=N]`.
2. Click test B. Peer receives a second `NotifySelection`; clicking test B again does NOT re-emit (same-value debounced).
3. Click "Open testbench source" in the inspector. Peer receives a `NotifySelection` with `elements[0].kind = source` and `path = <absolute path to source file>`.
4. Disable CXP in Settings; click test C. Peer receives nothing (subscriber sees no traffic — verified separately under "CXP server lifecycle" above).

**Multi-tab note.** `selectedTestIdProvider` is per-tab, so the root-hosted emitter subscribes to the ACTIVE tab's container (re-attaching when the active tab changes); clicking a test in the visible tab is what broadcasts. Selections mutated in a background tab's scope do not broadcast until that tab is active.

**Automation assessment.** Outbound emitter covered by `test/features/remote/providers/notify_selection_emitter_test.dart` (test selection, source selection, debouncing, disabled-state silence, cross-probe-events recording, and the active-tab-container subscription with a mounted workspace) plus a connector-linked-peer case: a full peer stack (server + manifest writer + discovery + connector) that never sends a manual `Subscribe` still receives the broadcast on its own `server.inbound`, because `CxpPeerConnector` auto-subscribes every link on handshake (crux-shared `fb8be19`, pin `20b7305`) — proving the subscription-and-delivery path works for real products, not only for a raw client that subscribes by hand.

### 7.4 Inbound request_highlight handler — every ElementKind

**What it does.** SimCrux receives a `RequestHighlight` and dispatches to the appropriate per-feature provider, replying with a `RequestHighlightAck` that carries `honored: true/false` + an optional reason.

**Setup.** SimCrux running with a project loaded. A peer connected (any `LocalCxpClient` will do).

**Steps & expected behavior.**

Every mutation targets the ACTIVE tab's provider scope (the handler resolves the active tab container; per-tab providers at root are dormant), so the selection / filter change is visible in the tab the user is looking at.

| ElementKind | Peer sends | SimCrux expected behavior | Ack |
|---|---|---|---|
| `test` | `path = suiteA/testB` (exists in the loaded config) | Inspector pane focuses on `suiteA/testB`; the dashboard row scrolls into view (or stays visible) | honored: true |
| `test` | `path = suiteA/nope` (not in the loaded config), or any test id while no config is loaded | No state change — honest ack instead of a silent-no-op success | honored: false, reason mentions "not found" |
| `source` | `path = /abs/rtl/alu.sv` | Inspector source-navigation surface records the explicit source selection; the notify_selection emitter re-broadcasts | honored: true |
| `signal` | `path = top.cpu.alu.sum[31:0]` | Dashboard filter substring updates to `sum` | honored: true |
| `net` | `path = top.x_net` | Filter substring updates to `x_net` | honored: true |
| `port` | `path = top.cpu.clk` | Filter substring updates to `clk` | honored: true |
| `instance` | `path = top.cpu.alu` | Filter substring updates to `alu` | honored: true |
| `scope` | `path = top.cpu` | Filter substring updates to `cpu` | honored: true |
| `breakpoint` | any | No state change | honored: false, reason mentions "breakpoint editor" |
| `marker` | any | No state change | honored: false, reason mentions "marker" |
| `rule` | any | No state change | honored: false, reason mentions "rule" |

**Automation assessment.** All ElementKind cases plus the honest-ack (`test` not found / no config) paths unit-covered in `test/features/remote/providers/inbound_request_handler_test.dart`; the active-tab routing (selection/filter land in the ACTIVE tab container, root instances untouched) is covered by the same file's workspace-mounted group; the integration suite in `test/integration/remote/simcrux_cxp_conformance_test.dart` drives the wire end-to-end. The same workspace-mounted group also carries a connector-linked-peer variant: a full peer product stack (not a raw client) originates the `RequestHighlight` over a connector-dialed link, the active tab's `selectedTestIdProvider` still updates, and — the part presence checks cannot see — the peer's own `server.inbound` genuinely receives SimCrux's ack back. Manual sign-off optional unless you suspect a regression.

### 7.5 Inbound request_open_source handler

**What it does.** SimCrux receives a `RequestOpenSource` from a peer, shells through the `EditorLauncher` to the user's configured editor, and acks honored:true on success.

**Setup.** Settings → Editors → ensure the editor command template is valid (e.g. `code --goto {file}:{line}:{column}`). Peer connected.

**Steps & expected behavior.**
1. Peer sends `RequestOpenSource(filePath: '/abs/rtl/alu.sv', line: 42, column: 8)`. VS Code (or the configured editor) opens at line 42 column 8.
2. Ack carries `honored: true, inReplyTo: <messageId>`.
3. Misconfigure the editor template to a malformed string and resend. Ack carries `honored: false, reason: <reason>` and no editor process opens.
4. **Containment (CXP §11).** Step 1 opens only because `/abs` is a directory the user has opened. The rule's roots are the directory of every tab's `simcrux.yaml`, of every recent project, and the directories the active config's tests name (each source up to its first glob segment, and each include directory). Send `RequestOpenSource(filePath: '/etc/passwd', line: 1)`: the ack carries `honored: false, reason: "file_path is outside the directories open in this session"`, and no editor opens. With no config open and no recent projects, every path is refused (`"no directory is open in this session"`). A relative or option-shaped path (`--help`) is refused as `"file_path must be an absolute path"`. No reason ever repeats the path.
5. The same rule applies to `request_open_artifact` (the recorded source a peer's `design_id` resolves to, or the path hint when nothing is recorded) and to the `crux.design_id` fallback a `request_highlight` takes when it cannot be honoured locally: a file outside the opened directories is never handed to the editor.
6. **Peer auth.** A peer must present, in its `hello`, the token SimCrux published in its discovery manifest; a suite app reads it from the manifest automatically. A hand-rolled peer that omits it is refused `unauthorized` before any request is dispatched.

**Automation assessment.** Both paths covered by stub-launcher tests in `inbound_request_handler_test.dart` and `simcrux_cxp_conformance_test.dart`. Containment: the "CXP §11 containment" group in `inbound_request_handler_test.dart` (the handler's own check on open-source, open-artifact record and hint, and the highlight fallback; mutation-verified), the conformance suite's outside-path case (refused at the server, built by the production factory), `simcrux_cxp_server_test.dart` (refused before `inbound`), and `cxp_workspace_link_test.dart` (the roots, and that the store and the server factory carry the one rule). Peer auth: `simcrux_cxp_server_test.dart` and the conformance suite. Manual sign-off recommended for the actual editor handoff (which the stub cannot exercise), and for a real cross-probe into a design SimCrux has never opened (refused).

### 7.6 "Debug in WaveCrux" originator flow

**The marquee cross-probe flow.** From the inspector, clicking "Debug in WaveCrux" dispatches the active test's captured waveform file to a connected WaveCrux peer via v1 vocabulary.

**Setup.** Open a project, run a regression that produces a `.vcd` or `.fst` for at least one test. Launch WaveCrux on the same machine (CXP server enabled on port 54322). Open SimCrux's cross-probe panel and confirm WaveCrux appears in the peer list.

**Steps & expected behavior.**
1. Click the test result in the dashboard. The "Debug in WaveCrux" button in the inspector becomes enabled (assuming the test captured a waveform).
2. Click the button. Snackbar: "Sent to WaveCrux (wavecrux-<pid>-<ts>)."
3. WaveCrux opens the waveform file and (optionally) pre-loads the suggested signals.
4. The cross-probe panel records two outbound events: a `NotifySelection` (carrying the `simcrux.suggested_signals` metadata) and a `RequestHighlight` (the imperative open).

**Edge cases.**
- No WaveCrux connected → snackbar: "WaveCrux is not connected. Launch WaveCrux on this machine and try again." No outbound events recorded.
- CXP disabled in settings → snackbar: "Cross-probe is disabled. Enable it in Settings → Remote Control to use Debug in WaveCrux." No outbound events.
- Test has no captured waveform → button enabled but click produces snackbar: "This test did not capture a waveform. Re-run with waveform capture enabled."

**Tier-gate scenarios.** Open-core feature; no tier gating applies. Unrestricted regardless of `kBetaPeriod`.

**Automation assessment.** Eight cases covered by `test/features/remote/services/debug_in_wavecrux_dispatcher_test.dart` (including the metadata round-trip and the four outcome branches), plus a connector-linked-peer case standing up a full WaveCrux-style peer stack (server + manifest writer + discovery + connector, sharing a manifest directory with SimCrux's own real discovery service — not a raw client dialing directly into SimCrux's server): it asserts the peer's OWN `server.inbound` genuinely receives the `RequestHighlight` and SimCrux's OWN `server.inbound` genuinely receives the peer's ack back. This is the regression pin for delivery being assumed rather than observed — `dispatch()` returning `outcome: dispatched` is not proof of delivery; this case fails on the `dispatched: true` return value alone and only passes when the peer's product-level stream actually observes the frame. Manual sign-off required for the end-to-end WaveCrux-actually-opens-the-waveform flow.

### 7.7 Error paths

- **Port-in-use.** Set the CXP port to an occupied port (e.g. 22). Settings save succeeds (the validator only checks the range); the lifecycle controller's `server.start()` throws, the AsyncValue surfaces as `AsyncError`, and the cross-probe panel header shows "Cross-probe is disabled." (Future polish: dedicated "port in use" status — open issue.)
- **Malformed inbound messages.** Peers that send unknown `kind` values receive an `ErrorResponse` with `code = unknown_kind` (handled by `LocalCxpServer` before the message reaches SimCrux's handlers).
- **Non-Hello first message.** Peers that send anything before `Hello` receive `code = handshake_required` (same — `LocalCxpServer` enforces).

### 7.8 Sign-off bullet group

See `verification/VERIFICATION_CHECKLIST.md` "Cross-Probing & CXP Integration".

## 8. Pro re-run + heatmap extension points (open-core)

These open-core seams ship behind the Pro re-run and seed-failure-heatmap UI. They are exercised by the Pro overlay's verification entries; the open-core-only checks here ensure the seam contracts remain stable when the overlay is absent.

### 8.1 `RegressionRunner.submitSpecs` — partial re-run path

**Setup.** A loaded project with at least two suites and three tests; one test passes, one fails, one is parameterized.

**Steps.**

1. Run the regression to completion.
2. Programmatically invoke `regressionRunnerProvider.notifier.submitSpecs([fail_spec])`.
3. Confirm the dashboard now shows only the single re-submitted spec.
4. Confirm `activeConfigProvider` still holds the original project (it was not overwritten).
5. Invoke `submitSpecs(<empty list>)`; confirm no new run is dispatched.
6. Close the project (so `activeConfigProvider == null`); invoke `submitSpecs([fail_spec])`; confirm silent no-op.

**Coverage.** Unit-tested in `test/features/dashboard/providers/regression_runner_test.dart`. No manual verification needed; this entry exists to document the open-core surface for Pro-overlay reviewers.

### 8.2 Auto-tracking with `ReRunQueryService`

**Setup.** Same as 8.1.

**Steps.**

1. After running the regression, read `reRunQueryServiceProvider` and assert its `trackedSpecs` inventory contains every submitted spec.
2. Run `submitSpecs([new_spec])` for a spec not in the original project; confirm the new spec joins the inventory.

**Coverage.** Unit-tested in the same file. The Pro re-run UI consumes this inventory transparently — no overlay change is required when adding new submission paths.

### 8.3 `extraDashboardActionsProvider` open-core default

**Steps.**

1. Build a fresh `ProviderContainer` with no overrides.
2. Read `extraDashboardActionsProvider`; confirm the returned list is empty.
3. Render `DashboardView` and confirm only the general toolbar buttons appear (no Pro chrome) above the filter chrome.
4. Override the provider with a `[SizedBox(width: 12)]` list; confirm the `SimcruxToolbar` now renders the supplied widget alongside the general buttons (the provider's widgets are folded into the toolbar, after a divider).

**Coverage.** Unit-tested in `test/features/dashboard/providers/dashboard_actions_extensions_test.dart` + `test/features/dashboard/widgets/simcrux_toolbar_test.dart` (fold-in case). Pro overlay verification covers the populated case end-to-end.

### 8.3.1 Action toolbar — tier-1 action surface

**What it does.** A `SimcruxToolbar` sits at the top of the regression dashboard, completing the three-tier action-discovery model (toolbar + native menu bar + command palette) the suite apps share. SimCrux previously shipped only the menu bar + palette plus the Pro `DashboardActionsRow`. The toolbar carries a curated **open-core** button set — **Run** (`runRegression`), **Stop** (`cancelRegression`), **Re-run Selected** (`reRunSelected`), **Search** (`openSearch`) — and **folds in** the Pro `extraDashboardActionsProvider` widgets (Re-run Failures, Compare to Baseline, seed heatmap) after a divider, replacing the standalone `DashboardActionsRow`. General buttons dispatch through `Actions.maybeInvoke<SimcruxActionIntent>` — the same `ShortcutManagerWidget` handler path the menu bar and palette use. Tooltips reuse each action's localized label (no toolbar-specific ARB keys).

**Steps.**

1. Open a config so the dashboard renders. Confirm the toolbar shows Run / Stop / Re-run Selected / Search at the top.
2. Hover each button; confirm the tooltip shows the action's localized name (matching the menu-bar label).
3. Click **Run**; confirm the regression starts (same as the Run menu item / `F5`). Click **Stop**; confirm it cancels.
4. In a Pro build, confirm the Pro action buttons (Re-run Failures, Compare to Baseline) appear to the right of the general buttons, after a divider — and that an open-core build shows only the four general buttons.
5. Narrow the window; confirm the toolbar scrolls horizontally rather than clipping.

**Coverage.** `[Coverage: WIDGET]` — `test/features/dashboard/widgets/simcrux_toolbar_test.dart` (button set, per-button `SimcruxActionIntent` dispatch via an `Actions` capture, Pro fold-in via `extraDashboardActionsProvider` override, 4-locale sweep). End-to-end "Run starts a regression" is `[Coverage: MANUAL]` (step 3) — the dispatch wiring is unit-covered, the downstream run has its own entries.

### 8.3.2 Action-handler dispatch — Re-run Selected, Close All Tabs, and no-project feedback

**What it does.** `SimcruxActionHandlers.build` is the single dispatch table behind all three action surfaces (keyboard, native menu bar, command palette). Three behaviours are verified here.

**Re-run Selected runs exactly one test.** `reRunSelected` submits the selected `TestSpec` through `RegressionRunner.submitSpecs`, which runs precisely the specs it is handed and leaves `activeConfigProvider` untouched. The earlier implementation narrowed the *config* — shrinking only the selected test's suite — and dispatched `start()`, which flattens every suite; on a multi-suite project that ran the selected test **plus every test of every other suite** at concurrency 1, and republished the narrowed config so the next plain "Run Regression" silently ran a subset until the project was reloaded.

**Close All Tabs confirms first.** `closeAllTabs` is the open-core tab-closing capability: no project registry, no pinning, no recents — it closes every open workspace tab and nothing else. The action is destructive and has no undo, so it opens a confirmation dialog (`showConfirmDialog`) before touching anything. Cancelling — or dismissing via the barrier — changes nothing. Confirming closes every tab.

Its registry-aware sibling `closeAllProjects` ("close all **except pinned**") is a Pro-tier action — see the tier classification below — and is verified in the Pro overlay's guide.

**Project-scoped actions always give feedback.** Run / Stop / Re-run Selected / Close Project / Close All Tabs fired with no project open show `snackNoProjectOpen` instead of silently doing nothing; Re-run Selected with a project but no selection shows `snackNoTestSelected`. A silent Run or Stop click reads as a broken app.

**Snack honesty vs. the tier badge.** The snack an action shows when its extension-point opener is absent is chosen from the action's own `requiredTier`, so it can never contradict the badge the palette and menu bar render for the same action: Pro-tier actions say "requires SimCrux Pro"; an open-core-tier action whose opener is absent would say `snackActionUnavailableInThisBuild`, making no tier claim (no action carries that classification today — every extension-point seam in SimCrux is Pro-tier). Deferred actions with no activating tier keep the separate `snackActionNotAvailableYet`.

**Tier classification.** `switchProject`, `reopenRecentProject`, and `closeAllProjects` are `LicenseTier.pro` — the suite-coherent line is that **the multi-project registry is a Pro feature in every product that has one**. Open-core ships `NoopProjectRegistry`: one project, recents cleared by construction, pinning a silent no-op. None of the three can do its advertised job under that default, so each routes through a null extension-point opener and surfaces "requires SimCrux Pro" — matching the PRO badge the palette and menu bar render from `requiredTier`.

`closeAllTabs` is the open-core action that carries the capability `closeAllProjects` was really providing in an open-core build (closing every workspace tab), under its own honest name, at `LicenseTier.openCore`, with the same confirmation dialog. Free users lose nothing.

`openProject` and `closeProject` stay open-core: both work standalone under `NoopProjectRegistry`.

**Steps.**

1. Open a project whose `simcrux.yaml` declares **two or more suites**. Run the regression once so results populate.
2. Select a single test in one suite, then fire **Re-run Selected** (toolbar Replay button, File menu, or the shortcut). Confirm the run that starts contains **exactly that one test** — not the other suites' tests.
3. Without reloading the project, fire **Run Regression**. Confirm it runs the **full** config again (the re-run must not have narrowed it).
   Repeat steps 2–3 with the Details panel's **Re-run** and **Re-run with waveform** buttons: each runs exactly the selected test (the second with `capture: always`) through the same `submitSpecs` path (`Coverage: AUTOMATED — inspector_actions_test.dart`, two-suite config).
4. With no project open, click Run, then Stop, then Re-run Selected, then Close Project, then Close All Tabs. Confirm each shows the "no project is open" snack rather than doing nothing.
5. With a project open but no row selected, fire Re-run Selected. Confirm the "no test is selected" snack.
6. With two tabs open, fire **Close All Tabs**. Confirm a confirmation dialog appears. Cancel it; confirm both tabs survive. Fire it again and confirm; confirm every tab closes.
7. In an open-core build, open the command palette and confirm **Switch Project**, **Reopen Recent Project**, and **Close All Projects** each render a PRO badge, and that **Close All Tabs** renders none. Fire each of the three Pro entries; confirm each shows "requires SimCrux Pro" — consistent with the badge beside it.
8. Repeat step 6's dialog in each locale (en, zh_CN, zh, ja, ko); confirm title, body, and both buttons are translated.

**Edge cases.**

- Dismissing the close-all dialog with the barrier (click outside) must behave as Cancel, never as Confirm.
- Re-run Selected on a test whose spec is missing from the loaded config is a no-op with the "no test is selected" snack — never a full-config run.

**Coverage.** `[Coverage: WIDGET]` — `test/core/shortcuts/simcrux_action_handlers_test.dart`: a table test pinned against `SimcruxAction.values` (a new action fails the test until its dispatch behaviour is declared), plus per-group behavioural tests for snack selection, the no-project snacks (4-locale sweep), the single-pane `closePane` / `moveTabToOtherPane` guards, the registry info snacks, the close-all confirm/cancel paths, and the multi-suite Re-run Selected regression (exactly one test runs; `activeConfigProvider` unchanged). `test/features/dialogs/confirm_dialog_test.dart` covers the dialog primitive including barrier dismissal and the 4-locale sweep. Step 3's cross-run "the config is still whole" check is also asserted in the widget test; `[Coverage: MANUAL]` remains for the real-simulator end-to-end.

### 8.4 `seedFailureHeatmapOpenerProvider` open-core default

**Steps.**

1. Build a fresh `ProviderContainer`; read `seedFailureHeatmapOpenerProvider`; confirm the value is `null`.
2. Open the command palette in an open-core build and run "Show Seed Failure Heatmap"; confirm the dispatch is a silent no-op (no exception, no navigation).
3. Confirm the action label is rendered in every locale (en, zh_CN, zh, ja, ko).

**Coverage.** Unit-tested in `test/features/dashboard/providers/seed_failure_heatmap_opener_test.dart`. Pro overlay verification covers the populated case.

### 8.4.1 Scheduler propagates the parameterization identity onto results

**What it does.** `LocalJobScheduler` stamps each emitted `TestResult` with the originating (already-expanded) spec's `parentSpecId` and `boundParameters`, alongside the existing `executionSeed`. Parameterized templates are fanned out by `TestSpecExpander` before the run — each concrete child carries its parent id and its resolved sweep slice — so this propagation is what lets Pro surfaces that group results back by parent (the Seed Failure Heatmap; the "Re-run all in this parameter group" query) reconstruct the seed×parameter grid from a completed run. Without it the emitted result loses the parent/parameter identity even though the run executed the right expansions.

**Steps.**

1. Load a project with a `seeds:` + `parameters:` sweep on one test; run it.
2. Confirm every result for an expanded child carries a non-null `parentSpecId` equal to the template id and a `boundParameters` map holding that child's swept values.
3. Confirm a plain (non-parameterized) test's result has `parentSpecId == null` and `boundParameters == null` — the propagation is a no-op there.

**Coverage.** Unit-tested in `test/services/job_scheduler/local_job_scheduler_test.dart` (`'propagates the expanded spec parentSpecId + boundParameters onto the result'` + the non-parameterized null case). The Pro overlay's seed-failure-heatmap verification exercises the full pipeline end-to-end (`Coverage: AUTOMATED — flutter test`).

### 8.5 Sign-off bullet group

See `verification/VERIFICATION_CHECKLIST.md` "Pro re-run + heatmap seams".

## 8.6 Keyboard-shortcut conflict resolution & warnings

**What it does.** Settings → Keyboard Shortcuts lets the user rebind any `SimcruxAction`. When a rebind makes two actions share a chord, SimCrux surfaces the conflict and resolves precedence **deterministically** via `resolveShortcutConflicts` (`lib/core/shortcuts/shortcut_conflicts.dart`), which feeds both the editor warnings and the runtime `ShortcutManagerWidget`.

**Steps.**
1. Open Settings → Keyboard Shortcuts. On a fresh profile, confirm **no** conflict banner appears (the default keymap is collision-free).
2. Rebind **Re-run Selected** onto **Run Regression**'s chord (Cmd/Ctrl+R). The binding applies (a warning, not a block).
3. Verify the warning is **asymmetric**: the remapped row (Re-run Selected, the customized "interloper") shows an amber **"Takes precedence over …"**; the other row (Run Regression, the default "owner") shows a red **"Won't fire — shadowed by …"**.
4. Verify a red **summary banner** ("N shortcut conflict(s) need attention", singular at 1) appears at the top of the section, stays visible when affected rows scroll off-screen, and clears when the conflict is resolved.
5. Press the contested chord: the **remapped** action fires — not the default owner. Deterministic, independent of `SimcruxAction` declaration order; the shadowed action stays reachable via the command palette / menu bar.

**Automation Assessment.** `[Coverage: UNIT]` (`test/core/shortcuts/shortcut_conflicts_test.dart` — precedence + count + default-keymap-collision-free guard). `[Coverage: WIDGET]` (`test/core/shortcuts/shortcut_manager_widget_test.dart` — runtime precedence; `test/features/settings/widgets/shortcuts_settings_section_test.dart` — asymmetric warning + summary banner). Core algorithm covered cross-suite in `crux_keybindings`.

## 8.7 Command palette is always reachable

**What it does.** The command-palette opener appears under the **Help** menu of the desktop menu bar, but **not** inside the command palette's own searchable list (self-referential). Previously it was hidden from every browsable surface, so its keyboard shortcut (Cmd/Ctrl+Shift+P) was the only way in — unbinding it left the palette permanently inaccessible.

**Steps.**
1. Settings → Keyboard Shortcuts → **unbind** Open Command Palette.
2. Confirm Cmd/Ctrl+Shift+P no longer opens it, but **Help → Command Palette** does (recovery path — no "reset all" needed).
3. Open the palette and search "command palette": it does **not** list itself.

**Automation Assessment.** `[Coverage: UNIT]` (`test/core/shortcuts/action_category_test.dart` — `menuVisibleActions` contains / `paletteVisibleActions` excludes openCommandPalette; grouped under Help).

## 8.7.1 Command palette: keyboard-only operation

**What it does.** With the palette open, typing filters, **↑/↓** move the
highlight while the caret stays in the query field, **Enter** runs the
highlighted entry, and **Esc** closes without running anything.

**Why this section exists.** The 2026-07-16 screenshot session found Enter dead
in the release build: the right row was highlighted and Enter did nothing.
Only a mouse click ran the entry, which removes several actions from keyboard
reach entirely — the palette is the only surface for some of them. The palette
handled Enter solely as a framework key event, but on every desktop platform
the engine translates Enter, while a text field holds the input connection,
into a text-input *done* action that the framework's key pipeline never sees.
Fixed 2026-07-21 in `crux_command_palette` by also wiring the query field's
`onSubmitted`. **This is a shared-widget fix — verify it in every Crux app,
not just SimCrux.**

**Steps (release build; a debug build exercises the same path but the bug was
reported against release).**
1. Cmd/Ctrl+Shift+P. Type enough of an action's name to leave one match.
2. Press **Enter**. Expected: the palette closes and the action runs. Failure
   mode to watch for: the palette stays open and nothing happens.
3. Reopen. Without typing, press **↓** twice. Expected: the highlight moves
   two rows down, and the text caret has **not** jumped — typing a character
   still appends to the query rather than inserting mid-string.
4. Press **↑** once, then **Enter**. Expected: the row now highlighted runs.
5. Reopen, type a query matching nothing ("No matching commands."), press
   **Enter**. Expected: nothing runs and the palette stays open.
6. Reopen and press **Esc**. Expected: the palette closes, nothing runs, and
   the window behind it is unchanged — in particular no *second* route closes
   (Esc used to bubble past the palette to the enclosing route).
7. Repeat step 2 with the **numpad** Enter key.

**Edge cases.** An external keyboard on a laptop, and an IME (Japanese/Korean)
active in the query field: with an IME mid-composition Enter commits the
composition rather than running the action, which is correct — press Enter
again to run.

**Tier-gate scenarios.** None for the keyboard mechanics. Pro/ENT entries keep
rendering their tier badge and keep showing the upgrade path when run from the
keyboard exactly as when clicked; confirm one Pro-badged entry behaves
identically via Enter and via click.

**Automation Assessment.**

| Check | Automatable? | How |
|---|---|---|
| Enter as an engine *done* action runs the highlighted entry | **Yes** | `crux_command_palette`'s `command_palette_test.dart` — `testTextInput.receiveAction`, the path that reproduces the shipped bug |
| Enter as a key event runs it, and both together run it once | **Yes** | same file — the double-dispatch / double-pop guard |
| ↑/↓ move the highlight with focus retained | **Yes** | same file |
| Esc closes without dispatching and without popping twice | **Yes** | same file |
| Behaviour holds on every `TargetPlatform` and across the locale sweep | **Yes** | same file |
| A real hardware keypress against a signed release build | **No** | Manual, per release — the defect lived in engine-to-framework key delivery, which no widget test observes |

## 8.8 Plugin-SDK action opener seams (`pluginManagerOpenerProvider` / `reloadPluginsOpenerProvider`)

**What it does.** The `openPluginManager` / `reloadPlugins` actions dispatch through two nullable opener seams (`lib/services/driver_plugin/plugin_action_openers.dart`). Open-core defaults are `null`, so both actions surface the Pro-gated snackbar (correct — plugin loading is Pro-only). The Pro overlay registers real openers (Settings → Plugins panel + directory re-scan); the Pro guide covers that side. Before this seam existed the two actions were hard-wired to the Pro-gated snackbar, so even a Pro build could never reach the plugin SDK.

**Steps (open-core build).**

1. Command palette → "Open Plugin Manager". Confirm the "Plugin Manager requires SimCrux Pro." snackbar (opener default is null).
2. Command palette → "Reload Driver Plugins". Confirm the same Pro-gated snackbar shape.
3. Build a fresh `ProviderContainer`; read both opener providers; confirm both are `null`.

**Automation Assessment.** `[Coverage: UNIT]` for the null defaults; the Pro overlay's `plugins_settings_section` tests cover the populated case. Manual steps 1–2 are smoke-level.

## 8.9 Trend retention enforcement + App Diagnostics trend-store section

**What it does.** After every completed regression run, `RegressionRunner` reads `retentionPolicyProvider` (default 30 days / 50 000 points) and calls `TrendStore.applyRetention(policy)` best-effort, so `trends.db` stays bounded in every tier without user action. The App Diagnostics dialog gained a **Trend store** section rendering `trendStorageStatsProvider` (data-point count, run count, approximate on-disk size; localized empty / size-unknown states). Before this wiring, `applyRetention` / `storageStats` / `retentionPolicyProvider` had zero production callers and trends.db grew without bound.

**Steps.**

1. Run a regression to completion. Tools → App Diagnostics: the Trend store section shows a non-zero data-point count and run count.
2. Set a tiny policy (Pro build: Settings → Retention → max data points = 1; open-core: programmatic `retentionPolicyProvider.notifier.replace`). Run another regression; re-open App Diagnostics; confirm the count pruned to the policy bound.
3. Fresh install (no runs): the section shows the localized "Trend store is empty." label.
4. Locale sweep: the section renders in en / zh_CN / zh / ja / ko without exceptions.

**Automation Assessment.** `[Coverage: UNIT]` — `test/features/dashboard/providers/regression_runner_test.dart` ("retention enforcement" group: ingestion past the policy horizon prunes; unlimited policy retains; stats reflect reality) + `test/features/diagnostics/app_diagnostics_dialog_test.dart` (summary / size-unknown / empty / 5-locale sweep). Step 2's Pro settings path is covered in the Pro guide.

## 8.10 Multi-project action seams (`switchProject` / `reopenRecentProject` / `closeAllProjects` / `pinActiveProject`) + PR-annotation seams

**What it does.** Every action whose meaning is defined by the persistent project registry is Pro-tier, and open-core routes it through a null extension-point opener:

| Action | Open-core seam | Open-core behavior |
|---|---|---|
| `switchProject` | `projectSwitcherOpenerProvider` | null → "requires SimCrux Pro" |
| `reopenRecentProject` | `reopenRecentProjectOpenerProvider` | null → "requires SimCrux Pro" |
| `closeAllProjects` | `closeAllProjectsOpenerProvider` | null → "requires SimCrux Pro" |
| `pinActiveProject` | `pinActiveProjectOpenerProvider` | null → "requires SimCrux Pro" (even with a project open: `NoopProjectRegistry` stores no pins) |

The Pro overlay overrides each opener with an implementation that gates on `betaPeriodProvider` + `licenseTierProvider` and shows the Pro upgrade dialog on the deny path. The Pro-side behavior is verified in the Pro overlay's verification guide.

`dispatchPrAnnotations` / `configurePrAnnotationTarget` follow the same shape through `prAnnotationDispatchOpenerProvider` / `prAnnotationSettingsOpenerProvider`: both are null in open core, so both show "requires SimCrux Pro".

**Steps (open-core build).**

1. Command palette → confirm **Switch Project**, **Reopen Recent Project**, **Close All Projects** and **Pin Project Tab** each render a PRO badge; the native menu bar shows the localized ` (PRO)` suffix on the same four.
2. With a project open, fire each of the four. Confirm each shows "requires SimCrux Pro" — no silent no-op, no "no recent projects" info snack that would contradict the badge.
3. Confirm **Close All Tabs** renders **no** badge and works: it confirms, then closes every open tab.
4. Command palette → "Dispatch PR Annotations" and "PR Annotation Target": both show "requires SimCrux Pro".

**Automation Assessment.** `[Coverage: WIDGET — simcrux_action_handlers_test.dart]` for the seam dispatch + snack selection (the `_expectedDispatch` classification map is pinned against `SimcruxAction.values`, so a new action cannot ship unclassified); `[Coverage: UNIT — simcrux_action_test.dart]` for the tier declarations; `[Coverage: MANUAL]` for the badge rendering in the native menu bar.

## 8.11 Registry↔workspace sync (`ProjectWorkspaceSync`) + empty-canvas seam

**What it does.** Before 2026-07-17 the project registry and the crux_workspace tab surface were fully disconnected: File → Open added a tab the registry never learned about (so switcher / recents / pins operated on stale-empty data), and registry-driven actions (switcher selection, recents Reopen, `reopenRecentProject`) mutated the registry without changing the displayed content. `ProjectWorkspaceSync` (anchored at app boot) now mirrors both directions with equality-guarded convergence: every config tab is recorded as an open project (close → registry recents), and registry activation/closure opens/activates/closes the matching tab. The `ProjectTabStrip` widget was **removed as superseded** — the crux_workspace viewer tab bar is the single tab surface. Separately, `emptyCanvasContentBuilderProvider` lets the Pro overlay replace the zero-tabs empty canvas (Pro mounts `EmptyWorkspaceState`: `EmptyCanvasContent` welcome side + registry recents panel).

**Steps (Pro build).**

1. File → Open a config. Cmd/Ctrl+P: the switcher lists it as open + active (the registry recorded the tab).
2. Open a second config; close the first tab (×). The switcher's recents (and the empty-canvas recents panel) now list the closed project with Reopen / Forget.
3. Select the recent project in the switcher (or press Reopen): the matching tab re-opens **and becomes the visible content** — previously this was a silent registry-only mutation.
4. With two tabs open, pick the inactive one in the switcher: the workspace switches tabs.
5. Close a project via the switcher's per-row Close: its tab closes.
6. Close every tab: the empty canvas renders — on Pro, `EmptyWorkspaceState` (Open Config / Session / Workspace / New actions + recent-configs list on the welcome side, registry recents panel beside it); on open-core, the built-in `EmptyCanvasContent` (seam default is null).

**Automation Assessment.** `[Coverage: UNIT]` — `test/features/workspace/providers/project_workspace_sync_test.dart` (recorder: open/close/active-switch/empty-path skip; follower: registry-open creates+activates tab, setActive activates, registry-close closes; loop-safety convergence with mutation counters). The Pro empty-canvas override is covered in the Pro repo's tests; seam default (null → `EmptyCanvasContent`) is exercised by every existing `WorkspaceScreen` usage.

## 9. Color Theming & Customization (suite-wide)

SimCrux adopts `crux_theme`'s preset-driven theming the same way WaveCrux, NetCrux, and LintCrux do: `cruxColorThemeProvider` holds the active `CruxColorTheme`, a `SimcruxCruxColorThemeNotifier` override bridges between `AppSettings.core.activeThemeName` / `themeOverrides` and that provider, and the root `MaterialApp` runs every base theme through `applyChromeTokens(...)` while driving `themeMode` via `themeModeFromBrightness(...)`. End-users see the same Settings → Appearance section across the four-app suite.

### What it does

- **Preset picker** — four built-in presets via `crux_theme`'s `PresetCard` (`wavecrux-dark`, `wavecrux-light`, `solarized-dark`, `high-contrast-dark`, `oscilloscope`). Tapping a preset writes through to `AppSettings.core.activeThemeName`.
- **Brightness toggle** — `MaterialApp.themeMode` follows the preset's `brightness`.
- **Chrome tokens** — Solarized Dark / Oscilloscope re-tint scaffold, AppBar, simulation panes, status bar via `applyChromeTokens`.
- **Per-token editor** — `TokenCategorySection` exposes every registered chrome token.
- **Theme packs** — install / activate / uninstall flow for `.crux-theme.json` files.
- **Locale** — every preset card, token row, color picker, and pack-browser string flows through `ThemeAppearanceStrings`.

### Setup

- Load a simulation config so simulation panes are populated.
- Open Settings → Appearance.

### Step-by-step verification

#### 9.1 Preset switching repaints every surface

1. Tap `WaveCrux Light`. **Expected:** Settings dialog and all chrome surfaces (AppBar, simulation panes, status bar) flip to light.
2. Tap `Solarized Dark`. **Expected:** Chrome re-tints with Solarized hues (teal-blue), not default Material-3 dark.
3. Tap `Oscilloscope`. **Expected:** Chrome flips to phosphor-green-on-black.
4. Quit and relaunch. **Expected:** Whichever preset you left active is restored.

#### 9.2 Per-token chrome override

Same flow as NetCrux §8.2 — edit a chrome token, observe immediate repaint, reset clears the override.

#### 9.3 Theme pack import / export

Same flow as WaveCrux §22.7.3 / §22.7.4. Default export filename: `simcrux-theme.crux-theme.json`.

#### 9.4 Locale sweep

Switch the active locale (Settings → Application → Language) to each of `en`, `zh_CN`, `ja`, `ko` and reopen Settings → Appearance. **Expected:** preset names, all headings, and color picker dialog render in the active locale with no overflow.

### Edge cases

| Scenario | Expected behavior |
|---|---|
| Unknown `AppSettings.core.activeThemeName` at boot | Falls back to `wavecrux-dark` |
| Imported pack with unknown chrome token id | Pack installs; unknown token silently ignored |
| Pack omits the `chrome` key entirely | Pack installs; chrome uses `SimcruxTheme` defaults |

### Automation assessment

| Test | Coverage | Assessment |
|---|---|---|
| `applyChromeTokens` / `themeModeFromBrightness` | `crux_theme/test/chrome_theme_data_test.dart` | **AUTOMATED** |
| `SimcruxCruxColorThemeNotifier.activate` persists | Pending | **HYBRID** |
| Brightness toggle from preset selection | **MANUAL** — visual |
| Chrome token override visible in chrome | **MANUAL** — visual |
| Locale sweep on Settings → Appearance | Pending | **AUTOMATED** when added |

---

## 10. Orchestration Robustness & Performance

SimCrux is a
regression **manager**, not a simulator, so these entries verify *orchestration*
robustness — process lifecycle, runaway guards, capture bounds — not numeric
stability. The bulk runs against the in-process **fake deterministic process
runner** (`lib/services/job_scheduler/fake_process_runner.dart`): no real
simulator is needed, and the real-simulator integration tests in
`test/integration/` remain the end-to-end backbone (they skip when the binary is
absent).

### 10.1 Process lifecycle & tree-reaping

- **What it does (plain language).** Every child the scheduler spawns — including
  Cocotb grandchildren (`make → python → vvp`) — is reaped within the grace
  window under timeout and cancellation. SIGTERM is sent to the whole process
  tree; if any member ignores it, SIGKILL is escalated after the grace window.
  Zero orphans, zero zombies. The recorded result carries the terminal
  `killSignal` (the kill *path*, not just the outcome).
- **Setup.** `flutter test test/services/job_scheduler/process_lifecycle_edge_cases_test.dart`
  and `…/orchestration_golden_test.dart`. Regenerate the corpus with
  `dart run tool/generate_orchestration_fixtures.dart`.
- **Step-by-step expected behaviour.** The 12 enumerated edge cases (normal exit,
  SIGTERM grace, SIGKILL escalation, Cocotb grandchild orphan, zombie reaping,
  cancel-midflight, semaphore-release-on-throw, resource-lock-starvation,
  multi-step cleanup, double-cancel idempotency, cancel-after-complete, and
  unsupported-platform bounded termination) each pass; the golden replay matches
  the committed `expected_results.ndjson` per scenario. Each scenario's
  committed `simcrux.yaml` also **loads through the real `ConfigLoader`** — in
  both fixture trees — and the specs it yields are diffed against the specs the
  scheduler runs (suite, name, `top`, seed, per-test timeout), so the config is
  the scenario's real input rather than a decorative sketch beside it.
- **Manual spot-check.** Open
  `verification/fixtures/orchestration/<scenario>/generated/simcrux.yaml` in
  SimCrux via **File → Open Project**. It must load — one `suite` with the
  scenario's tests. (These three files were once written against a schema the
  loader rejects outright; every existence check in the suite stayed green
  because none of them ever parsed the YAML.)
- **Diagnostics-assisted verification.** The fake runner exposes `liveHandles`; a
  correct tree reap leaves it empty. The golden encodes `killSignal` per test.
- **Edge cases & tier-gate.** Open-core only (no Pro tier gate); the seam
  (`ProcessReaper` interface + `NoopProcessReaper` + platform reapers +
  `processReaperProvider`) is reused unchanged by the Pro plugin path.

**Automation Assessment.**

| Test | Coverage |
|---|---|
| `process_lifecycle_edge_cases_test.dart` (12 cases + 2 mutations) | `[Coverage: INTEGRATION]` (fake runner) |
| `orchestration_golden_test.dart` (dual-tree corpus) | `[Coverage: INTEGRATION]` |
| real-simulator `test/integration/**` | `[Coverage: INTEGRATION]` (skips when binary absent) |

**Mutation.** Deleting the SIGKILL escalation hangs case 3 to its timeout;
reverting `terminateTree` to a single-PID kill leaves grandchildren orphaned
(case 4). Both verified.

### 10.2 Runaway-regression & resource guards

- **What it does (plain language).** No config, log volume, waveform-dump
  accumulation, or pathological regex can drive SimCrux into unbounded CPU,
  memory, or disk. The config-expansion ceiling is checked against the
  **Cartesian product across every axis** (not the largest single axis), for
  both hand-authored and FuseSoC-imported configs. The pass/fail capture buffer
  is a bounded head-dropping ring. Retained per-test dirs + waveform dumps are
  pruned by a keep-last-N-failures + total-byte policy. The regex detector bounds
  its scan window **and** the production scheduler classifies through an
  isolate-deadline guarded matcher (`PassFailDetectorRegistry.classifyAsync` →
  `RegexDetector.detectAsync`), so a catastrophic user pattern — including one
  nested in a composite `allOf`/`anyOf` — times out to the exit-code fallback
  instead of freezing the run on the main isolate.
- **Setup.** `flutter test test/services/config/config_expansion_fuzz_test.dart
  test/services/job_scheduler/driver_stdout_bounded_test.dart
  test/services/job_scheduler/cross_run_dump_retention_test.dart
  test/services/pass_fail_detector/regex_detector_redos_test.dart`.
- **Step-by-step expected behaviour.** A 100×100×2 = 20 000 sweep is rejected
  before any spawn; an imported config flows through the same ceiling; 1e6
  captured lines stay bounded with a non-zero dropped counter; an early fail
  token beyond the cap is dropped; retention prunes to the newest N / under the
  byte ceiling; a catastrophic `(a+)+$` pattern over 4 MB returns under a 500 ms
  deadline (the worker isolate is killed) — both via the bare `guardedRegexHasMatch`
  helper and via the production `classifyAsync`/`detectAsync` path exercised by the
  same test.
- **Edge cases & tier-gate.** Open-core only. The `dumpRetentionPolicyProvider`
  and `BoundedLogCapture` ceiling are configurable; defaults are generous.
- **Headless retention.** Both `--ci` schedulers — the app's
  `ciSchedulerFactoryProvider` and the standalone binary's
  `SimcruxCli.ciSchedulerFor` — prune with the default policy, as does the Pro
  local fallback when no distributed backend is configured. **Manual check:** on
  a runner, run a project with 60 failing tests twice and count
  `$TMPDIR/runs/*/*` — 50 remain.
- **`capture: always`** keeps a passing test's work dir and dump (no archive,
  no sweep), bounded by the same retention; `on_failure` still sweeps a passing
  work dir.

**Automation Assessment.**

| Test | Coverage |
|---|---|
| `config_expansion_fuzz_test.dart` (fixed-seed fuzz + multi-axis reject + post-import) | `[Coverage: UNIT]` |
| `driver_stdout_bounded_test.dart` (ring bound + scheduler capture) | `[Coverage: UNIT/INTEGRATION]` |
| `cross_run_dump_retention_test.dart` (keep-last-N + byte ceiling, ranked across every run) | `[Coverage: UNIT]` |
| `ci_scheduler_factory_retention_test.dart` (both headless schedulers are bounded) | `[Coverage: UNIT]` |
| `local_job_scheduler_waveform_archive_test.dart` (`always` keeps a passing dump, with and without an archive) | `[Coverage: UNIT]` |
| `regex_detector_redos_test.dart` (isolate deadline + scan bound) | `[Coverage: UNIT]` |

**Mutation.** Largest-single-axis instead of the product lets a 20 000 sweep
through; an unbounded capture sees the early fail token and mis-classifies;
dropping the byte ceiling prunes nothing; removing the scan bound matches a head
token. All verified.

### 10.3 Persistence durability & crash recovery

- **What it does (plain language).** A crash mid-run leaves a *recoverable* state:
  a truncated or garbled `results.ndjson` tail is trimmed to the last complete
  record (idempotently), an orphaned `runs` row is marked `interrupted` (never
  silently "passed"), and the SQLite trend store survives corruption, a
  future-schema-version file, and a concurrent write lock — and reclaims disk on
  retention.
- **Setup.** `flutter test test/services/result_store/persistence_recovery_edge_cases_test.dart
  test/services/trend_store/sql_recovery_test.dart
  test/services/trend_store/sql_pre_upgrade_backup_test.dart
  test/services/trend_store/trend_store_provider_corruption_test.dart
  test/services/trend_store/trend_store_rebuild_test.dart
  test/features/diagnostics/widgets/trend_store_recovery_card_test.dart`.
- **Step-by-step expected behaviour.** Clean tail → no-op; truncated/garbled tail
  → trimmed to N-1, repaired in place; empty/missing file → clean no-op; embedded
  newline value (encoder-escaped) → not mis-split; second pass → idempotent.
  Retention prune + `VACUUM` shrinks the on-disk file; an unfinalized run is
  marked interrupted; a header-corrupt DB → renamed aside, a fresh database
  opened in its place and a notice raised (never an uncaught
  `DatabaseException`, and never a deletion); a future `user_version` →
  `CruxSchemaVersionSkewException`; two writers share a file under the
  `busy_timeout` back-off.
- **Edge cases & tier-gate.** Open-core only. The `NdjsonRecovery` seam
  (`NoopNdjsonRecovery` / `FileNdjsonRecovery` / `ndjsonRecoveryProvider`) is
  available to the Pro per-project stores; no Pro call site consumes it today.
- **Reconciliation is wired, not just implemented (§10.8).** `SqlTrendStore.open`
  now runs `reconcileInterruptedRuns` on every open, and the CI runner calls
  `StreamingResultsWriter.abortWithoutSummary` on its error path. Both used to
  exist with zero production call sites.

- **Pre-upgrade backup (manual, once per release containing a migration).**
  `trends.db` is PRECIOUS, so every schema upgrade snapshots it first with
  `VACUUM INTO` and no upgrade runs if that snapshot cannot be written
  (`crux-shared/packages/crux_sqlite/README.md`, rule 4). To verify by
  hand on a real file with real history:

  1. Note the schema version and the row count:
     `sqlite3 "<appSupport>/trends.db" 'PRAGMA user_version; SELECT COUNT(*) FROM test_results;'`
  2. Launch the **previous** public build once so the file is at its schema
     version, then quit it and launch **this** build.
  3. `ls "<appSupport>"` — a `trends.db.pre-v<n>-<YYYYMMDD>T<HHMMSS>Z.bak` must
     have appeared, where `<n>` is the version from step 1. Open it:
     `sqlite3 "<the .bak>" 'PRAGMA user_version; SELECT COUNT(*) FROM test_results;'`
     must return exactly the numbers from step 1 — the snapshot is the file as
     it was *before* the upgrade, not a copy of the upgraded one.
  4. The live `trends.db` is at the new version with at least the step-1 row
     count, and Trends renders the same history it did before.
  5. **Backup failure aborts the migration.** Repeat steps 1–2 with the
     directory made read-only (`chmod 555 "<appSupport>"`). The store must fail
     with a message naming the store, the size, and what to do — and
     `PRAGMA user_version` afterwards must still be the *old* version, with
     every row intact. Restore with `chmod 755`.
  6. **The downgrade is pointed at it.** Install the previous public build over
     the upgraded file. It must refuse, name both versions, and name the `.bak`
     from step 3 by absolute path — and `trends.db` must still be there
     afterwards.

  Only the newest two backups are kept, and only after a *successful* upgrade;
  a failed one prunes nothing.
- **Where the mechanism lives.** `crux_sqlite`, not here. `trends.db` opts in by
  declaring `CruxDbRecovery.renameAside`, which is PRECIOUS — there is no
  backup call in this repo to forget, and `cache.db`-style derivable stores opt
  out by declaring `recreate`.

#### 10.3.1 A damaged `trends.db`: the notice and the rebuild

- **What it does (plain language).** A `trends.db` whose bytes are not a
  readable SQLite database is **renamed aside**, never deleted: SimCrux keeps
  it as `trends.db.corrupt-<YYYYMMDD>T<HHMMSS>Z`, opens a fresh empty database
  in its place, and raises a notice in **App Diagnostics**. Without the notice
  the quarantine would be invisible — an empty trend chart looks exactly like a
  project that has never been run. The notice card names where the bytes went,
  names the pre-upgrade `.bak` when one exists (the better recovery: it is a
  complete database), and offers one explicit action: **Rebuild from
  results.ndjson…**. The rebuild never runs by itself.
- **What a rebuild can and cannot recover.** It replays the `results.ndjson`
  archives written by runs with streaming output (`--ci`, or
  `output: { streaming: true }`). All five trend-point fields come back
  verbatim — run id, test id, status, runtime, start time. **Runs that left no
  archive cannot be recovered by anything**, and neither can a run's
  `config_hash` or trigger kind. The card says so before the user clicks.
- **Setup (manual, on a real file).**
  1. Run a regression with `--ci` so an archive exists, and note the path
     printed for `results.ndjson`.
  2. Quit SimCrux. Corrupt the database deliberately:
     `printf 'not a database' | dd of="<appSupport>/trends.db" conv=notrunc`
  3. Relaunch and open **Help → App Diagnostics** (or the palette entry).
- **Step-by-step expected behaviour.**
  1. The dashboard opens normally. Trends are empty — this is the fresh
     database, not a crash.
  2. App Diagnostics shows the red **Trend database was damaged** card naming
     both paths. `ls "<appSupport>"` shows the `trends.db.corrupt-…` file, and
     `cmp` against a copy of the bytes you wrote confirms it is byte-identical:
     **nothing was deleted**.
  3. Click **Rebuild from results.ndjson…**, select the archive from step 1,
     and confirm the card reports the recovered point and run counts. The
     Trend store line above it re-reads and shows the same counts.
  4. Re-selecting the same archive a second time recovers **0** points: a run
     already present is not replayed twice.
  5. Quit and relaunch. The recovered runs are **not** marked interrupted, and
     the trend charts render them.
- **Edge cases & tier-gate.** Open-core, and it covers the Pro per-project
  `<projectPath>/.simcrux/trends.db` too — both files open through the same
  `SqlTrendStore.open`, so both quarantine, both notify and both can be
  rebuilt. A crash-truncated archive recovers its complete prefix and stays
  interrupted; the archive itself is **never** rewritten by a rebuild.

**Automation Assessment (10.3.1).**

| Test | Coverage |
|---|---|
| `test/services/trend_store/sql_recovery_test.dart` (quarantine keeps every byte; the reported path is absolute) | `[Coverage: HYBRID]` (file-backed SQLite) |
| `test/services/trend_store/trend_store_provider_corruption_test.dart` (the production provider resolves to a store and raises the notice) | `[Coverage: HYBRID]` |
| `test/services/trend_store/trend_store_rebuild_test.dart` (round trip through a real `StreamingResultsWriter`; finish stamp; truncated archive; idempotence; unreadable archive; no-run-id) | `[Coverage: HYBRID]` |
| `test/features/diagnostics/widgets/trend_store_recovery_card_test.dart` (both bodies, the backup line, dismissal, locale sweep) | `[Coverage: WIDGET]` |

**Mutation (10.3.1).** Reverting `SqlTrendStore.open` to
`databaseFactory.openDatabase(…, options: policy.buildOptions(…))` makes both
`corruptSqlite` cases red with the raw `DatabaseException` — verified
2026-08-20. Dropping the `markRunFinished` stamp from the rebuild makes
`a recovered complete run is NOT relabelled interrupted` red.

**Automation Assessment.**

| Test | Coverage |
|---|---|
| `persistence_recovery_edge_cases_test.dart` (clean/truncated/garbled/empty/idempotent/midNewline) | `[Coverage: UNIT]` |
| `sql_recovery_test.dart` (VACUUM-shrinks, interrupted, quarantined-corrupt, schema-ahead, locked) | `[Coverage: HYBRID]` (file-backed SQLite) |
| `sql_pre_upgrade_backup_test.dart` (backup before an upgrade, none at the same version, the store's PRECIOUS declaration) | `[Coverage: HYBRID]` (file-backed SQLite) |

**Mutation.** Returning the raw lines without trimming the partial tail makes the
`truncatedLastLine` case red; removing the `VACUUM` makes `retentionVacuumShrinks`
red; disabling the backup in `CruxSqliteOpenPolicy.buildOptions`'s `onConfigure`
makes `sql_pre_upgrade_backup_test.dart`'s first case red. All verified.

### 10.4 Determinism & seed surfacing

- **What it does (plain language).** Every driver records the seed it **actually
  ran with** (`TestExecutionFinished.effectiveSeed` → `TestResult.executionSeed`):
  the requested seed when pinned, else a clock-derived value the driver injects
  (`+seed=` for Icarus, `+verilator+seed+` for Verilator, `RANDOM_SEED` for
  Cocotb; report-only for GHDL). The first flaky retry replays that *effective*
  seed, so it reproduces the original failure — closing the documented
  determinism gap. The `config_hash` changes whenever the test population /
  parameter set changes, so trend queries are never silently blended.
- **Setup.** `flutter test test/services/simulator/effective_seed_surfacing_test.dart
  test/services/config/config_hash_guard_test.dart
  test/services/job_scheduler/seed_replay_test.dart`.
- **Step-by-step expected behaviour.** Each driver reports the requested seed and
  injects it; with no seed pinned it surfaces a derived non-null seed. Adding /
  removing a test or changing a parameter / seed sweep changes `computeConfigHash`;
  identical configs hash identically. Through the scheduler, the first retry's
  `+seed=` equals the first attempt's effective seed.
- **Edge cases & tier-gate.** Open-core surfaces the effective seed; the Pro
  `FlakyRetryPolicy` replays it (Pro delta, in the Pro overlay's verification guide).

**Retry-policy wiring & run-start priming.** Two open-core seams let an injected retry policy actually drive
the run: (1) `jobSchedulerProvider` passes `retryPolicyProvider` into
`LocalJobScheduler` — before this fix it fell back to the scheduler's
`NoopRetryPolicy` default, so any override (the Pro `FlakyRetryPolicy`) never
reached the run loop; (2) the optional capability
`PreparableRetryPolicy.prepareForRun(specs)` is invoked once by the scheduler at
run start, before the first test executes, so a policy whose synchronous
`shouldRetry` reads from an async-primed cache sees a warm cache on the first
failure. `NoopRetryPolicy` (and any policy not implementing the capability) is
unaffected; priming is best-effort (the scheduler swallows a `prepareForRun`
error so a trend-store hiccup degrades to the policy's cold-cache behaviour
rather than aborting the run). `retry_policy_wiring_test.dart` asserts both: the
provider injects the override, and `prepareForRun` runs at run start with the
run's specs before a policy-driven retry.

**Automation Assessment.**

| Test | Coverage |
|---|---|
| `effective_seed_surfacing_test.dart` (Icarus/Verilator/GHDL, requested + derived) | `[Coverage: UNIT]` |
| `config_hash_guard_test.dart` (stable + sensitive to test/param changes) | `[Coverage: UNIT]` |
| `seed_replay_test.dart` (scheduler retry replays the effective seed) | `[Coverage: INTEGRATION]` |
| `retry_policy_wiring_test.dart` (`jobSchedulerProvider` injects the policy + `prepareForRun` at run start + policy-driven retry) | `[Coverage: INTEGRATION]` |

**Mutation.** A driver that reports the requested seed (null) instead of the
effective seed makes `seed_replay_test` red (the replay rolls a fresh seed and
the two attempts diverge). Verified. Dropping the `retryPolicy:` wiring in
`jobSchedulerProvider`, or the `prepareForRun` call in `LocalJobScheduler`, makes
`retry_policy_wiring_test` red (the injected policy never runs / is never primed).

### 10.5 Long-run memory soak

- **What it does (plain language).** A 10,000-test regression runs with a flat
  retained working set — no monotonic growth. Results stream to the bounded
  `StreamingResultsWriter` (O(1) aggregate footprint), per-test logs live in the
  `LogBuffer` ring (head-dropped at `maxLines`), and the in-memory store never
  pins a full log. The `tool/soak/regression_soak.dart` harness drives the real
  scheduler + `FakeProcessRunner` and samples real RSS; the CI test asserts the
  deterministic bounds the flat RSS rides on.
- **Setup.** `dart run tool/soak/regression_soak.dart [N]` (writes
  `build/soak/results.jsonl`, gitignored) and
  `flutter test test/perf/memory_soak_test.dart`.
- **Step-by-step expected behaviour.** The log ring's retained line count at the
  75% mark equals it at 100% (flat); the streaming writer's footprint stays
  O(distinct statuses) across 10k results; every retained per-test buffer is
  ring-bounded. The soak harness's `results.jsonl` shows RSS roughly flat between
  the 1000-test checkpoints.
- **Edge cases & tier-gate.** Open-core; the Pro per-project SQLite store is
  soaked as a delta (in the Pro overlay's verification guide).

**Automation Assessment.**

| Test | Coverage |
|---|---|
| `tool/soak/regression_soak.dart` (real-RSS sampler, 10k) | `[Coverage: HYBRID]` (out-of-band) |
| `memory_soak_test.dart` (ring flatness + O(1) writer + bounded store) | `[Coverage: HYBRID]` (deterministic bound + soft RSS) |

**Mutation.** Raising the `LogBuffer` ring's effective cap (e.g. `1 << 30`) makes
the retained-line count grow with the stream, so the 75% ≈ 100% flatness
assertion goes red. Verified.

### 10.6 Dashboard / aggregation performance at scale

- **What it does (plain language).** The results dashboard, the flaky-detection
  trend aggregate, and the inspector log view stay interactive at 10,000+ rows:
  the table is virtualized (only viewport rows realized), the trend aggregate is
  served by a composite `(test_name, started_at)` index (no scan/temp-sort), and
  a 100k-line log is ring-bounded before it reaches the view.
- **Setup.** `flutter test test/perf/dashboard_render_test.dart
  test/perf/trend_query_index_test.dart test/perf/inspector_log_render_test.dart`
  for the deterministic guards (always run); add
  `--dart-define=RUN_BENCHMARKS=true test/perf/trend_query_wallclock_bench_test.dart`
  for the raw wall-clock companion (nightly perf job only).
- **Step-by-step expected behaviour.** A 10k-row table realizes < 100 rows; a
  streamed run of 2 000 fast-arriving results coalesces to a handful of
  rows-pipeline rebuilds (never one per result) with the final coalesced
  emission carrying every result (live `TestRun.view` in the store, one
  specsById build per config, `coalesceLatest` at ~10 Hz — before/after at 10k:
  10 409 ms / 10 001 rebuilds → 687 ms / 60 rebuilds); the per-test aggregate
  over a 10k-run store returns < 200 ms and `EXPLAIN QUERY PLAN` uses
  `idx_results_test_started` (no `SCAN`, no `TEMP B-TREE`); a 100k-line log is
  ring-bounded (the view never materializes all 100k).
- **Edge cases & tier-gate.** Open-core; the Pro regression-diff bench is the
  delta (in the Pro overlay's verification guide).

**Automation Assessment.**

| Test | Coverage |
|---|---|
| `dashboard_render_test.dart` (realized-row bound + streaming scenario: coalesced-rebuild bound, final-state correctness) | `[Coverage: WIDGET]` |
| `trend_query_index_test.dart` (index plan; no SCAN, no temp-sort) | `[Coverage: HYBRID]` |
| `trend_query_wallclock_bench_test.dart` (< 200 ms, nightly-only) | `[Coverage: BENCH]` |
| `inspector_log_render_test.dart` (ring-bounded open) | `[Coverage: UNIT]` |

**Mutation.** A non-virtualized `Column` of all rows realizes 10k rows (dashboard
bench red); dropping the composite-index migration makes the planner stop using
`idx_results_test_started` (trend bench red). Both verified.

### 10.7 Static guardrails + CI self-enforcement

- **What it does (plain language).** The orchestration corpus and the
  no-real-spawn discipline are enforced by CI, not memory. Three static guards
  under `test/static/` fail on an injected violation: a real `Process.start` /
  `Process.run` smuggled into `test/services/**`, a loose fixture file outside a
  scenario's `generated/`, or a scenario missing its `behaviors.json` / golden.
  The companion guard checks **validity, not just presence**: every committed
  `simcrux.yaml` in both corpora is parsed through the real `ConfigLoader`, so a
  config that the app would refuse to open cannot sit in the corpus green.
- **Setup.** `flutter test test/static/`.
- **Step-by-step expected behaviour.** All three guards pass on the committed
  tree; each goes red on its injected violation (see the mutation note). The
  real-simulator `test/integration/**` tests continue to **skip** cleanly when
  the binary is absent — they must never fail CI for a missing `iverilog`.
- **Edge cases & tier-gate.** Open-core; the Pro plugin and isolate guards are
  the delta (in the Pro overlay's verification guide).

**Automation Assessment.**

| Test | Coverage |
|---|---|
| `no_real_process_spawn_in_unit_tests_test.dart` (the load-bearing guard) | `[Coverage: STATIC]` |
| `orchestration_fixture_layout_test.dart` (no loose fixtures) | `[Coverage: STATIC]` |
| `orchestration_fixture_companion_test.dart` (yaml + behaviors + golden, **and every yaml parses**) | `[Coverage: STATIC]` |

**Mutation.** Adding a `Process.run(...)` to any `test/services/**` file makes the
no-real-spawn guard red. Verified. Restoring any pre-fix (schema-invalid)
`simcrux.yaml` into either corpus makes the companion guard red with the
loader's own `file:line:col` message. Verified.

> **§10.1–§10.7 are held by `flutter test` on every desktop platform.**

---

### 10.8 Lifecycle robustness: quit, resource locks, CI exit honesty, reconciliation

- **What it does (plain language).** Five things that all fail quietly rather
  than loudly, so each needs a deliberate check:
  1. **Quit no longer orphans simulators.** File → Quit (and an OS-initiated
     termination — window close, Cmd-Q, log-out) cancels every in-flight
     regression *across every tab*, waits for the drivers to reap their process
     trees under a bounded grace, and only then exits. Previously `quit` was
     `exit(0)` — every running `vvp` / `verilator` / `make → python` tree, and
     its work dir, survived the app.
  2. **A resource lock is never granted twice.** Releasing an FPGA-board /
     license-slot lock transfers ownership straight to the next waiter instead
     of clearing the entry and letting the waiter re-take it a microtask later
     (a window in which a third acquirer was granted the same board).
  3. **CI exit codes are honest.** Tests classified `unknown` (no driver
     registered, an exception inside the scheduler) now count as failures, and
     the summary line prints *every* status that occurred, so its components sum
     to its own total. `vacuous` counts as a failure only under the new
     `--fail-on-vacuous` flag.
  4. **Crash reconciliation actually runs.** Opening the trend store marks runs
     a dead process left dangling; a CI run that errors mid-flight flushes and
     closes its NDJSON without writing a `summary` line.
  5. **Cheap correctness fixes.** Driver log-stream errors no longer hang a test
     until its timeout; cancellation awaits a completion signal instead of
     polling every 10 ms; finished runs and per-config schedulers are released
     instead of retained forever.
- **Setup.** `flutter test test/services/lifecycle/ test/services/job_scheduler/
  test/services/ci/ci_runner_test.dart test/services/simulator/driver_stream_error_test.dart
  test/services/trend_store/sql_recovery_test.dart
  test/core/shortcuts/simcrux_action_handlers_test.dart`. For the manual pass:
  a project with at least one long-running testbench.
- **Step-by-step expected behaviour.**
  1. Start a regression with a testbench that runs for minutes. While it is
     running, choose **File → Quit**. The app terminates, and `ps` (or Task
     Manager) shows **no** surviving `vvp` / `verilator` / `python` descendants.
     Repeat with the window close button and with Cmd-Q / Alt-F4 — same result.
  2. Repeat step 1 with runs started in **two different tabs**, switching to a
     third tab before quitting. Both background runs must still be reaped — the
     registry is app-scoped precisely so the exit path sees tabs it is not
     looking at.
  3. Declare a `resources:` lock shared by several tests and run them at
     concurrency > 1. Exactly one test at a time may hold the lock, and the
     waiters are served in submission order.
  4. Run `simcrux --ci` against a project whose `simulators:` block names a
     simulator with no registered driver. Exit code is **non-zero**, and the
     summary line names the `unknown` count.
  5. Run `simcrux --ci` on a project whose testbench completes without
     exercising its checks. Default: exit 0, summary shows `N vacuous`. With
     `--fail-on-vacuous`: exit 1.
  6. Kill the app (`kill -9`) mid-run, then relaunch and open the trend view.
     The interrupted run is marked interrupted, not rendered as complete.
- **Diagnostics-assisted verification.** App Diagnostics → Trend Store shows the
  run count; an interrupted run carries the `interrupted` metadata marker
  (`SqlTrendStore.isRunInterrupted`).
- **Edge cases.** A wedged driver that ignores SIGTERM/SIGKILL must **delay**
  the quit by at most `AppExitCoordinator.kDefaultShutdownGrace` (8 s), never
  block it — `shutdown()` returns false and the app exits anyway. A second quit
  request while the first drain is running is a no-op, not a second drain.
  Quitting with nothing running exits immediately.
- **Tier-gate.** Open-core only; no tier gating on any of it. The Pro overlay
  inherits every fix through the submodule. The `--fail-on-vacuous` flag is
  open-core CLI surface and is unaffected by `kBetaPeriod`.

**Automation Assessment.**

| Test | Coverage |
|---|---|
| `test/services/lifecycle/app_exit_coordinator_test.dart` (registry lifecycle, throwing canceller, grace expiry, idempotent shutdown) | `[Coverage: UNIT]` |
| `test/services/lifecycle/app_exit_reaps_runs_test.dart` (scripted processes recorded as killed end-to-end) | `[Coverage: UNIT]` |
| `test/core/shortcuts/simcrux_action_handlers_test.dart` → `group('quit')` (drains then exits, via injected `processExitProvider`) | `[Coverage: WIDGET]` |
| `test/features/dashboard/providers/regression_runner_test.dart` (run registers/releases in `activeRunRegistryProvider`) | `[Coverage: UNIT]` |
| `test/services/job_scheduler/resource_lock_table_test.dart` (forced interleaving, FIFO, no double-grant) | `[Coverage: UNIT]` |
| `test/services/job_scheduler/job_scheduler_cache_test.dart` (reuse across test edits, bounded LRU) | `[Coverage: UNIT]` |
| `test/services/ci/ci_runner_test.dart` (unknown raises exit code, summary sums to total, `--fail-on-vacuous`, crash-path abort) | `[Coverage: UNIT]` |
| `test/services/trend_store/sql_recovery_test.dart` → `reconcileAtOpen:` (reopen marks dangling run) | `[Coverage: HYBRID]` (file-backed SQLite) |
| `test/services/simulator/driver_stream_error_test.dart` (stdout/stderr stream error reaches a terminal event) | `[Coverage: UNIT]` |
| OS-initiated exit (`AppExitGuard` / `AppLifecycleListener.onExitRequested`) | `[Coverage: MANUAL]` — the embedder hook has no test-harness equivalent; covered by steps 1–2 above |

**Mutation.** Restoring `release()` to clear-then-complete makes the
double-grant test red (verified: `['waiter', 'interloper']` vs `['waiter']`).
Removing the drivers' stream `onError` handlers makes both
`driver_stream_error_test` cases red (verified: both hang to the 5 s guard).

### 10.9 Trend-store query cost, retention correctness, dump growth

- **What it does (plain language).** Four hot paths that were correct on a
  ten-test fixture and pathological on a ten-thousand-test project, plus two
  correctness bugs hiding behind them.

  1. **`recentDeltas` is one query, not N+1.** It used to issue a
     `SELECT … LIMIT 1` per test in the newest run to find each test's prior
     status. The dashboard's delta strip recomputes this on every trend flush
     tick mid-run (every 25 results / 250 ms), so a 10 000-test project queued
     ~10 000 round-trips per tick through the single sqflite worker, starving
     the sparkline and flaky-panel queries behind it. A `ROW_NUMBER()` window
     over the run window now resolves every test's prior status at once.
  2. **`limit` is honored.** It previously selected `limit` run ids and used
     only the first, then scanned *all* history for the prior status. It now
     bounds the comparison window as the interface always documented: a prior
     result older than the newest `limit` runs reads as "no previous status".
  3. **Retention actually bounds the database.** The `runs` table was never
     pruned (it feeds `recentDeltas`' ordering and `storageStats`);
     `lowestValueFirst` deleted row-at-a-time in autocommit (one fsync per
     row); and once the DB was older than the age cutoff, *every* post-run
     retention pass triggered a full `VACUUM` file rewrite. Deletes are now
     batched in one transaction, orphaned runs are pruned, and `VACUUM` is
     conditional on reclaimable space.
  4. **Dump retention bounds across runs.** `DumpRetentionPolicy`'s own doc
     promised a cap holding "across months of nightly regressions", but the
     scheduler pruned only the run that had just finished — a cap of N per run
     times unboundedly many runs. `pruneRetainedDumpsAcrossRuns` ranks every
     retained directory under `<runRoot>/runs/` together.
  5. **Regex guard isolates are pooled.** `guardedRegexHasMatch` spawned a
     fresh isolate per pattern per test (~20 000 spawns on a regex-heavy
     10 000-test run). Workers are leased from a bounded pool; the killable
     -deadline guarantee is unchanged because a worker serves one match at a
     time and a killed worker is never returned to the pool.

  Two new `TrendStore` methods support this and the Pro flaky panel:
  `recentTrendsFor` (bulk `recentTrend`, chunked `IN (…)`) and
  `distinctTestIds` (the honest "which tests ran recently" enumerator).
  Schema migration **v3** adds `idx_runs_started`, without which every
  recent-runs window is a full scan of the `runs` table.

- **Setup.** `flutter test test/perf/trend_query_count_test.dart
  test/services/trend_store/retention_bounds_disk_test.dart
  test/services/job_scheduler/cross_run_dump_retention_test.dart
  test/services/pass_fail_detector/regex_isolate_pool_test.dart`.

- **Step-by-step expected behaviour.**
  1. **Query cost.** With 1 000 tests × 6 runs seeded, `recentDeltas` issues
     exactly **1** statement (`debugQueryCount`), `distinctTestIds` exactly 1,
     and `recentTrendsFor` over 1 000 ids at most 3 (500 placeholders per
     chunk). All three counts are independent of the test count.
  2. **Equivalence.** `recentTrendsFor` returns, per test, byte-identical
     points to per-test `recentTrend` (runId, status, startedAt compared
     element-wise). Measured A/B at 5 000 tests × 10 runs: old N+1 path 391 ms
     / 5 002 queries, new path 59 ms / 1 query — **6.6×** faster, with both
     producing the identical 5 000 deltas.
  3. **Index plan.** `EXPLAIN QUERY PLAN SELECT id FROM runs ORDER BY
     started_at DESC LIMIT 10` names `idx_runs_started` and shows no
     `TEMP B-TREE`.
  4. **Retention bounds disk.** Across 30 synthetic runs against a real
     on-disk DB with `maxDataPoints: 2000`, the row count never exceeds the
     cap after any run and the file size plateaus (the settled tail's max is
     under 3× its min) instead of growing monotonically.
  5. **Runs are pruned; the live run is not.** After a prune, zero `runs` rows
     lack a surviving `test_results` row. A run whose row exists but whose
     first result has not yet flushed (the in-flight case) survives — the
     prune's cutoff is the oldest *surviving* data point, which an in-flight
     run is always newer than.
  6. **`VACUUM` is conditional.** A prune that frees a trivial number of pages
     leaves `freelist_count` non-zero (an unconditional `VACUUM` would always
     leave it 0). Thresholds: `kVacuumMinReclaimableBytes` (8 MiB) or
     `kVacuumMinFreeFraction` (25 % of the file).
  7. **Cross-run dump cap.** 5 runs × 4 failure dirs with
     `keepLastNFailures: 5` leaves exactly 5 directories — the 5 newest
     *overall*, spanning run boundaries. The mutation case (pruning each run
     in isolation, the old behaviour) leaves all 20.
  8. **Keep markers.** A `.simcrux-keep` file in a test dir pins it against
     pruning however old it is; the same file at the run level pins every test
     dir under that run. Pinned dirs are charged against the budget *before*
     unpinned dirs are admitted, so the ceiling still holds.
  9. **Regex pool.** A completed match parks its worker (`idleCount == 1`) and
     25 sequential matches never exceed one worker. A catastrophic `(a+)+b`
     still returns by its deadline and leaves `idleCount == 0` — the killed
     worker is not reused — and the next call transparently respawns.

- **Edge cases & tier-gate.** Open Core only; no tier gate, no user-visible
  strings, no ARB change. `limit <= 0` / `runWindow <= 0` return empty rather
  than throwing. `recentTrendsFor` omits tests with no history (it does not
  map them to an empty list). A pinned dump set larger than the ceiling
  degrades to "prune nothing unpinned" rather than to a violated policy. The
  `runs` prune is skipped entirely when no data points survive, because there
  is then no safe cutoff that could not delete a live run's row.

- **Diagnostics-assisted verification.** App Diagnostics → **Trend store**
  shows data-point count *and* run count; after a retention pass on an old
  project both should fall, where previously only the data-point count moved.

**Automation Assessment.**

| Test | Coverage |
|---|---|
| `test/perf/trend_query_count_test.dart` (1-query guards for `recentDeltas` / `distinctTestIds`, chunk guard for `recentTrendsFor`, bulk-vs-single equivalence, `idx_runs_started` plan) | `[Coverage: UNIT]` |
| `test/services/trend_store/retention_bounds_disk_test.dart` (30-run disk bound, run pruning, in-flight-run survival, conditional VACUUM, decimation cap) | `[Coverage: HYBRID]` (file-backed SQLite) |
| `test/services/job_scheduler/cross_run_dump_retention_test.dart` (cross-run count + byte caps, keep markers at both levels, empty-shell sweep, async parity) | `[Coverage: UNIT]` |
| `test/services/pass_fail_detector/regex_isolate_pool_test.dart` (reuse, correctness across reuse, kill-on-deadline, recovery, concurrency, `onTimeout`) | `[Coverage: UNIT]` |
| `test/services/trend_store/sql_trend_store_test.dart` (`recentDeltas` semantics retained) | `[Coverage: UNIT]` |

**Mutation.** Reverting `recentDeltas` to the per-test prior-status lookup makes
the 1-query guard report ~1 000 statements. Pruning each run's directory in
isolation instead of ranking across runs leaves 20 directories under a policy
promising 5, which fails the across-runs keep-last-N case. Charging pinned dirs in
mtime order rather than up front over-subscribes the cap by exactly the number
of pins — caught during development by the keep-marker case. All verified.

### 10.10 Cancel-path instance correctness + dispose-hook safety

- **What it does (plain language).** Two defects found while
  adversarially re-verifying §10.8 and §10.9, both on the path that
  tears a running regression down.

  1. **Cancel reaches the scheduler holding the run.** `JobSchedulerCache`
     is an LRU bounded at `kJobSchedulerCacheSize` distinct
     simulator-binary signatures. `RegressionRunner.cancel` re-resolved
     its scheduler with `schedulerFor(activeConfig)`, so once the cache
     had evicted the run's entry (or the config's `simulators:` block was
     edited, changing the key) it received a freshly built scheduler
     whose run table was empty and `JobScheduler.cancel` silently
     returned. Run teardown itself was never at risk — it rides the event
     stream's `onCancel`, which closes over the owning run state — so
     this was a latent no-op on the belt-and-braces half rather than a
     process leak. The runner now pins the scheduler instance at submit
     time.
  2. **Disposing a tab mid-run no longer aborts its own cleanup.**
     `_releaseActiveRunToken` ran from `ref.onDispose` and called
     `ref.read`, which Riverpod forbids inside a lifecycle callback. The
     resulting assertion aborted the rest of the dispose hook — the
     subscription cancel and the buffered-trend flush — so closing a tab
     with a run in flight both asserted and skipped its cleanup. The
     registry is now resolved eagerly in `build`.

- **Setup.** Open a project, start a long regression, then either close
  the tab or open four further projects with distinct simulator paths
  and press Stop.
- **Step-by-step expected behavior.** Stop cancels the run and its
  simulator processes in both cases; closing a tab mid-run raises no
  assertion in a debug build and still lands the run's buffered trend
  points.
- **Edge cases.** A run cancelled after its scheduler was evicted; a tab
  closed while its run is still dispatching.
- **Tier-gate.** None — open-core lifecycle behavior in both
  `kBetaPeriod` states.

**Automation Assessment.**

| Test | Coverage |
|---|---|
| `test/features/dashboard/providers/regression_runner_test.dart` (cancel after a forced LRU eviction tears the run down; asserts the eviction actually happened) | `[Coverage: UNIT]` |

**Mutation.** Restoring the `schedulerFor(activeConfig)` re-resolution
leaves the test green — teardown rides the subscription — which is why
the guarantee is documented as belt-and-braces rather than claimed as a
process-leak fix. Restoring the `ref.read` inside `onDispose` fails the
same test with Riverpod's `_debugCallbackStack == 0` assertion. Both
verified.

### 10.11 Query-count guards run in CI

The §10.9 query-count guards lived in `test/perf/trend_query_count_test.dart`.
`flutter test` globs `*_test.dart`, there is no perf job in `.github/workflows/`,
and so no `_bench.dart` file ran anywhere automatically — the guards passed
when invoked by hand but could not fail a build. The file is deterministic
(it counts SQL statements rather than measuring wall-clock) and completes in
about five seconds, so it is now `trend_query_count_test.dart` and runs with
every suite. The remaining `*_bench.dart` files are wall-clock harnesses and
stay opt-in by design.

## 11. About Box (suite-wide `crux_about_dialog`)

SimCrux adopts the cross-suite `crux_about_dialog` package the same way WaveCrux, NetCrux, and LintCrux do, replacing its former Material `showAboutDialog` stub (this section documents the real surface). `SimcruxAboutDialog.openAdaptive(context, ref)` (`lib/features/about/simcrux_about_dialog.dart`) maps SimCrux's branding (`aboutBrandingProvider`), build metadata (`aboutBuildInfoProvider`), edition label (`aboutEditionLabel`), and ARB chrome strings (`SimcruxAboutStrings`) onto the shared `CruxAboutDialog`. SimCrux is the simpler member of the suite: **no third-party attribution section** and only **two** action buttons (Visit Website + Copy Version Info). Tier and beta-period chips are driven by `crux_license` (`licenseTierProvider` / `betaPeriodProvider`) inside the shared widget. The About box is **not feature-gated** — it is reachable in every edition; only the chips change.

### What it does

- **Adaptive presentation** — a modal dialog on desktop (macOS/Windows/Linux), a pushed full-screen route on phone/tablet.
- **Header** — app icon (`Icons.bar_chart_rounded`), title "About SimCrux", tagline, and a chip row: Public Beta chip (while `betaPeriodProvider` is true), edition chip (hidden for Open Core), and the EDU `EditionBadge` for an Educational license.
- **Version section** — version, build number, commit SHA, OS, architecture, Flutter and Dart versions, sourced from `PackageInfo.fromPlatform()` + platform introspection.
- **Branding banner** — square Ferrite Engineering logo (falls back gracefully if the asset is absent), company tagline, and `© <year> <company>`.
- **Actions** — **Visit Website** (opens `ferriteengineering.com` via `url_launcher`) and **Copy Version Info** (copies the structured version paragraph to the clipboard, confirmed by a snackbar; disabled while build info is still loading).
- **Locale** — every chrome string flows through `SimcruxAboutStrings` (ARB keys `about*`), shipped across en / zh_CN / zh / ja / ko.

### Setup

- Launch SimCrux. Trigger Help → About SimCrux (menu bar), or the `openAbout` action via the command palette (Cmd/Ctrl+Shift+P → "About").

### Step-by-step verification

#### 11.1 Open + content

1. Invoke About SimCrux. **Expected:** the About box opens (dialog on desktop, route on mobile) with title "About SimCrux" and the simulation-dashboard tagline.
2. **Expected:** the Version section lists a version, build, commit, OS, architecture, Flutter, and Dart row. On a CI/dev build version/commit may read `dev` / `0`.
3. **Expected:** the branding banner shows "Ferrite Engineering" and the copyright line.

#### 11.2 Action buttons

1. Tap **Visit Website**. **Expected:** the system browser opens `https://ferriteengineering.com`.
2. Tap **Copy Version Info**. **Expected:** a snackbar confirms "Version info copied"; pasting elsewhere yields the structured paragraph (`SimCrux <ver> (build <n>)`, Edition, Git SHA, OS, Architecture, Flutter, Dart). The button is disabled if build info failed to resolve.

#### 11.3 Locale sweep

Switch the active locale to each of `en`, `zh_CN`, `ja`, `ko` and reopen the About box. **Expected:** title, tagline, section headers, row labels, and both button labels render in the active locale with no overflow.

### Tier-gate scenarios

The About box is always reachable; tier only changes the header chips. EDU is feature-equivalent to Pro but renders the EDU `EditionBadge` rather than a "Pro" edition chip.

| Build / tier | `kBetaPeriod = true` (beta) | `kBetaPeriod = false` (post-beta) |
|---|---|---|
| Open Core | Box opens; **Public Beta** chip shown; **no** edition chip | Box opens; no beta chip; no edition chip |
| Pro | Box opens; Public Beta chip + **Pro** edition chip | Box opens; **Pro** edition chip, no beta chip |
| Enterprise | Box opens; Public Beta chip + **Enterprise** edition chip | Box opens; **Enterprise** edition chip, no beta chip |
| EDU | Box opens; Public Beta chip + **EDU** `EditionBadge` | Box opens; **EDU** `EditionBadge`, no beta chip |

### Edge cases

| Scenario | Expected behavior |
|---|---|
| `aboutBuildInfoProvider` throws | Version section hidden; Copy Version Info button disabled; box still opens |
| Branding logo asset missing | Banner renders with a blank logo box (asset `errorBuilder`), text intact |
| Open Core edition | Edition chip suppressed (label equals `aboutEditionOpenCore`) |

### Automation assessment

| Test | Coverage | Assessment |
|---|---|---|
| Opens + shows "About SimCrux" title | `test/features/about/simcrux_about_dialog_test.dart` | **AUTOMATED — flutter test** |
| Version + commit SHA from stub build info | `test/features/about/simcrux_about_dialog_test.dart` | **AUTOMATED — flutter test** |
| Locale sweep (en/zh_CN/ja/ko) renders without exception | `test/features/about/simcrux_about_dialog_test.dart` | **AUTOMATED — flutter test** |
| Edition chip hidden for Open Core; EDU badge for edu tier | `test/features/about/simcrux_about_dialog_test.dart` | **AUTOMATED — flutter test** |
| Both action buttons present; Copy enabled once build info loads | `test/features/about/simcrux_about_dialog_test.dart` | **AUTOMATED — flutter test** |
| Visit Website actually launches the URL | — | **MANUAL** — OS-level url_launcher |
| Copy Version Info clipboard contents in a real session | — | **MANUAL** — OS clipboard |
| Beta chip presence keyed to real `kBetaPeriod` | — | **MANUAL** — build-flag dependent |

---

## 12. Update Mechanism (`crux_updates`)

### What it does

SimCrux checks a public JSON manifest for a newer release and, when one exists, shows a non-intrusive strip above the app content offering **View Changes** and **Update Now**. There is no in-place download or relaunch — Update Now deep-links to `https://simcrux.app/download`.

The mechanism is `package:crux_updates` (crux-shared); SimCrux supplies:

- **`simcruxUpdateConfig`** (`lib/core/update/simcrux_update_config.dart`) — product name `SimCrux`, manifest `https://updates.simcrux.app/manifest.json`, download page `https://simcrux.app/download`. No App Store / Play Store URIs and `checkOnMobile: false`: SimCrux ships no mobile target.
- **`SimcruxUpdateStrings`** (`lib/core/update/simcrux_update_strings.dart`) — the ARB adapter, five locales.
- **`simcruxUpdateOverrides`** (`lib/features/update/providers/update_overrides.dart`) — the six root-container bindings.
- **`ObservedServerTimeStore`** (`lib/features/update/providers/observed_server_time_provider.dart`) — the persisted, monotonic `server_time` watermark feeding beta expiry (§14).

Three behaviours are worth stating explicitly because they look like bugs if you do not expect them:

- **The banner never renders on the web dashboard.** A web build self-updates on deploy, so a "download the new version" strip would fire transiently around every release, between the manifest bump and the edge-cache expiry. The *check* still runs on web — its remaining job there is to observe `server_time` for the beta-expiry clock.
- **A failed check is silent.** `checking` and `error` render nothing. Only the manual **Check for Updates** action reports a failure.
- **`min_supported_version` is a floor, not a filter.** A newer release always surfaces; when the running build is *below* the floor the update is forced `mandatory` (and therefore non-dismissible) even if the manifest does not say so.

### Setup

- A build whose version is *older* than the manifest's `latest.version` (or a locally served manifest — point `simcruxUpdateConfig.manifestUri` at a file server for the manual pass).
- Network reachability to `updates.simcrux.app`, or a controlled substitute.
- Settings → General → **Automatically check for updates** in its default (on) state.

### Step-by-step verification

#### 12.1 Launch check and the banner

1. Launch SimCrux with a manifest advertising a newer version. **Expected:** within a second or two a strip appears above the app content reading "SimCrux `<version>` is available." with **View Changes**, **Update Now**, and a close (×) button.
2. Click **View Changes**. **Expected:** the browser opens the manifest's `changelog_url`. If the manifest carries no `changelog_url`, the button is absent rather than dead.
3. Click **Update Now**. **Expected:** the browser opens `https://simcrux.app/download`.
4. Click the × . **Expected:** the strip disappears and does not return this session.
5. Restart with the same manifest. **Expected:** the strip returns — the dismissal is per-session, per-version, not persisted.
6. Bump the manifest to a *newer* version and re-check. **Expected:** the strip returns even though the previous version was dismissed.

#### 12.2 Manual check

1. Help → **Check for Updates…** (also in the command palette, and as a button in the About box). **Expected:** a "Checking for updates…" snackbar, replaced by the outcome.
2. With the manifest at the running version: **Expected:** "You're on the latest version (`<version>`)."
3. With the manifest advertising a newer version: **Expected:** no "up to date" snackbar — the persistent banner is the report.
4. With `updates.simcrux.app` unreachable: **Expected:** "Couldn't check for updates." — non-fatal, no dialog, nothing else in the app is affected.

#### 12.3 The auto-check setting

1. Settings → General. **Expected:** an **Automatically check for updates** switch, on by default, with the "Only the app version and your operating system are sent" explanation beneath it.
2. Turn it off, quit, relaunch. **Expected:** no launch check fires (verify with a proxy / server log: zero requests to the manifest URL) and no banner appears even though a newer version is advertised.
3. With the setting still off, run Help → **Check for Updates…**. **Expected:** the check runs and reports its outcome. A manual request always runs.
4. Turn it back on and relaunch. **Expected:** the launch check fires again.

#### 12.4 Mandatory updates

1. Serve a manifest with `"mandatory": true`. **Expected:** the strip renders with **no** × button — there is no way to dismiss it.
2. Serve a manifest whose `min_supported_version` is *above* the running version, with `"mandatory": false`. **Expected:** the strip is still non-dismissible — a build below the floor is no longer supported.

#### 12.5 What the check transmits

1. Watch the request with a proxy. **Expected:** exactly one `GET` for the manifest JSON, with a single `User-Agent` of the form `SimCrux/<version> (macOS 15.0)`, and **no** body. No project path, no config, no test names, no results, no identity — ever.

#### 12.6 Web dashboard

1. Build the web dashboard viewer and load it with a manifest advertising a newer version. **Expected:** no banner. The manifest fetch still occurs (visible in the network panel) so the `server_time` watermark advances.

### Tier-gate scenarios

The update mechanism is **open-core, every tier, in every build**. `SimcruxAction.checkForUpdates.requiredTier` is `LicenseTier.openCore`, so no `SimCruxFeatureTierBadge` renders in the command palette and no `" (PRO)"` suffix appears on the native menu bar. Staying on a current build is not a paid feature.

| Build / tier | `kBetaPeriod = true` (beta) | `kBetaPeriod = false` (post-beta) |
|---|---|---|
| Open Core | Banner + manual check available; no badge | Identical — no gate, no badge |
| Pro | Identical to Open Core | Identical to Open Core |
| Enterprise | Identical to Open Core | Identical to Open Core (managed update channels do not exist) |
| EDU | Identical to Open Core | Identical to Open Core |

### Edge cases

| Scenario | Expected behavior |
|---|---|
| Manifest returns HTTP 500 | Status → error; banner renders nothing; manual check says "Couldn't check for updates." |
| Manifest is malformed JSON | Same as above — `UpdateManifest.tryParse` fails soft, never throws |
| Manifest `latest` lacks `version` | Treated as "no update info"; status → current |
| A manifest field has the wrong type | That field is dropped; the rest of the release parses |
| Check fires before build info resolves | `NoopUpdateCheckService` reports "current" rather than comparing against an unknown version |
| `cruxUpdateConfigProvider` unbound | Throws at app wiring, loudly — never silently stops checking |
| `updateUrlLauncherProvider` unbound | Throws when Update Now is pressed — never a dead button |
| App resumed from background | A gated re-check fires (honours the auto-check setting) |
| Container torn down mid-fetch | The server-time sink was captured at construction; the callback does not reach back through a disposed `ref` |

### Automation assessment

| Test | Coverage | Assessment |
|---|---|---|
| Config names SimCrux and the right endpoints; `updateTargetFor` on every platform | `test/core/update/simcrux_update_config_test.dart` | **AUTOMATED — flutter test** |
| Beta-expiry download target does not drift from the config's download page | `test/core/update/simcrux_update_config_test.dart` | **AUTOMATED — flutter test** |
| Every string getter resolves + interpolates in en / zh_CN / ja / ko | `test/core/update/simcrux_update_strings_test.dart` | **AUTOMATED — flutter test** |
| Launch check: newer version → available; same version → current | `test/features/update/update_status_machine_test.dart` | **AUTOMATED — flutter test** |
| Auto-check off suppresses launch + scheduled checks (zero fetches) | `test/features/update/update_status_machine_test.dart` | **AUTOMATED — flutter test** |
| `checkNow()` runs with auto-check off | `test/features/update/update_status_machine_test.dart` | **AUTOMATED — flutter test** |
| HTTP failure and malformed manifest resolve to error, never a throw | `test/features/update/update_status_machine_test.dart` | **AUTOMATED — flutter test** |
| Build below `min_supported_version` forced mandatory | `test/features/update/update_status_machine_test.dart` | **AUTOMATED — flutter test** |
| `server_time` recorded on every successful fetch, including "current" | `test/features/update/update_status_machine_test.dart` | **AUTOMATED — flutter test** |
| Request is a bodyless GET to the SimCrux manifest with a product User-Agent | `test/features/update/update_status_machine_test.dart` | **AUTOMATED — flutter test** |
| Every `crux_updates` seam is actually bound by `simcruxUpdateOverrides` | `test/features/update/providers/update_overrides_test.dart` | **AUTOMATED — flutter test** |
| Settings toggle reaches `autoUpdateCheckEnabledProvider` | `test/features/update/providers/update_overrides_test.dart` | **AUTOMATED — flutter test** |
| Banner: current / checking / error render nothing | `test/features/update/widgets/update_banner_test.dart` | **AUTOMATED — flutter test** |
| Banner: mandatory renders no dismiss affordance | `test/features/update/widgets/update_banner_test.dart` | **AUTOMATED — flutter test** |
| Banner: dismissal hides the strip for the session | `test/features/update/widgets/update_banner_test.dart` | **AUTOMATED — flutter test** |
| Banner: Update Now opens the SimCrux download page | `test/features/update/widgets/update_banner_test.dart` | **AUTOMATED — flutter test** |
| Banner actions clear the 44 dp touch-target floor | `test/features/update/widgets/update_banner_test.dart` | **AUTOMATED — flutter test** |
| Banner locale sweep (en / zh_CN / ja / ko) with no overflow | `test/features/update/widgets/update_banner_test.dart` | **AUTOMATED — flutter test** |
| `autoCheckForUpdates` codec round-trip + default-on | `test/services/settings/simcrux_settings_codec_test.dart` | **AUTOMATED — flutter test** |
| Settings → General toggle renders, clears 44 dp, and persists | `test/features/settings/widgets/settings_general_section_test.dart` | **AUTOMATED — flutter test** |
| `checkForUpdates` is open-core, in Help, in menu + palette, localized | `test/core/shortcuts/beta_infrastructure_actions_test.dart` | **AUTOMATED — flutter test** |
| A real browser actually opens the download / changelog page | — | **MANUAL** — OS `url_launcher` |
| The banner never renders in a real web build | — | **MANUAL** — web build required |
| Periodic (24 h) re-check fires | — | **MANUAL** — wall-clock dependent (the gating path it shares with the launch check is automated) |
| Resume-from-background re-check | — | **MANUAL** — OS lifecycle event |
| Real proxy capture of the outbound request | — | **MANUAL** — network observation |

---

## 13. Beta Issue Reporter (`crux_issue_reporter`)

### What it does

An in-app "file a GitHub issue with my diagnostics attached" flow, reachable from Help → **Submit Issue…**, the command palette, and the About box. It collects structured, privacy-scrubbed context; lets the user review and switch off any category; shows a live markdown preview of the exact issue body; and on submit copies the body to the clipboard, opens the pre-filled GitHub new-issue page, and (desktop) writes the screenshot PNG to the OS temp directory and reveals it in the file manager.

Reports are filed against **`Ferrite-Engineering/simcrux`** using the `bug_report.yml` template. The slug is fixed, not keyed off `kBetaPeriod`.

Categories:

| Category | Default | Content |
|---|---|---|
| App & Environment | always on, locked | Product, version, build SHA, platform, OS, architecture, DPI, locale, Flutter/Dart SDK versions |
| Session State | on | SimCrux's contributor — see the privacy contract below |
| Diagnostics | on | The last 100 WARNING+ ring-buffer entries plus the last 20 at any level |
| Screenshot | on, desktop only | Flutter-layer `RepaintBoundary` capture, previewed as a thumbnail |

### The privacy contract — read this before signing off

SimCrux sessions are saturated with private strings: the project directory, every source and testbench path, dump and log paths, and the user's own suite / test / top-module names. **None of it may reach a public GitHub issue.** What the Session State category carries is counts, a fixed vocabulary of simulator ids, scrubbed tool-version banners, and enum names:

`Open project tabs`, `Active project` (`loaded` / `(none loaded)` — never the path), `Config schema version`, `Suites`, `Tests`, `Configured simulators`, `Simulator binary overrides` (**count only**, never the paths), `Registered drivers`, `Detected versions`, `Run state`, `Tests in run`, `Results recorded`, `Passed`, `Failed`.

Deliberately excluded, and each for a reason:

- `RegressionConfig.projectFilePath` — a path, and often the employer / project name.
- `Suite.name`, `TestSpec.name`, `TestSpec.top` — user-authored testbench and DUT identifiers; frequently the most confidential strings in the session.
- `TestResult.stdoutPath` / `stderrPath` / `waveformPath` / `failureMessage` — paths, and log text that quotes the design.
- `cruxIssueDiagnosticsReportProvider` is left **unbound**. SimCrux's own "Copy Full Diagnostics Report" opens with `Config: <projectFilePath>`; it is fine on the user's clipboard, where they pick the recipient, but folding it into a public issue body would breach the contract.
- Simulator `--version` banners are third-party output, so any whitespace-delimited token containing `/`, `\`, or a Windows drive prefix is replaced with `(redacted)` before it reaches the report.

### Setup

- Open a real project with real on-disk paths and run a regression to completion (at least one pass and one fail), so the report is exercised against a populated session rather than an empty one.
- Desktop build (the Screenshot category is hidden on web).

### Step-by-step verification

#### 13.1 Open and content

1. Help → **Submit Issue…**. **Expected:** a modal dialog titled "Submit Issue" with an Issue Summary field, the privacy callout, four category tiles, and a collapsed "Preview issue body" disclosure.
2. Expand the preview. **Expected:** the markdown body updates live as categories are toggled.
3. **Expected:** the App & Environment tile shows a lock affordance and cannot be switched off.

#### 13.2 THE PRIVACY PASS — do this on every release

1. Expand the preview and read the **Session State** section line by line.
2. **Expected:** not one `/` or `\` anywhere in it. Not the project directory, not a source file, not a dump or log path, not a binary-override path.
3. **Expected:** no suite name, no test name, no top-module name — only counts.
4. **Expected:** `Simulator binary overrides` is a bare number.
5. **Expected:** `Detected versions` reads like `icarus Icarus Verilog version 12.0 (stable); verilator Verilator 5.020`. If a locally built toolchain prints its install prefix, that token reads `(redacted)`.
6. Scan the **Diagnostics** section for the same. Log lines are the app's own; if any of them quotes a user path, that is a defect in the *logging call site* — file it.

#### 13.3 Category toggles

1. Switch off Session State. **Expected:** the section disappears from the preview.
2. Switch off Diagnostics, then Screenshot. **Expected:** each disappears; the App & Environment section always remains.

#### 13.4 Submit

1. Type a summary and press **Submit**. **Expected:** the browser opens `github.com/Ferrite-Engineering/simcrux/issues/new` with the `bug_report.yml` template, the title pre-filled from the summary, and the body pre-filled when it fits.
2. **Expected:** the body is also on the clipboard either way.
3. With a very large report (long log), **Expected:** the body is dropped from the URL and the toast says to paste from the clipboard instead.
4. On desktop with the Screenshot category on: **Expected:** the toast names the temp path the PNG was written to, and the file manager reveals it.
5. Leave the summary blank and submit. **Expected:** the issue title falls back to a SimCrux-named default rather than being empty.

#### 13.5 Early-startup log capture

1. Launch SimCrux with a deliberately broken `simcrux.yaml` on the command line so the config loader logs a warning during startup.
2. Open the reporter without doing anything else. **Expected:** that startup warning is already in the Diagnostics section — the ring buffer is attached in `bootstrap()` before the first provider is constructed.

#### 13.6 Locale sweep

Switch the locale to each of `en`, `zh_CN`, `ja`, `ko` and reopen the reporter. **Expected:** dialog title, field labels, privacy notice, all four category titles and descriptions, both buttons, and the toasts render in the active locale with no overflow. **Expected:** the markdown *body* stays English — that is deliberate; the body is read by maintainers in the repository and a mixed-language body makes triage harder.

### Tier-gate scenarios

The reporter is **open to every tier, in every build** — no `SimCruxFeatureTierBadge`, no `FeatureGate`. Gating it would mean the users most likely to hit a beta bug (open-core users) are the ones who cannot report it.

| Build / tier | `kBetaPeriod = true` | `kBetaPeriod = false` |
|---|---|---|
| Open Core | Reporter opens; no badge; files to `Ferrite-Engineering/simcrux` | Identical — the slug does not track the flag |
| Pro | Same, plus the overlay's **Pro State** category (see the Pro overlay guide) | Same, plus Pro State |
| Enterprise | Same as Pro | Same as Pro |
| EDU | Same as Open Core | Same as Open Core |

The `kBetaPeriod` flip is the only tier-adjacent behaviour change, and it changes the *repository slug*, not availability. Verify by inspecting the opened URL host path.

### Edge cases

| Scenario | Expected behavior |
|---|---|
| No project open | Session State still renders, with `Active project: (none loaded)` and zero counts |
| Version probe has not resolved | `Detected versions: (not detected)`; the tiles refresh in place once it does |
| A simulator is not installed | It is simply absent from `Detected versions` — no error, no empty entry |
| Bare/unwired provider scope | The contributor catches and returns what it has; opening the reporter never crashes |
| `cruxIssueReporterConfigProvider` unbound | Throws `CruxIssueReporterUnconfiguredError` — never files against the wrong repository |
| Web build | Screenshot tile hidden (no temp-dir reveal) |
| Report body exceeds 6000-char URL cap | Body dropped from the URL, clipboard carries it, toast says so |

### Automation assessment

| Test | Coverage | Assessment |
|---|---|---|
| **PRIVACY: a Session State body carries no file paths** — driven from a loaded project with real on-disk paths and a completed run | `test/features/issue_reporter/issue_reporter_session_context_test.dart` | **AUTOMATED — flutter test** |
| PRIVACY: the Pro-overlay `attributes` map carries no paths either | `test/features/issue_reporter/issue_reporter_session_context_test.dart` | **AUTOMATED — flutter test** |
| PRIVACY: a path-bearing `--version` banner cannot reach the body | `test/features/issue_reporter/issue_reporter_session_context_test.dart` | **AUTOMATED — flutter test** |
| `scrubVersionBanner` redacts POSIX prefixes, Windows paths, drive prefixes | `test/features/issue_reporter/issue_reporter_session_context_test.dart` | **AUTOMATED — flutter test** |
| Session State reports the right counts from a populated session | `test/features/issue_reporter/issue_reporter_session_context_test.dart` | **AUTOMATED — flutter test** |
| Contributor degrades to a valid snapshot in a bare scope | `test/features/issue_reporter/issue_reporter_session_context_test.dart` | **AUTOMATED — flutter test** |
| Config names SimCrux + the beta repo + the `bug_report.yml` template | `test/features/issue_reporter/issue_reporter_overrides_test.dart` | **AUTOMATED — flutter test** |
| The diagnostics-report seam stays unbound (it carries a path) | `test/features/issue_reporter/issue_reporter_overrides_test.dart` | **AUTOMATED — flutter test** |
| Open-core contributes no overlay categories | `test/features/issue_reporter/issue_reporter_overrides_test.dart` | **AUTOMATED — flutter test** |
| Every string getter resolves in en / zh_CN / ja / ko | `test/core/issue_reporter/simcrux_issue_reporter_strings_test.dart` | **AUTOMATED — flutter test** |
| `submitIssue` is open-core, in Help, in menu + palette, localized | `test/core/shortcuts/beta_infrastructure_actions_test.dart` | **AUTOMATED — flutter test** |
| The real GitHub page opens with the template and pre-filled body | — | **MANUAL** — OS `url_launcher` + GitHub |
| Clipboard contents in a real session | — | **MANUAL** — OS clipboard |
| Screenshot PNG written and revealed in Finder / Explorer | — | **MANUAL** — OS file manager |
| Startup warnings present in the ring buffer at first open | — | **MANUAL** — real launch required |
| Over-long body falls back to clipboard-only | — | **MANUAL** — needs a real oversized report |

---

## 14. Beta Expiry Gate (`crux_license` + `crux_updates`)

### What it does

Each public-beta build carries its own shelf life, injected at build time with `--dart-define=BETA_EXPIRY=<yyyymmdd>`. Inside the warning window (default 7 days, `--dart-define=BETA_EXPIRY_WARNING_DAYS=<n>`) SimCrux shows a dismissible strip; on and after the expiry date it shows a blocking, non-dismissable modal offering **Download latest build** and **Quit SimCrux**.

`BETA_EXPIRY` absent, `0`, or not a real calendar date means **the build never expires** — which is every developer build. Expiry also applies only while `kBetaPeriod` is `true`; a post-beta production build never expires regardless of the define.

This is distinct from `kBetaPeriod`, which governs feature *gating* and flips once at the beta-to-production transition. This governs one build's shelf life and moves with every beta drop.

**Clock hardening.** The status is reckoned against `trustedBetaExpiryNow(DateTime.now(), observedServerTime: …)` — the *later* of the device clock and the manifest `server_time` watermark persisted by `ObservedServerTimeStore` (§12). Winding the device clock back therefore cannot defer expiry below the last server time SimCrux has observed. A never-online install has no watermark and is reckoned by the device clock alone; that is accepted, because the mechanism exists to retire stale builds, not to resist a determined attacker.

The gate sits inside `MaterialApp.builder`, **outside** the `UpdateBanner`, so a blocking expiry modal covers the update strip.

### Setup

Build with an explicit expiry date. Three builds cover the whole surface:

```bash
# Active — expiry far away
flutter run -d macos --dart-define=BETA_EXPIRY=20991231

# Expiring soon — 3 days out (set the date accordingly)
flutter run -d macos --dart-define=BETA_EXPIRY=<today+3>

# Expired — yesterday
flutter run -d macos --dart-define=BETA_EXPIRY=<yesterday>
```

### Step-by-step verification

#### 14.1 The common case — no expiry

1. Launch a plain `flutter run` build with no `--dart-define`. **Expected:** nothing. No banner, no modal, app content untouched. This is what every developer and every post-beta user sees.

#### 14.2 Active

1. Launch the `BETA_EXPIRY=20991231` build. **Expected:** nothing — the expiry is outside the warning window.

#### 14.3 Expiring soon

1. Launch the today+3 build. **Expected:** a strip above the app content reading "SimCrux Beta expires in 3 days. Download the latest build." with a **Download** action and a close (×) button.
2. Set the date to today+1 and relaunch. **Expected:** the singular form — "expires in 1 day", not "in 1 days".
3. Click **Download**. **Expected:** the browser opens `https://simcrux.app/download`.
4. Click ×. **Expected:** the strip disappears for the session and the app is fully usable.
5. Send the app to the background and bring it back. **Expected:** the strip returns — the dismissal is cleared on resume so a returning user is reminded again.

#### 14.4 Expired

1. Launch the yesterday build. **Expected:** a dimming barrier over the app and a centred card: "Beta build expired", the explanatory body, **Download latest build**, and **Quit SimCrux**.
2. Try to interact with anything behind the barrier. **Expected:** nothing responds.
3. Try the system back gesture / Escape. **Expected:** the modal does not close.
4. Click **Download latest build**. **Expected:** the browser opens the download page; the modal stays.
5. Click **Quit SimCrux**. **Expected:** the app shuts down *orderly* — any in-flight simulator process tree is reaped first (check with `ps` that no `vvp` / `verilator` / `make` child survives), then the process exits. This action is load-bearing on Windows and Linux, where the custom window chrome's close button sits behind the barrier.

#### 14.5 Clock rollback

1. Launch the today+3 build once with network access, so a `server_time` watermark is persisted.
2. Quit. Set the system clock back two months. Relaunch **offline**.
3. **Expected:** the warning banner is still shown (or the modal, if the watermark is already past the expiry). Rolling the clock back does not buy more beta.
4. Reset the clock.

#### 14.6 Mid-session stability

1. Launch a build that will cross into `expiringSoon` in a few minutes and start a long regression.
2. **Expected:** the run is never interrupted. The status is evaluated at startup and on the resume lifecycle edge only — never mid-session.

### Tier-gate scenarios

Beta expiry is **not** a tier feature — it is a property of the build, and it applies identically to every tier. What gates it is `kBetaPeriod`, not `licenseTierProvider`.

| Build / tier | `kBetaPeriod = true` (beta) | `kBetaPeriod = false` (post-beta) |
|---|---|---|
| Open Core | Banner / modal per the injected `BETA_EXPIRY` | **Never expires** — `kBetaExpiry` resolves to `null` regardless of the define |
| Pro | Identical to Open Core | Never expires |
| Enterprise | Identical to Open Core | Never expires |
| EDU | Identical to Open Core | Never expires |

Post-beta verification: build with `kBetaPeriod = false` **and** `--dart-define=BETA_EXPIRY=<yesterday>` and confirm the app launches with no modal. That is the single most important post-beta assertion in this section — a production build that inherits a stale beta expiry would brick itself in the field.

### Edge cases

| Scenario | Expected behavior |
|---|---|
| `BETA_EXPIRY` absent or `0` | Never expires; gate renders its child untouched |
| `BETA_EXPIRY=20261301` (month 13) or `20260230` (Feb 30) | Treated as absent, **not** as expired |
| Expiry date is today | `expired` — expiry is reckoned in whole calendar days and lands at the start of the date |
| Exactly `warningDays` out | `expiringSoon`; one day further out is still `active` |
| Device clock ahead of the watermark | The device clock wins (forward motion is never resisted) |
| Never-online install | No watermark; device clock governs; app keeps working |
| Stale / replayed manifest with an older `server_time` | The watermark is monotonic and does not move backwards |
| Auto-check turned off | The watermark stops advancing; expiry falls back to the device clock, exactly as on a never-online install |

### Automation assessment

| Test | Coverage | Assessment |
|---|---|---|
| `notApplicable` / `active` render the app untouched | `test/features/beta_expiry/beta_expiry_gate_test.dart` | **AUTOMATED — flutter test** |
| `expiringSoon` renders the dismissible banner with the day count | `test/features/beta_expiry/beta_expiry_gate_test.dart` | **AUTOMATED — flutter test** |
| The banner is dismissible for the session | `test/features/beta_expiry/beta_expiry_gate_test.dart` | **AUTOMATED — flutter test** |
| `expired` renders the blocking modal with no dismiss affordance | `test/features/beta_expiry/beta_expiry_gate_test.dart` | **AUTOMATED — flutter test** |
| The expired modal blocks the system back gesture (`canPop: false`) and the barrier is non-dismissible | `test/features/beta_expiry/beta_expiry_gate_test.dart` | **AUTOMATED — flutter test** |
| Both Download actions open the SimCrux download page | `test/features/beta_expiry/beta_expiry_gate_test.dart` | **AUTOMATED — flutter test** |
| Quit routes through the `AppExitCoordinator` + `processExit` seam | `test/features/beta_expiry/beta_expiry_gate_test.dart` | **AUTOMATED — flutter test** |
| Every affordance clears the 44 dp touch-target floor | `test/features/beta_expiry/beta_expiry_gate_test.dart` | **AUTOMATED — flutter test** |
| Banner + modal locale sweep (en / zh_CN / ja / ko) with no overflow | `test/features/beta_expiry/beta_expiry_gate_test.dart` | **AUTOMATED — flutter test** |
| ICU `=1` singular differs from the plural form | `test/features/beta_expiry/beta_expiry_gate_test.dart` | **AUTOMATED — flutter test** |
| **Clock rollback cannot defer expiry below the watermark** | `test/features/beta_expiry/beta_expiry_clock_tampering_test.dart` | **AUTOMATED — flutter test** |
| No watermark ⇒ device clock governs (offline install keeps working) | `test/features/beta_expiry/beta_expiry_clock_tampering_test.dart` | **AUTOMATED — flutter test** |
| A replayed stale `server_time` does not weaken expiry | `test/features/beta_expiry/beta_expiry_clock_tampering_test.dart` | **AUTOMATED — flutter test** |
| The store → `crux_license` override is actually wired | `test/features/beta_expiry/beta_expiry_clock_tampering_test.dart`, `test/features/update/providers/update_overrides_test.dart` | **AUTOMATED — flutter test** |
| Absent / invalid `BETA_EXPIRY` means never-expires | `test/features/beta_expiry/beta_expiry_clock_tampering_test.dart` | **AUTOMATED — flutter test** |
| Warning-window boundary (active / expiringSoon / expired) | `test/features/beta_expiry/beta_expiry_clock_tampering_test.dart` | **AUTOMATED — flutter test** |
| Watermark is monotonic and survives relaunch | `test/features/update/providers/observed_server_time_provider_test.dart` | **AUTOMATED — flutter test** |
| Real `--dart-define=BETA_EXPIRY` build actually expires | — | **MANUAL** — build-flag dependent |
| `kBetaPeriod = false` build ignores a stale `BETA_EXPIRY` | — | **MANUAL** — build-flag dependent, **release-blocking** |
| Resume-edge re-evaluation and dismissal reset | — | **MANUAL** — OS lifecycle event |
| Quit reaps a real simulator process tree | — | **MANUAL** — needs a live run |
| Real system-clock rollback | — | **MANUAL** — OS clock change |

---

## 15. macOS release-build file access (sandbox entitlement)

- **What it does.** SimCrux's macOS **release** build must be able to present
  `NSOpenPanel`. The `file_selector` plugin refuses to open the panel unless the
  app declares `com.apple.security.files.user-selected.read-write`, even when
  `com.apple.security.app-sandbox` is `false`. Debug builds mask the problem,
  because `DebugProfile.entitlements` carries broader permissions.
- **Why this section exists.** The 2026-07-16 marketing-screenshot session found
  the release build dead on this path: every picker invocation surfaced
  `PlatformException(ENTITLEMENT_NOT_FOUND, ...)`. Opening a file by CLI argument
  still worked, which is exactly why it survived earlier testing — **the failure
  is invisible to anyone who launches with a path.** Fixed 2026-07-21 by
  mirroring WaveCrux's `Release.entitlements` in both this repo and the Pro
  overlay.
- **Setup.** `flutter build macos --release`, then launch the produced `.app`
  from Finder (not `flutter run`, and not with a positional path argument).
- **Steps and expected behavior.**
  1. With no file loaded, invoke **File → Open Regression Config…**. Expected: the macOS open panel
     appears. Failure mode to watch for: a snackbar reading
     `ENTITLEMENT_NOT_FOUND`.
  2. Choose a file. Expected: it loads normally.
  3. Confirm the key is present in the shipped binary:
     `codesign -d --entitlements - <path>.app` must list
     `com.apple.security.files.user-selected.read-write`.
- **Edge cases.** Drag-and-drop and CLI-argument opening bypass the panel
  entirely and will keep working even when the entitlement is missing — so
  neither is a substitute for step 1.
- **Tier-gate scenarios.** None. File opening is open-core and ungated; the
  behavior is identical under `kBetaPeriod = true` and `false`.

### Automation Assessment

| Check | Automatable? | How |
|---|---|---|
| Entitlement key present in both repos' `Release.entitlements` | **Yes** | Static test parsing the plist; guards against a Flutter-tooling regeneration silently dropping it |
| Release `.app` ships the entitlement | Partly | `codesign -d --entitlements -` in release CI, post-build |
| Open panel actually appears | **No** | Requires a signed release build and a real window server — manual, per release |

## 16. Launch restore: tab dedupe + `restoreTabsOnLaunch`

- **What it does.** On launch SimCrux rehydrates the tabs from the previous
  session, then opens whatever the command line names. Two rules govern that:
  a config the workspace already holds is **focused**, not opened a second
  time; and the whole rehydration is skipped when the user has turned
  **restore tabs on launch** off.
- **Why this section exists.** A screenshot session during the beta found
  neither rule implemented (LintCrux had the same defect).
  Relaunching with the same positional `simcrux.yaml` produced a second tab for
  it every time, without bound — LintCrux reached seven tabs of one project —
  and setting `flutter.settings.restoreTabsOnLaunch` to `false` restored the
  tabs anyway, because nothing between `WorkspaceService.load()` and the
  rendered tab bar consulted the preference. Fixed 2026-07-21 in
  `crux_workspace` (`WorkspaceCodec.identityOf` +
  `WorkspaceNotifier.openTab(dedupe:)` + `shouldRestoreOnLaunch`), wired here
  by `SimcruxWorkspaceCodec.identityOf` and
  `SimcruxWorkspaceNotifier.shouldRestoreOnLaunch`.
- **What "the same config" means.** Identity is the *canonical* path —
  absolute, `.`/`..` collapsed, trailing separator dropped, symlinks resolved,
  and case-folded on macOS and Windows. It is deliberately **not** the raw
  string, because a raw string does not survive any of those spellings and
  each mismatch is a duplicate tab that comes back every launch.

### Setup

Use a real config on disk, and know where the state lives:

- Tabs and panes: `~/Library/Application Support/com.ferriteengineering.simcruxPro/workspace.json`
- Project registry (Pro overlay; can re-seed a tab on its own):
  `~/Library/Application Support/com.ferriteengineering.simcruxPro/simcrux/workspace.json`
- Per-tab sidecars: `~/Library/Application Support/com.ferriteengineering.simcruxPro/sessions/`

**A full session reset means deleting all three.** Deleting only the first is
what made this bug look unkillable during the beta report — the registry file
re-opens the active project's tab by itself.

### Step-by-step verification

1. **Baseline.** Delete all three locations above. Launch with a positional
   config: `SimCrux.app/Contents/MacOS/SimCrux /path/to/cpu/simcrux.yaml`.
   Expected: exactly one tab.
2. **Relaunch, same argument.** Quit and relaunch with the identical argument.
   Expected: still exactly **one** tab, and it is the focused tab. Failure mode
   to watch for: two tabs with the same name.
3. **Relaunch five more times.** Expected: still one tab. This is the check
   that matters — the original defect was linear growth, so a single relaunch
   is not conclusive if the first launch happened to start empty.
4. **Relative argument.** From the config's parent directory, launch with
   `./cpu/simcrux.yaml`. Expected: focuses the existing tab; no new tab.
5. **Symlink argument.** `ln -s /path/to/cpu/simcrux.yaml /tmp/alias.yaml`,
   then launch with `/tmp/alias.yaml`. Expected: focuses the existing tab.
   (On macOS `/tmp` is itself a symlink to `/private/tmp`, so this exercises
   two levels at once.)
6. **Case variant.** Launch with the path retyped in a different case.
   Expected on macOS: focuses the existing tab.
7. **Distinct configs.** Launch with two different `simcrux.yaml` paths.
   Expected: two tabs. Dedupe must not over-merge.
8. **Blank tabs.** Press the tab bar's **+** twice. Expected: two `(new tab)`
   tabs. A payload with no config has no identity and must never be folded.
9. **Restore off.** Quit. Set the preference to `false`:
   `defaults write com.ferriteengineering.simcruxPro flutter.settings.restoreTabsOnLaunch -bool NO`.
   Relaunch with **no** argument. Expected: empty canvas, no tabs.
10. **Restore off is not destructive.** Confirm `workspace.json` still contains
    the previous tabs (`cat` it). Set the preference back to `true` and
    relaunch. Expected: the tabs come back. A restore gate that deleted the
    document would fail here.
11. **Restore off plus an argument.** With the preference `false`, relaunch
    with a positional config. Expected: exactly one tab — the command-line
    one — and nothing from the previous session.
12. **Restore on plus an argument.** With the preference `true` and a
    two-tab session persisted, relaunch naming one of those two configs.
    Expected: two tabs, the named one focused. Not three.

### Diagnostics-assisted verification

`workspace.json` is plain JSON — `jq '.tabs[].configPath'` on it after each
relaunch is the fastest way to see growth. The count should be stable across
launches; a count that increments by one per launch is the original bug.

### Edge cases

- **A restored config that has since been deleted from disk.** The tab is kept
  (identity canonicalization fails soft rather than throwing); the tab surfaces
  its own load error. It must not silently vanish, and it must still dedupe
  against a command-line open of the same path.
- **The Pro project registry.** With the Pro overlay installed, the registry's
  active project can open a tab of its own after restore. Verify step 2 with
  the Pro build too, not just open core.
- **`--session` and `--workspace`.** `--workspace` replaces the workspace
  before positional configs are applied; `--session` opens a tab for the
  session's referenced config and dedupes on the same rule.

### Tier-gate scenarios

None. Workspace restore and command-line opening are open-core and ungated;
behavior is identical under `kBetaPeriod = true` and `false`. The Pro overlay
adds the project registry, which is covered by the edge case above rather than
by a tier gate.

### Automation Assessment

| Check | Automatable? | How |
|---|---|---|
| CLI open of an already-open config focuses instead of duplicating | **Yes** | `test/features/workspace/providers/workspace_restore_and_dedupe_test.dart` |
| Seven relaunches leave one tab | **Yes** | same file — the unbounded-growth guard |
| Relative / dot-segment / symlink / case spellings all dedupe | **Yes** | same file; the primitive itself is covered by `crux_io`'s `path_identity_test.dart` |
| Distinct configs stay distinct; blank tabs stay separate | **Yes** | same file — the over-merge guards |
| Duplicate positional arguments collapse on one command line | **Yes** | `test/features/dashboard/widgets/cli_regression_bootstrapper_test.dart` |
| `restoreTabsOnLaunch = false` starts clean, and is non-destructive | **Yes** | same file as row 1 |
| Restore-off / restore-on × CLI argument matrix | **Yes** | same file as row 1 |
| Unreadable settings store still restores | **Yes** | same file as row 1 |
| Registry-driven re-seed after restore (Pro overlay) | Partly | the Pro overlay's workspace-registry autosync integration test covers the sync; the launch interaction is manual |
| Real relaunch of a signed build against real app-support paths | **No** | Manual, per release — process lifecycle and the real storage directory |

## 17. Opening a config arms the tab; it does not run it (`autoRunOnOpen`)

- **What it does.** Opening a regression config — by command line, by
  File → Open, or by picking one from a blank tab — loads it and *arms* the
  tab: the config is published, the test browser fills, the file watcher
  starts. The regression itself waits for **Run Regression**. A Settings →
  General toggle, **off by default**, restores the old auto-start behaviour
  for users who want it.
- **Why this section exists, and the decision.** A screenshot session during
  the beta raised this as a *question* rather than a defect:
  opening a `simcrux.yaml` by CLI argument started the full regression at
  launch with no user action, while `CliRegressionBootstrapper`'s own docs
  described the run as armed rather than started. **Auto-start on open is
  unintended.** The reasoning is worth keeping, because the opposite reading
  is defensible for a tool whose job is running regressions: opening a file
  should not launch two hundred tests, and in a real setup a misclick then
  also checks out simulator licences. This was decided, not drifted into — do
  not "fix" it back without a deliberate product decision.
- **What is explicitly unchanged.** The auto-reload path. "Sources changed —
  Re-run now?" and `AutoReloadMode.auto` are about a run the user already
  started, and are already an explicit opt-in of their own. `autoRunOnOpen`
  does not gate them.

### Setup

A real `simcrux.yaml` with at least a couple of tests, and a simulator that
takes long enough to observe (or simply watch the run state, below).

### Step-by-step verification

1. **Default is armed, not running.** On a profile that has never touched the
   setting, launch with a positional config. Expected: the dashboard renders,
   the test browser lists every test, the run controls are idle, and **no
   tests execute**. Failure mode to watch for: results streaming in
   immediately.
2. **Run is one press away.** Press **Run Regression** (toolbar, `Cmd/Ctrl+R`,
   or the command palette). Expected: the run starts normally. Arming must not
   have left the tab in a state that needs a reload first.
3. **Opt in.** Settings → General → **Run the regression when a config is
   opened** → on. Quit, relaunch with the same positional config. Expected:
   the regression starts by itself, exactly as it used to.
4. **Opt back out.** Turn the toggle off, relaunch. Expected: armed, not
   running, again.
5. **Other open paths.** With the toggle off, open a config via File → Open
   and via a blank tab's picker. Expected: both arm, neither runs.
6. **A config that will not parse.** With the toggle off, open a `simcrux.yaml`
   with a YAML error. Expected: the tab shows "Couldn't load &lt;path&gt;: &lt;reason&gt;".
   Arming is not an excuse to swallow a broken file.
7. **Auto-reload is unaffected.** With the toggle off, start a run manually,
   let it finish, then touch a source file. Expected: the "Sources changed —
   Re-run now?" prompt behaves exactly as before, and `AutoReloadMode.auto`
   still re-runs without asking.

### Edge cases

- **Command-line launch before settings load.** The open path resolves the
  preference from the settings service when the in-memory settings have not
  arrived yet, so an opted-in user still gets the auto-start on the very first
  tab. An unreadable settings store resolves to **off** — never start a run
  nobody asked for.
- **Several positional configs at once.** With the toggle on, each opened tab
  starts its own run. That is the opt-in the user asked for, but it is the
  case worth watching on a licence-limited simulator.

### Tier-gate scenarios

None. Opening and running a regression are open-core and ungated; the setting
carries no `FeatureTierBadge` and behaves identically under `kBetaPeriod = true` and
`false`.

### Automation Assessment

| Check | Automatable? | How |
|---|---|---|
| Opening with the setting off publishes the config and starts no run | **Yes** | `test/features/dashboard/providers/auto_run_on_open_test.dart` |
| Opening with the setting on still starts the run | **Yes** | same file |
| A broken config still reports its load error when only arming | **Yes** | same file |
| The setting defaults to off and round-trips through preferences | **Yes** | `test/services/settings/simcrux_settings_codec_test.dart` |
| The Settings toggle renders off by default, persists, and clears 44 dp | **Yes** | `test/features/settings/widgets/settings_general_section_test.dart` |
| The *open* path passes the preference rather than a constant | Partly | covered by the widget wiring; the end-to-end launch is manual |
| A real launch executing (or not executing) real simulator processes | **No** | Manual, per release — needs a real simulator and process observation |

## 18. RISC-V architectural compatibility and formal proofs

Three features live here: the `golden_compare` detector (§18.1); the
`riscv_arch` driver with its `riscv:` block, toolchain probe and demo mode
(§18.2); and the `riscv_formal` driver that runs the riscv-formal check set
through SymbiYosys (§18.3).

### 18.1 The `golden_compare` detector

The seventh `pass_fail:` type. It
compares a file the DUT wrote against a committed golden reference, word
for word, and reports the **first** divergent word with its zero-based
offset.

**Read the name literally: it is not RISC-V-specific.** Comparing an
output against a golden and locating the first divergence is standard
practice in DSP, video, crypto and codec verification. RISC-V
architectural signatures are the flagship use and arrive as a
**profile**, not as the type. The `riscv_arch` driver is covered separately in §18.2.

#### What it does

```yaml
pass_fail:
  type: golden_compare
  profile: riscv_signature     # generic | riscv_signature
  dut: signature.dut.sig       # relative to the test's working directory
  reference: signature.ref.sig # absolute paths are allowed
```

- **`profile: riscv_signature`** folds case and an optional `0x` / `0X`
  prefix, and supplies both filenames as defaults so the two path keys
  can be omitted entirely.
- **`profile: generic`** (the default) compares words exactly. It has no
  conventional filenames, so both paths are required.
- **Whitespace is insignificant under both profiles** — any run of
  spaces, tabs, `\r` or `\n` separates words, so CRLF dumps, blank lines
  and trailing whitespace never change the verdict.
- **Leading zeros are never stripped.** `0000dead` and `dead` are
  different words under both profiles; folding them would hide a real
  divergence in a fixed-width dump.

#### Setup

The committed corpus is `verification/fixtures/golden_compare/`, eight
case directories each holding `case.json` (the inputs), the dump files,
and `expected.json` (the golden verdict + comparison + driver metrics).
Regenerate with:

```bash
dart run tool/generate_golden_compare_fixtures.dart
```

No toolchain, no simulator and no network are required for any of it.

#### Step-by-step expected behavior

1. **Clean pass.** Identical dumps ⇒ the test reports **pass**.
   (`clean_pass`)
2. **First-word divergence.** ⇒ **fail**, offset **0**. This is the
   boundary an off-by-one hides, so check the offset, not just the
   verdict. (`first_word_mismatch`)
3. **Mid-file divergence.** ⇒ **fail**, offset 3 in the fixture — proving
   the scan does not stop at the first word and does not report the
   *last* divergence. (`mid_file_mismatch`)
4. **Length divergence.** One dump is a strict prefix of the other ⇒
   **fail**, offset = where the shorter one ran out, and only the longer
   side carries a word. (`length_mismatch`)
5. **Format variance, RISC-V profile.** The same words re-spelled with
   CRLF, blank lines, uppercase hex and `0X` prefixes ⇒ **pass**.
   (`format_variance_riscv`)
6. **The same bytes under the generic profile** ⇒ **fail** at offset 0.
   The pair is what makes the profile observable — if both report the
   same verdict, the profile is not being honored.
   (`format_variance_generic`)

#### The two status traps — check these deliberately

Both are ways for a *missing* result to read as a *good* result, which in
a compatibility tool is the worst available failure mode. Every case
below **exits 0**, so without the detector the run reports pass.

7. **Empty DUT dump ⇒ fail.** Not `vacuous`. An empty dump is "the run
   did not do the thing it was asked to do", not "nothing to check". The
   scheduler treats `vacuous` as success-equivalent: no retry, and the
   working directory holding the evidence is **deleted**. Nothing in
   `lib/` produces `vacuous` today and this detector must not become the
   first thing that does. (`empty_dut`)
8. **Missing DUT dump ⇒ fail.** Not `unknown`. A detector returning
   `unknown` hands the verdict back to the *driver*, and a run that
   produced no output typically still exits 0 — so `unknown` would become
   **pass**. (`missing_dut`)
9. **Empty golden, missing golden, both sides empty, and a directory
   where a file was expected** are all likewise **fail**.

#### Edge cases

- **Absolute reference path.** A golden committed alongside the RTL,
  outside the run tree, is read as given.
- **Under a non-`riscv_arch` driver** — wiring `golden_compare` onto an
  ordinary Icarus or Verilator test that writes its own output file —
  the verdict is still correct, but **no `golden.*` offset metrics are
  emitted**, because no driver emitted them. A Pro diff viewer will show
  a verdict and no offset for such a test. This is expected, not a
  defect: a detector structurally cannot write metrics
  (`TestResult.metrics` is fed solely from
  `TestExecutionFinished.metrics`).
- **Synchronous classification fails loudly.** `golden_compare` is the
  only filesystem-backed detector, so it is reachable only from
  `PassFailDetectorRegistry.classifyAsync`, which carries the working
  directory. The synchronous `classify()` **throws** for it — including
  for a `golden_compare` leaf nested inside a `composite` — rather than
  degrading to `unknown` and silently inheriting the driver's status.
  Production always takes the async path.
- **`dut` and `reference` pointing at the same file** is a config error,
  refused at load time. It would otherwise always pass.
- **Config validation accumulates**: a `golden_compare` block missing
  both paths under the generic profile reports both errors in one load,
  not just the first.

#### Persistence

The offset rides `TestResult.metrics`, **not** a new typed field, under
five reserved keys: `golden.mismatch_offset`, `golden.dut_value`,
`golden.ref_value`, `golden.dut_words`, `golden.ref_words`. `TestResult`
reconstruction projects a fixed key list, so a new typed field would
survive the NDJSON write and die on hydrate; `metrics` round-trips
through the writer, hydrator, bundle writer, JSON exporter and web reader
untouched. The word-count pair is what lets a consumer tell a *content*
divergence from a *length* divergence without re-reading files retention
may already have pruned.

#### Tier-gate scenarios

**None, deliberately and permanently.** The compatibility pass/fail
verdict is open core and is never gated — not by `LicenseTier`, not by
`FeatureGate`, not by a row cap or a watermark, and **not after
`kBetaPeriod` flips to `false`**. Compatibility is RVI's own program and
monetizing the verdict itself would be read as tolling a standard.

Note the intentional asymmetry with the config loader's existing
`_parameterizationUnlocked` gate, which does gate `seeds:` / `parameters:`
sweep expansion. Sweeps are a productivity feature and are Pro; a
correctness verdict is free. A later consistency pass must **not** "fix"
the missing gate onto this path.

#### Automation Assessment

| Check | Automatable? | How |
|---|---|---|
| First-word / mid-file / length / clean-pass comparison semantics | **Yes** | `test/domain/models/golden_comparator_test.dart` |
| Profile normalization (case, `0x`, leading zeros, whitespace) | **Yes** | same file |
| Empty on either side, and both sides, never match | **Yes** | same file |
| The eight committed fixture cases replay to their goldens | **Yes** | `test/services/pass_fail_detector/golden_compare_fixtures_test.dart` |
| Missing / empty / unreadable file ⇒ `fail`, never `unknown` or `vacuous` | **Yes** | `test/services/pass_fail_detector/golden_compare_detector_test.dart` |
| Absolute vs relative path resolution | **Yes** | same file |
| `classifyAsync` threads the working directory; sync `classify` throws | **Yes** | `test/services/pass_fail_detector/pass_fail_detector_registry_test.dart` |
| A `golden_compare` leaf nested in a composite, both paths | **Yes** | same file |
| The scheduler's real call site reaches the run's own work dir | **Yes** | `test/services/job_scheduler/golden_compare_working_dir_test.dart` |
| An exit-0 run with no dump reports `fail` end to end | **Yes** | same file |
| YAML schema, profile parsing, and every validation error | **Yes** | `test/services/config/config_loader_golden_compare_test.dart` |
| No tier gate on the loader path | **Yes** | same file |
| Storage codec round-trip incl. nesting in a composite | **Yes** | `test/domain/models/pass_fail_config_codec_test.dart` |
| `golden.*` metrics survive encode → decode → hydrate | **Yes** | `test/services/result_store/golden_metrics_roundtrip_test.dart` |
| Settings → Detectors editor: chip, profile dropdown, both paths | **Yes** | `test/features/settings/widgets/detector_spec_editor_test.dart` |
| Locale sweep (en / zh_CN / zh / ja / ko) of the new editor fields | **Yes** | same file |
| A real `riscv-arch-test` suite against a real reference model | **No** | Manual, and `riscv_arch` driver territory — needs Sail/Spike + the RISC-V cross-compiler |
| Reading the offset in the Pro signature diff viewer | **No** | Pro overlay |

### 18.2 The `riscv_arch` driver, the `riscv:` block, toolchain guidance and demo mode

The driver that actually runs the
compatibility flow, plus the config block that describes it, the toolchain
probe that tells you what to install, and the demo mode that lets all of it
be exercised — and demoed — with no RISC-V toolchain on the machine at all.

#### Enumerate up front: one test per job

The job model has **no fan-out**: one `TestSpec` yields exactly one
`TestExecutionFinished` and exactly one `TestResult`. RISCOF naturally emits
*N* results per invocation, so the mismatch is resolved before the scheduler:

- `RiscvArchTestImporter` (`lib/services/import/riscv_arch_test_importer.dart`)
  reads a `riscv-arch-test` checkout and emits **one test per architectural
  test** as ordinary, inspectable `simcrux.yaml` — the `FuseSoCImporter`
  precedent. The file is yours: read it, diff it, edit it, commit it.
- `RiscvArchDriver` (`lib/services/simulator/riscv_arch_driver.dart`), id
  `riscv_arch`, runs exactly one of them per job, reusing
  `ProcessBackedSimulatorDriver`'s process-tree reaping, timeout escalation
  and cancellation. No new subprocess handling was written.

**Shelling RISCOF once for the whole suite is rejected as the primary path**
— it forfeits per-test scheduling, per-test timeouts, cancellation and
progress, and the dashboard would show one row that either passed or failed
for twenty minutes. It survives as `mode: riscof_passthrough`, whose
limitation is stated at the config key rather than discovered.

Two importer obligations worth checking by hand:

1. **`top:` is synthesized.** It is a required `TestSpec` field and an
   architectural test has no HDL top level, so the importer writes the
   test's base name. An importer that omitted it produces a config the
   loader refuses.
2. **`riscv.test` is relative to `arch_test.suite_path`,** which the
   importer pins to the scanned root, so the spawned compile does not depend
   on the process working directory.

#### The three modes share one code path

| Stage | `normal` | `demo` | `riscof_passthrough` |
|---|---|---|---|
| compile | cross-compile the test, then run the reference model | stage the committed reference signature | nothing |
| execute | run the DUT | stage the committed DUT signature | run your RISCOF command |
| **tail** | **read both signatures, compare, emit metrics, build the event** | **identical** | **identical** |

The reference-model run lives in the **compile** stage on purpose: it
produces a prerequisite artifact, and `runProcessStreaming` owns the whole
execute stream (it drains and closes the controller), so it can be called
exactly once per execute. Compile-stage processes are reaped on cancel
because the scheduler registers the live test before `driver.compile`.

#### The `riscv:` block

```yaml
riscv:
  isa: rv32imc_zicsr_zifencei     # descriptive; never used to infer a verdict
  reference:
    model: spike                  # sail | spike
    path: /opt/riscv/bin/spike
    args: []                      # spliced in before the ELF path
  arch_test:
    suite_path: third_party/riscv-arch-test
    revision: <sha or tag>        # rides into the Pro report's provenance
  toolchain:
    prefix: riscv32-unknown-elf-
    path: /opt/riscv/bin
  target:
    command: [./mycore, --elf, '{elf}', --signature, '{signature}']
    plugin_path: riscof/spike     # riscof_passthrough only
  compile:
    link_script: env/link.ld
    include_dirs: [env]
    extra_args: []
    command: []                   # full override; skips the derived gcc line
  riscof:
    command: [riscof, run, '--testfile={test}']
  extensions: [I, M, C, Zicsr, Zifencei]
  signature:
    dut: signature.dut.sig        # relative to the test working directory
    reference: signature.ref.sig
    word_size: 4                  # bytes per signature word
  mode: normal                    # normal | demo | riscof_passthrough
  demo_signatures: verification/fixtures/golden_compare
  # per test, written by the importer:
  test: rv32i_m/I/src/add-01.S
  extension: I
  demo_case: clean_pass
```

Placeholders accepted in `target.command`, `riscof.command` and the compile
overrides: `{elf}`, `{signature}`, `{ref_signature}`, `{test}`, `{isa}`,
`{name}`, `{work_dir}`. **An unknown placeholder is left verbatim**, so a
typo shows up in the spawned command line and the log instead of silently
becoming an empty argument.

`target.command` is a deliberate addition to RISCOF's shape, which
configures only `target.plugin_path` — a RISCOF *Python plugin* directory,
which a Dart driver cannot execute without reimplementing RISCOF's plugin
protocol. `plugin_path` is retained for the passthrough mode.

#### Four inheritance levels, not three

`riscv:` is read at **four** sites, each merging field-by-field over the one
above: **include file → project `defaults:` → suite → test.** Check all four
by hand at least once; missing one makes a per-test `riscv:` silently ignore
that level, which is invisible until someone wonders why their suite-level
`word_size` did not apply. Nested blocks merge rather than replace, so a
suite that switches only `reference.model` keeps the project's
`reference.path`.

**Completeness is validated on the flattened config**, not per level: a
project that declares `target.command` once in `defaults:` and only
`test:`/`extension:` per test is valid and must load.

#### Toolchain guidance — graded, not polish

**We detect and guide. We never bundle and never auto-install.** Bundling
a GPL engine alongside SimCrux is mere aggregation and does not change
SimCrux's licence, but it does create obligations when we ship the binary —
pinned provenance with SHA-256, patches preserved, Corresponding Source
published beside the binary for the binary's whole lifetime, and a
per-licence delivery mechanism. The RISC-V dependency set is the heaviest in
the suite and we build none of it. **SimCrux conveys none of it, so none of
those obligations arise.**

`SimulatorDriver.detectVersion` returns one `String?`, which is adequate for
Icarus and inadequate for four independent dependencies where "not found"
has a different remedy for each. So `RiscvToolchainProbe`
(`lib/services/simulator/riscv_toolchain_probe.dart`) reports **per
component** — cross-compiler, reference model, Python/RISCOF, and
Yosys/SymbiYosys for the formal driver (§18.3) — and `detectVersion` returns its summary line.

| Component | Linux | macOS | Windows |
|---|---|---|---|
| RISC-V GNU cross-compiler | distro package or an xPack / SiFive prebuilt | Homebrew tap or xPack prebuilt | **Worst case.** xPack prebuilts work but arch-test assumes a POSIX layout; WSL2 is better supported |
| Reference model | build Sail, or install Spike (easier) | Spike via Homebrew; Sail builds with effort | **Worst case.** Sail realistically means **WSL2**; Spike ships in the OSS CAD Suite |
| Python + RISCOF | `pip install riscof` in a venv | same | Works natively — the one component that gives no trouble here |
| Yosys / SymbiYosys | OSS CAD Suite | OSS CAD Suite / Homebrew | OSS CAD Suite, or WSL2 |

**Where the honest answer is WSL2, the guidance says WSL2.** Emitting a
Windows invocation we know is broken, and letting the user find out through a
subprocess failure at depth, is a worse product than a clear sentence. Check
this deliberately: the reference-model copy on Windows must say Sail is not
practically available natively and offer Spike.

The guidance exists twice, on purpose, and the two say the same thing:

- `RiscvComponentReport.remediation` — **unlocalized English**, the same
  channel as `SimulatorNotAvailableException.remediation`. This is what
  reaches logs, `failureMessage` and the plain-text diagnostics body, none
  of which has a localization path.
- `RiscvToolchainReportView`
  (`lib/features/diagnostics/widgets/riscv_toolchain_report_view.dart`) —
  the **localized** copy, authored as widget strings from the start rather
  than plumbed out of a value object. Localization covers widget-rendered
  strings only; config-loader diagnostics stay English.

The panel is rendered inside **App Diagnostics**. Its probe is lazy —
resolving it spawns four short-lived version probes — so an app launch pays
nothing until that dialog is opened.

#### Never surface a raw Python traceback

RISCOF failures arrive as ten to forty lines of interpreter frames.
`PythonTracebackReducer` keeps the final `SomeError: message` line as
`TestExecutionFinished.failureMessage` — documented as a *short
human-readable failure summary* — and **the full trace is not discarded**:
every line still reaches the stream as a `TestLogLine` and lands in the
retained stderr log, one click away in the inspector. A chained traceback
reports the exception that actually escaped.

#### Demo mode — the offline demo path AND the CI test path

```yaml
riscv:
  mode: demo
  demo_signatures: verification/fixtures/golden_compare
  demo_case: clean_pass
```

**Config-declared, never environment-gated.** Explicitly *not* the
`SIMCRUX_DEMO_RUNNER` / `DemoSimulatorDriver` pattern: an env-gated separate
driver would make CI exercise a different code path than production, which
is the single thing demo mode must not do. There is one driver id and one
code path; demo mode skips only the *spawn* steps and proceeds through
identical signature reading, comparison, metric emission and event
construction.

**No toolchain probe fires in demo mode at all** — skipped, not
probed-and-tolerated. A probe that fires and is then ignored costs four
process spawns and invites a future reader to "fix" the ignored result into
a failure.

**The corpus is the `golden_compare` detector's, unchanged** (`verification/fixtures/golden_compare/`,
eight cases, regenerated by
`dart run tool/generate_golden_compare_fixtures.dart`). Authoring a second
fixture set would give the two halves somewhere to drift apart. Each case's
`case.json` names its two dump files; the driver stages them into the test's
working directory under the `riscv_signature` profile's conventional names.

Step-by-step, with **no RISC-V toolchain installed and no network**:

1. Import the corpus (`RiscvArchTestImporter.importDemo`) or hand-write the
   block above. The emitted YAML must load with no `target.command`, no
   cross-compiler and no reference model.
2. Run it. Every case reports the same verdict the corpus's `expected.json` records,
   with one deliberate exception: `format_variance_generic` reports **pass**
   here, because this driver is RISC-V by definition and always compares
   under `profile: riscv_signature`. The corpus's `fail` for that case is the
   generic-profile counter-verdict.
3. `clean_pass` passes; `first_word_mismatch` fails at offset 0;
   `missing_dut` and `empty_dut` fail — never `unknown`, never `vacuous`.

#### Status classification — the same two traps, on the driver side

Every demo case exits 0, and so does a real core that wrote no signature.

- **Missing or empty signature on either side ⇒ `fail`.** Never `unknown`
  (which hands the verdict back to the driver's own exit code — a clean exit
  would report **pass**) and never `vacuous` (which the scheduler treats as
  success-equivalent: no retry, and the work directory holding the evidence
  is deleted).
- **A non-zero exit fails even when the signatures agree.** A core that
  crashed after writing a correct prefix is not compatible.
- A programmatically-built spec with no usable `riscv:` block fails loudly
  with the loader's own message rather than reporting green.

#### Metrics

The driver calls the same pure `GoldenComparator` the detector calls and
emits `GoldenComparison.toMetrics()`, so the two agree by construction. On
top of the five reserved `golden.*` keys:

| Key | Meaning |
|---|---|
| `riscv.extension` | the extension this test exercises — what the Pro rollup groups on |
| `riscv.isa` | the ISA string the config claimed (descriptive only) |
| `riscv.mode` | `normal` / `demo` / `riscof_passthrough` |
| `riscv.test` | the architectural test source |
| `riscv.arch_test_revision` | suite revision, for report provenance |
| `riscv.reference_model` | which model produced the golden — **absent in demo mode**, because none ran |
| `riscv.signature.word_size` | bytes per signature word |
| `riscv.signature.byte_offset` | the word offset × word size — the byte the Pro diff viewer decodes at |

`signature.word_size` is why that key lives in the `riscv:` block and not on
the comparison profile: the comparator counts *words* and never needs a
width, but locating the divergent instruction does.

#### Tier-gate scenarios

**None, deliberately and permanently** — the same decision as §18.1, now
extended across the whole `riscv:` path: the config reader, the driver, the
toolchain probe and the diagnostics panel. Verify at
`LicenseTier.openCore` with `kBetaPeriod = false` that a compatibility run
still produces per-test verdicts with no badge, cap or nag. The loader's
`_parameterizationUnlocked` sweep gate still applies to `seeds:` /
`parameters:` and that asymmetry is intentional: sweeps are productivity and
are Pro; a correctness verdict is free.

#### Automation Assessment

| Check | Automatable? | How |
|---|---|---|
| Four-level `riscv:` inheritance, each level independently | **Yes** | `test/services/config/config_loader_riscv_test.dart` |
| Nested blocks merge rather than replace | **Yes** | same file, and `test/domain/models/riscv_config_test.dart` |
| `TestSpecExpander` keeps `riscv:` on a swept child | **Yes** | `test/services/config/config_loader_riscv_test.dart` |
| Every validation error, accumulating, with source spans | **Yes** | same file |
| No tier gate at any tier × `kBetaPeriod` combination | **Yes** | same file (post-flip build MANUAL) |
| `riscv_arch` absent from the language catalog; tests not flagged | **Yes** | same file |
| Enumeration: one `TestSpec` per architectural test | **Yes** | `test/services/import/riscv_arch_test_importer_test.dart` |
| The emitted YAML loads through the real `ConfigLoader` | **Yes** | same file |
| `top:` synthesized for every emitted test | **Yes** | same file |
| Demo import loads with no toolchain plumbing at all | **Yes** | same file |
| The whole flow in demo mode, through the real scheduler | **Yes** | `test/services/simulator/riscv_arch_driver_demo_test.dart` |
| Every committed corpus case replays to its `golden_compare` verdict | **Yes** | same file |
| Missing / empty signature ⇒ `fail`, never `unknown` or `vacuous` | **Yes** | same file, and `test/services/simulator/riscv_arch_driver_normal_test.dart` |
| `golden.*` + `riscv.*` metrics reach `TestResult` | **Yes** | `test/services/simulator/riscv_arch_driver_demo_test.dart` |
| `riscv.signature.byte_offset` scales with `word_size` | **Yes** | same file |
| No subprocess is spawned in demo mode | **Yes** | same file (launcher throws if called) |
| gcc + reference-model argv construction, both models | **Yes** | `test/services/simulator/riscv_arch_driver_normal_test.dart` |
| Placeholder expansion, including an unknown placeholder | **Yes** | same file |
| A missing binary raises `SimulatorNotAvailableException` | **Yes** | same file |
| RISCOF passthrough spawns the configured command | **Yes** | same file |
| Python traceback reduced to one line, full trace retained | **Yes** | same file, and `test/services/simulator/python_traceback_reducer_test.dart` |
| Per-component probe; demo mode probes nothing | **Yes** | `test/services/simulator/riscv_toolchain_probe_test.dart` |
| Actionable guidance for every component × platform | **Yes** | same file |
| Windows says WSL2 where that is the honest answer | **Yes** | same file |
| Locale sweep (en / zh_CN / zh / ja / ko) × three platforms | **Yes** | `test/features/diagnostics/riscv_toolchain_report_view_test.dart` |
| A real `riscv-arch-test` run against a real reference model | **No** | Manual — needs Sail/Spike + the RISC-V cross-compiler |
| A real RISCOF passthrough against an existing user flow | **No** | Manual — needs a working RISCOF install |
| Windows / WSL2 guidance read on an actual Windows host | **No** | Manual |
| Reading the offset in the Pro signature diff viewer | **No** | Pro overlay |

### 18.3 The `riscv_formal` driver — bounded proofs on the job model

riscv-formal is SymbiYosys running
the RVFI check set against an instrumented core: *N* independent bounded
proofs, each pass/fail, each with a counterexample VCD on failure. That is
structurally a regression run, so it maps onto the existing job model
rather than getting a parallel one.

#### What it does

```yaml
defaults:
  simulator: riscv_formal
  pass_fail:
    type: string_match
    pass_string: 'DONE (PASS'
  riscv:
    isa: rv32imc_zicsr
    formal:
      checks_dir: cores/democore/checks   # where genchecks.py wrote the jobs
      sby_binary: sby                     # optional; PATH by default
suites:
  insn:
    tests:
      - name: insn_add_ch0
        top: insn_add_ch0
        riscv:
          formal:
            check: insn_add_ch0
            sby_file: insn_add_ch0.sby
            group: insn
```

Normally written by the importer, not by hand:

```
RiscvFormalCheckImporter.importChecks(checksPath: 'cores/democore/checks')
```

- **One test per bounded proof.** Every generated `.sby` becomes one
  `TestSpec`. A `.sby` that declares `[tasks]` becomes one test *per task*,
  with an import warning saying so — one `sby` invocation over several
  tasks prints several `DONE (…)` lines into a single result row, which is
  exactly the fan-out the job model cannot represent.
- **`sby` runs in the checks directory**, because `genchecks.py` writes
  `[files]` entries relative to it and the upstream Makefile runs `sby`
  from there. Artifacts still land in the test's working directory,
  because the driver passes `-d <work_dir>/<check>`.
- **The derived command line is** `sby -f -d <task_dir> <sby_file> [task]`.
  `riscv.formal.command` replaces it wholesale for a wrapper flow, with the
  `{sby_file}` / `{task_dir}` / `{task}` / `{check}` / `{checks_dir}`
  placeholders — and an **unknown** placeholder is left verbatim so a typo
  shows up in the command line rather than becoming an empty argument.

#### Setup

The committed corpus is `verification/fixtures/riscv_formal/`, seven case
directories each holding `case.json` (the inputs), `sby.log` (the captured
SymbiYosys output), any trace VCDs, and `expected.json` (the golden the
production parser produces). Regenerate with:

```bash
dart run tool/generate_riscv_formal_fixtures.dart
```

**Everything in the corpus is hand-authored.** Nothing is derived from
riscv-formal or SymbiYosys, so no third-party attribution obligation is
created — the same call the signature corpus makes (§18.1). No Yosys, no SymbiYosys, no SMT
solver and no network are required for any of it.

#### Step-by-step expected behavior

Each numbered item is a case directory replayed in `mode: demo`.

1. **A clean bounded proof.** `DONE (PASS, rc=0)` ⇒ **pass**, no failure
   message, no counterexample. (`insn_add_pass`)
2. **A counterexample.** `DONE (FAIL, rc=2)` ⇒ **fail**, with the trace VCD
   recorded and the failure line naming the step and the check.
   (`insn_sub_counterexample`)
3. **A cover run with several traces.** ⇒ **pass**, `trace_count` 2.
   (`cover_multi_trace`)

#### The verdict mapping — the correctness question of this driver

**A proof that did not prove anything must not read as a pass.** Every
non-`PASS` SymbiYosys outcome is `TestStatus.fail`; the *shape* of the
failure survives in `riscv.formal.verdict`, which is what the Pro formal
dashboard renders as "inconclusive" versus "counterexample found".

| `sby` outcome | SimCrux status | Why |
|---|---|---|
| `PASS` | `pass` | the property held over the whole bound |
| `FAIL` | `fail` | a counterexample exists |
| `UNKNOWN` | **`fail`** | the engine did not decide. Nothing was proved and nothing was refuted — an unproven property is not a passing property |
| `TIMEOUT` | **`fail`** | the engine's own solver budget expired. **Deliberately not `TestStatus.timeout`**, which means *SimCrux killed the job*; conflating them makes one dashboard filter mean two things, and would also put the driver at odds with the `string_match` detector |
| `ERROR` | `fail` | the proof never ran |
| *no `DONE (…)` line at all* | **`fail`** | see below |

4. **`UNKNOWN` reports fail** and says "inconclusive", never anything
   resembling a pass. (`pc_fwd_unknown`)
5. **`TIMEOUT` reports fail**, and the status is **not** `timeout`.
   (`reg_timeout`)
6. **`ERROR` reports fail**, with SymbiYosys's own `ERROR:` line as the
   failure message rather than a generic exit-code sentence.
   (`causal_error`)

#### The status traps — check these deliberately

7. **No verdict at all, on an exit-0 run, reports fail.**
   (`liveness_no_outcome`) This is the sharpest case in the corpus: the log
   ends before any `DONE (…)` line and the process **exits 0**. Classifying
   from the exit code would report a proof that never happened as green.
   The driver classifies from the log, never from the exit code.
8. **Nothing here is ever `unknown`.** `unknown` hands classification back
   to the driver's own exit code, which is the same trap by another route.
9. **Nothing here is ever `vacuous`.** `vacuous` is success-equivalent to
   the scheduler: no retry, and the work directory holding the
   counterexample VCD is **deleted**. "The solver gave up" is not a vacuous
   pass.
10. **A non-`PASS` verdict never reports exit code 0.** A decisive detector
    overrides the driver, and `0` is the one value every exit-code-shaped
    classifier reads as a pass — including `ExitCodePassFailConfig`, which
    is what a `TestSpec` with no `pass_fail:` block gets. The driver
    withholds a contradicting `0` and preserves it in
    `riscv.formal.process_exit_code`. **Verify this by running a formal
    test with no `pass_fail:` block at all: it must still fail.**
11. **`PASS` with a non-zero process exit is a fail** — a contradicted pass
    is not a pass.

#### The counterexample VCD — the hand-off to WaveCrux

The trace path lands on **`TestResult.waveformPath`**, the existing field
that already round-trips NDJSON as `waveform_path` and that the "Debug in
WaveCrux" dispatcher and the CXP producer already consume. **No new result
field exists or is needed.**

12. **The recorded path is absolute and the file exists.** A path that does
    not resolve is worse than an honest absence, so an announced-but-missing
    trace is reported in `riscv.formal.trace_unresolved` and
    `waveformPath` stays null.
13. **A failing proof's VCD survives on disk.** The scheduler sweeps only
    **successful** work directories, so the evidence is still there when
    the Pro dashboard or the CXP producer asks for it. This is why `UNKNOWN`
    and `TIMEOUT` being `fail` rather than `vacuous` is load-bearing and not
    a nicety.
14. **A passing run's path is archived or dropped, never left dangling.**
    That is the scheduler's existing rule and the driver does not
    special-case it.

#### Metrics

Namespaced `riscv.formal.*`, alongside the `riscv.mode` and `riscv.isa`
keys shared with §18.2 **by reference to the same constants**, so a report
mixing both flows cannot end up with two spellings of one fact.

| Key | Meaning |
|---|---|
| `riscv.formal.check` | the check this row proved (`insn_add_ch0`) |
| `riscv.formal.group` | the property group — what the Pro check-set coverage rollup groups on. Derived from the check name; an explicit `group:` wins |
| `riscv.formal.channel` | the RVFI channel index from a `…_chN` name |
| `riscv.formal.verdict` | `sby`'s own token, verbatim — **where the honest distinction lives** |
| `riscv.formal.rc` | the `rc=` value from the `DONE` line |
| `riscv.formal.proof_mode` | `bmc` / `prove` / `cover` / `live`, read from the `.sby` at run time |
| `riscv.formal.depth_configured` | the bound the `.sby` set |
| `riscv.formal.depth_reached` | the deepest step the engine reported |
| `riscv.formal.wall_time_ms` | the proof's wall time |
| `riscv.formal.wall_time_source` | `engine` (`sby`'s own elapsed clock time) or `measured` (this driver's stopwatch) — never conflated |
| `riscv.formal.engine` | e.g. `smtbmc boolector` |
| `riscv.formal.trace_count` | how many traces were announced |
| `riscv.formal.trace_unresolved` | an announced trace that is not on disk |
| `riscv.formal.process_exit_code` | a `0` withheld because it contradicted the verdict |

`depth_reached` is reported **beside** `depth_configured` on purpose:
"reached 12 of a configured 20" and "reached 12 of a configured 12" are
different facts about a proof.

#### Toolchain

Same posture as §18.2 — **detect and guide, never bundle**. SymbiYosys is
already the fourth component of `RiscvToolchainProbe`, so the formal
driver **consumes** that probe and does not extend it. Verify:

15. With `sby` absent, the failure message is the component's actionable
    per-platform remediation — "install the OSS CAD Suite", not an errno.
16. No guidance anywhere offers to install or bundle a toolchain.
17. A SymbiYosys Python traceback is reduced to its final
    `SomeError: message` line for the dashboard row, with the full trace
    still in the retained stderr log. The `PythonTracebackReducer` from §18.2 is
    reused unchanged — there is one reducer in the codebase.

#### Localization

**No new ARB strings.** The formal driver renders no widget of its own: the
App Diagnostics toolchain panel already covers SymbiYosys, and everything
the driver emits (loader diagnostics, remediation text, failure messages)
is on the unlocalized-English channel that has no localization path
(§18.2).

#### Tier-gate scenarios

**None, deliberately and permanently.** Same decision as §18.1 and §18.2,
now covering the `riscv.formal:` reader, the driver and the importer.
Verify at `LicenseTier.openCore` with `kBetaPeriod = false` that a formal
run still produces per-property verdicts with no badge, cap or nag. The
Pro formal dashboard is the analysis layer over these rows, not a gate
on them.

#### Automation Assessment

| Check | Automatable? | How |
|---|---|---|
| The verdict comes from the log, never from the exit code | **Yes** | `test/domain/models/sby_outcome_test.dart` |
| No `DONE (…)` line ⇒ `NO_OUTCOME` ⇒ `fail` | **Yes** | same file, and `test/services/simulator/riscv_formal_driver_demo_test.dart` |
| `UNKNOWN` / `TIMEOUT` / `ERROR` ⇒ `fail`, never `unknown` or `vacuous` | **Yes** | same files |
| `sby` TIMEOUT is not `TestStatus.timeout` | **Yes** | same files |
| Worst outcome wins across a multi-task log | **Yes** | `test/domain/models/sby_outcome_test.dart` |
| Depth, wall time, engine and traces parsed out of the log | **Yes** | same file |
| Wall time attributed to `engine` vs `measured` | **Yes** | `test/services/simulator/riscv_formal_driver_demo_test.dart` |
| `.sby` proof mode / depth / `[tasks]` parsing | **Yes** | `test/domain/models/sby_script_test.dart` |
| One `TestSpec` per bounded proof; one per task for a multi-task job | **Yes** | `test/services/import/riscv_formal_check_importer_test.dart` |
| `top:` synthesized for every emitted test | **Yes** | same file |
| The emitted YAML loads through the real `ConfigLoader` | **Yes** | same file |
| The emitted `pass_string` is the parser's own constant | **Yes** | same file |
| The detector and the driver agree on every corpus case | **Yes** | `test/services/simulator/riscv_formal_driver_demo_test.dart` |
| `riscv.formal:` reads and merges at every inheritance level | **Yes** | `test/services/config/config_loader_riscv_formal_test.dart` |
| Completeness scoped by simulator id; a foreign sub-block is inert | **Yes** | same file |
| `riscof_passthrough` refused for a bounded proof | **Yes** | same file, and `test/domain/models/riscv_formal_config_test.dart` |
| No tier gate at any tier × `kBetaPeriod` combination | **Yes** | `test/services/config/config_loader_riscv_formal_test.dart` (post-flip build MANUAL) |
| `riscv_formal` absent from the language catalog; tests not flagged | **Yes** | same file |
| The whole flow in demo mode, through the real scheduler | **Yes** | `test/services/simulator/riscv_formal_driver_demo_test.dart` |
| No subprocess is spawned in demo mode | **Yes** | same file (launcher throws if called) |
| The counterexample VCD reaches `TestResult.waveformPath`, absolute and existing | **Yes** | same file |
| The VCD survives the scheduler's cleanup on a failing proof | **Yes** | same file |
| A non-`PASS` verdict never reports exit code 0 (default-detector trap) | **Yes** | same file, and `test/services/simulator/riscv_formal_driver_normal_test.dart` |
| `sby -f -d <task_dir> <sby_file>` argv, including a `task` | **Yes** | `test/services/simulator/riscv_formal_driver_normal_test.dart` |
| `sby` is spawned in the **checks** directory, not the work directory | **Yes** | same file |
| Placeholder expansion, including an unknown placeholder | **Yes** | same file |
| Trace resolution from both `sby` spellings; unresolved reported | **Yes** | same file |
| A missing `sby` yields the actionable remediation, not an errno | **Yes** | same file |
| A Python traceback reduced to one line, full trace retained | **Yes** | same file |
| The corpus covers every verdict and cannot silently lose a case | **Yes** | `test/services/simulator/riscv_formal_fixtures_test.dart` |
| Fixtures are hand-authored, not derived from upstream | **Yes** | same file |
| A real riscv-formal check set against a real core | **No** | Manual — needs Yosys + SymbiYosys + an SMT solver + an RVFI-instrumented core |
| A real counterexample VCD opened in WaveCrux | **No** | Manual; the CXP coordinate is §18.7 |
| Property-level rollup and proof-depth display | **No** | Pro overlay |


### 18.4 The Pro opener seam — and what it must never gate

The Pro Compatibility Dashboard mounts through
`riscvCompatibilityOpenerProvider`
(`lib/features/dashboard/providers/riscv_compatibility_opener.dart`), the
same `Provider<XOpener?>` shape as `seedFailureHeatmapOpenerProvider` and
`regressionComparisonOpenerProvider`: open core declares it `null`, the Pro
overlay overrides it in `proOverrides` and **the override owns the tier
gate**, so every caller is gated in one place.

**The load-bearing property is what the seam does *not* touch.** The
compatibility **verdict** is open core (§18.1). A build with no license, post-`kBetaPeriod`,
still runs `riscv_arch`, still classifies every architectural test, still
records `golden.*` / `riscv.*` metrics, and still renders per-test pass/fail
in the ordinary dashboard. Only the *analysis* screen — the per-extension
rollup, the ISA-string attestation and the signature diff viewer — is Pro.

**Steps.**

1. Build a fresh `ProviderContainer`; read `riscvCompatibilityOpenerProvider`;
   confirm the value is `null`.
2. Repeat for every `LicenseTier` × `betaPeriodProvider` combination; confirm
   the default is `null` in all of them **and** that nothing on the open-core
   side reads a tier to decide it.
3. In an unlicensed build, run a `mode: demo` compatibility project end to
   end and confirm every row's pass/fail verdict renders in the ordinary
   dashboard, unchanged and uncapped.

| Check | Automatable? | How |
|---|---|---|
| Open-core default is `null` | **Yes** | `test/features/dashboard/providers/riscv_compatibility_opener_test.dart` |
| Default is tier-independent at every tier × `kBetaPeriod` | **Yes** | same file |
| An override surfaces a callable opener | **Yes** | same file |
| Per-test pass/fail is produced and rendered ungated at `LicenseTier.openCore` post-beta | **Yes** | Pro overlay — its ungated-verdict test |
| The Pro screen itself, gated both ways | **Yes** | Pro overlay verification guide |

### 18.5 The shared HTML export shell — the open-core half of the Pro report

The Pro compatibility **report** is a second self-contained HTML artifact,
and it is built on the existing static-dashboard export machinery rather
than on a parallel renderer. So the document
skeleton, the HTML escaping and the per-status color palette moved out of
`HtmlExporter` into `HtmlReportShell`
(`lib/services/export/html_report_shell.dart`), which `HtmlExporter` now
consumes unchanged.

**Why this is a correctness surface and not a tidiness one.** Two HTML
exports that disagree about what `fail` looks like — or that escape
attribute values differently — is a defect the user discovers *after*
handing the file to someone else. One palette, one escape function.

`HtmlReportShell` contains **no** RISC-V vocabulary and **no** tier check.
It is a renderer. The report's wording, which is a reviewed surface, lives
entirely in the Pro overlay.

**Steps.**

1. Export a regression to HTML (`simcrux --ci --export html=<path>`) and
   open it from `file://` with networking disabled; confirm it renders
   fully — no CDN, no font fetch, no stylesheet link.
2. Confirm every `TestStatus` value has a chip color; a status with no rule
   must render plain, never in another status's color.

| Check | Automatable? | How |
|---|---|---|
| Skeleton, escaping, `extraCss` ordering | **Yes** | `test/services/export/html_report_shell_test.dart` |
| The title is escaped by the shell, not by trusting callers | **Yes** | same file |
| Every `TestStatus` has a palette rule | **Yes** | same file |
| No external reference of any kind in the document | **Yes** | same file, and `html_exporter_test.dart` |
| `HtmlExporter` output unchanged by the extraction | **Yes** | `test/services/export/html_exporter_test.dart` |
| The Pro report built on the shell | **Yes** | Pro overlay verification guide |

### 18.6 The formal-dashboard opener seam

The Pro formal
property dashboard mounts through `riscvFormalOpenerProvider`
(`lib/features/dashboard/providers/riscv_formal_opener.dart`), the same
`Provider<XOpener?>` shape §18.4 established for the compatibility
dashboard: open core declares it `null`, the Pro overlay overrides it in
`proOverrides` and **the override owns the tier gate**.

**The load-bearing property is, again, what the seam does *not* touch.** The
formal **verdict** is open core. A build with no license, post-`kBetaPeriod`,
still runs `riscv_formal`, still reads `sby`'s `DONE (…)` line rather than its
exit code, still classifies every bounded proof, still records the whole
`riscv.formal.*` metric set, and still hands the counterexample VCD to
`TestResult.waveformPath` — which is what "Debug in WaveCrux" and the CXP
producer consume, both of them open core. A proof that says a property does
**not** hold is a correctness result, and correctness is free. Only the
*analysis* screen — check-set
coverage, the proof-depth pair, the per-property table — is Pro.

**Steps.**

1. Build a fresh `ProviderContainer`; read `riscvFormalOpenerProvider`;
   confirm the value is `null`.
2. Repeat for every `LicenseTier` × `betaPeriodProvider` combination; confirm
   the default is `null` in all of them.
3. In an unlicensed build, run a `mode: demo` formal project (§18.3's
   committed corpus) end to end and confirm every proof's verdict renders in
   the ordinary dashboard, and that the counterexample row still carries its
   waveform.

| Check | Automatable? | How |
|---|---|---|
| Open-core default is `null` | **Yes** | `test/features/dashboard/providers/riscv_formal_opener_test.dart` |
| Default is tier-independent at every tier × `kBetaPeriod` | **Yes** | same file |
| An override surfaces a callable opener | **Yes** | same file |
| Per-property pass/fail **and the counterexample VCD** produced and rendered ungated at `LicenseTier.openCore` post-beta | **Yes** | Pro overlay — its ungated formal-verdict test |
| The Pro screen itself, gated both ways | **Yes** | Pro overlay verification guide |

### 18.7 The CXP semantic stream coordinate — the producer

**Open core and ungated.** `riscvStreamCoordinateFor`
(`lib/services/remote/cxp/riscv_stream_coordinate.dart`) turns a `TestResult`
into the optional `coordinate` payload field CXP §9.9
(`https://edacrux.app/cxp#sec-9-9`) defines, so the
"Debug in WaveCrux" hand-off can say *open this trace **at step 7*** rather
than only *open this trace*. It is pure and has no tier gate anywhere on the
path.

**What you are verifying is mostly silence.** CXP §9.9 rule 3 forbids emitting
a `sequence_index` the producer cannot state in the named stream's own index
space, so the correct behaviour for nearly every row is to send **no**
coordinate, and a reviewer's instinct that this is unfinished is the thing to
head off. Two cases in particular are decisions rather than gaps:

- **An architectural-compatibility row carries no coordinate, ever** — not
  even a failing one whose `riscv.signature.byte_offset` looks like an
  address. A signature is machine state dumped at the *end* of a test, not a
  retire log: word *N* is the *N*th value stored into the signature region,
  and recovering which retirement stored it needs the execution trace. Which
  `riscv_arch` does not produce — it declares `supportsVcd: false`, so there
  is no decoded stream to address and nothing for a receiver to open. If you
  ever see a compatibility row hand WaveCrux an instruction index, that is a
  fabricated number and a defect.
- **A failing bounded proof emits `riscv.formal.trace_step`, not
  `riscv.rvfi.retire`.** SimCrux knows the step `sby` printed; it does not
  know `rvfi_order`, and converting between them requires the trace, because
  how many instructions a core retires in seven cycles is a property of the
  core under proof. WaveCrux holds the decoded trace and does the conversion.

`RiscvResultKind` (`lib/services/simulator/riscv_result_kind.dart`) is where
the two row discriminators live — the compatibility and formal predicates,
kept in open core because each is a statement about the *driver's* metric
contract and both drivers are open core. The Pro rollups delegate to them, so
there is still exactly one definition of "is this a formal row".

**Steps.**

1. Run a `mode: demo` formal project (§18.3's corpus) in an **unlicensed**
   build, post-`kBetaPeriod`. Open the inspector on the
   `insn_sub_counterexample` row and press **Debug in WaveCrux** with a
   WaveCrux peer running.
2. In WaveCrux's cross-probe panel, confirm the received `request_highlight`
   carries a `coordinate` of `riscv.formal.trace_step`, `sequence_index` 7,
   `sub_id` `ch0`.
3. Repeat on a **passing** proof and on an `UNKNOWN` one: both must dispatch
   the file with **no** coordinate. A coordinate on either would assert that
   a counterexample exists.
4. Repeat on an architectural-compatibility failure: file only, no
   coordinate.
5. Confirm the demo row's coordinate carries `riscv.mode = demo`, so a
   receiver can label replayed evidence rather than present it as measured.

| Check | Automatable? | How |
|---|---|---|
| A failing proof emits step + channel; every other verdict emits nothing | **Yes** | `test/services/remote/cxp/riscv_stream_coordinate_test.dart` |
| A compatibility row emits nothing even with a signature offset | **Yes** | same file |
| A missing / non-numeric `depth_reached` emits nothing rather than step 0 | **Yes** | same file |
| An announced-but-unresolved trace emits nothing | **Yes** | same file |
| A demo row emits, and labels itself `demo` | **Yes** | same file |
| The two discriminators partition a mixed run | **Yes** | same file |
| The coordinate reaches a peer on the `RequestHighlight`, not only the notify | **Yes** | `test/features/remote/services/debug_in_wavecrux_dispatcher_test.dart` |
| Callers passing no `result` still dispatch (the coordinate is additive) | **Yes** | same file |
| The whole path is ungated at every tier × `kBetaPeriod` | **Partly** | the producer takes no tier input at all — read the source; the surrounding dispatch is covered by §18.6's ungated test |


### 18.8 The two shipped demo projects — `examples/riscv-*-demo/`

**What it does, in plain language.** Demo mode was implemented, tested and
documented (§18.2, §18.3), and the corpora were committed — but there was no
`simcrux.yaml` anywhere in the repository that a *person* could open to run
it. Everything reached the corpora from test code. §18.8 closes that: two
committed, openable projects that run to completion **with no RISC-V
toolchain on the machine**.

| Project | Driver | Corpus | Spread |
|---|---|---|---|
| [`examples/riscv-compatibility-demo/simcrux.yaml`](../examples/riscv-compatibility-demo/simcrux.yaml) | `riscv_arch` + `golden_compare` / `riscv_signature` | `verification/fixtures/golden_compare/` | 8 tests, **3 pass / 5 fail**, over four extension suites (`I`, `M`, `C`, `Zicsr`) |
| [`examples/riscv-formal-demo/simcrux.yaml`](../examples/riscv-formal-demo/simcrux.yaml) | `riscv_formal` + `string_match` on `DONE (PASS` | `verification/fixtures/riscv_formal/` | 7 tests, **2 pass / 5 fail**, one per verdict, over six property groups |

**Neither is all-green, on purpose.** A report that shows only passes
demonstrates nothing about a comparison, and an evaluator is right to
discount it. Both spreads are asserted by name, in both directions.

**Setup.** None. Clone the repository and open the file. Every path inside
each config is relative to the config itself, so a checkout anywhere works.

**Step-by-step, on a machine with no RISC-V toolchain and no network.**

1. **File → Open Config…** and pick either
   `examples/riscv-*-demo/simcrux.yaml`. It must load with **no error dialog
   and no warning banner** — the whole file, not a partial parse.
2. **Tools → Run Regression** (`F5`). Nothing is spawned; the run finishes in well
   under a second.
3. Confirm the spread in the results dashboard. Compatibility: `clean_pass`,
   `format_variance_riscv` and `format_variance_generic` pass; the other five
   fail. (The last of those three is a decision, not a bug: the driver is
   ISA-coupled by construction and always compares on the
   `riscv_signature` profile, so the corpus's generic-profile `fail` for the same
   bytes does not apply here — §18.2.) Formal: `insn_add_pass` and
   `cover_multi_trace` pass; the other five fail, and `reg_timeout` reports
   **fail**, never `TestStatus.timeout`, which would mean SimCrux killed it.
4. No row anywhere may report `unknown`, `vacuous`, `skipped` or `cancelled`
   — every one of those reads as a broken demo.
5. On a Pro build, open the compatibility dashboard and the formal property
   dashboard against the two runs. Both must **populate**: four extension
   rows with `Zicsr` attested and `I`/`M`/`C` not; six property-group rows
   with no `(ungrouped)` bucket; provenance reading demo on every row and
   naming **no** reference model, because none ran.

**Edge cases and the reason each config is shaped the way it is.**

- **The paths are relative to the config, and the loader resolves them.**
  `riscv.demo_signatures` and `riscv.formal.demo_outputs` are rooted at the
  project file's directory, the same treatment `sources:` and
  `include_dirs:` already get. Without that they would resolve against the
  *process* working directory — the repo root under `flutter test`, and `/`
  for a Finder-launched desktop build, so a config that passed CI would fail
  for the person opening it from the app. Nothing else in the `riscv:` block
  is rewritten: install locations (`reference.path`, `toolchain.path`,
  `formal.sby_binary`) stay verbatim so engine detection is untouched, and
  the placeholder-bearing fields stay verbatim so `{elf}` is not corrupted
  into a path.
- **Two separate demo keys.** The compatibility flow reads
  `riscv.demo_signatures`; the formal flow reads
  `riscv.formal.demo_outputs`. The corpora are different shapes — signature
  pairs versus captured logs and traces — and a project may run both flows
  in demo mode at once.
- **`existsSync()` is not loadability.** Three `simcrux.yaml` fixtures in
  this repo were unopenable for months behind a guard that only checked the
  file was there. The guard for these two parses them with the real
  `ConfigLoader`, asserts zero errors **and** zero warnings, then executes
  them through the real `LocalJobScheduler` with a process launcher that
  **throws if anything is spawned** — which is a stronger statement of "no
  toolchain required" than any assertion about the environment, and is only
  meaningful because demo mode is the same driver as the real path.

| Check | Automatable? | How |
|---|---|---|
| Both configs load through the real `ConfigLoader` with zero errors | **Yes** | `test/examples/riscv_demo_examples_test.dart` |
| …and zero warnings | **Yes** | same file |
| Every corpus path resolves from the committed location | **Yes** | same file |
| Both run to completion with a launcher that throws on any spawn | **Yes** | same file |
| The exact pass/fail spread, by test name, in both directions | **Yes** | same file |
| The four-way formal verdict distinction survives the demo path | **Yes** | same file |
| Demo-corpus paths are rooted at the project file; nothing else is rewritten | **Yes** | `test/services/config/config_loader_riscv_test.dart` |
| Both Pro dashboards populate from these exact runs | **Yes** | Pro overlay `riscv_demo_examples_pro_test.dart` |
| The dialog really opens the file on a clean machine | **No** | Manual, and the point of the exercise — do it on a machine with no RISC-V toolchain installed |

### 18.9 The two RISC-V importers' entry points — menu items and CLI sub-commands

**What it does, in plain language.** §18.2 and §18.3 built
`RiscvArchTestImporter` and `RiscvFormalCheckImporter`, and §18.8 shipped two
demo projects whose per-test YAML is **pre-written**. Between those, a user
pointing SimCrux at their own `riscv-arch-test` checkout or their own
riscv-formal `checks/` directory had nothing to press: neither importer had a
menu item, a sub-command, or any caller at all. §18.9 closes that. It adds no
importer behaviour — the enumeration, the emission, the warnings and the
`top:` synthesis are all §18.2/§18.3 code, unchanged — only the two doors.

| Surface | Arch-test | riscv-formal |
|---|---|---|
| Menu | **File → Import RISC-V Architectural Tests…** | **File → Import riscv-formal Checks…** |
| Command palette | same label | same label |
| CLI | `simcrux import-riscv-arch-test <suite-path> [options]` | `simcrux import-riscv-formal <checks-path> [options]` |
| Keyboard | none by design — `Cmd/Ctrl+I` is `Import FuseSoC .core File…` | none by design |
| Toolbar | no — the canonical common block is shared across the suite | no |

Both menu items sit in the File menu's **first group**, directly under
Open Config… and Import FuseSoC .core File…, because they are one job:
turn something that is not a `simcrux.yaml` into one.

**Setup.** A `riscv-arch-test` checkout and/or a riscv-formal `checks/`
directory that `genchecks.py` has already been run against. Neither needs a
toolchain — nothing is compiled, elaborated or spawned by an import. If you
have neither, the committed miniatures at
[`test/fixtures/riscv_arch_test/`](../test/fixtures/riscv_arch_test/) and
[`test/fixtures/riscv_formal_checks/`](../test/fixtures/riscv_formal_checks/)
have the same layout and work for every step below.

**Step-by-step — the GUI.**

1. **File → Import RISC-V Architectural Tests…** A **directory** picker
   opens (not a file picker: an arch-test checkout is a tree).
2. Pick the checkout root — the directory *containing* `riscv-test-suite/`.
   Pointing one level in also works and raises the `no_suite_subdir` warning.
3. A **save** dialog opens next, pre-filled with `simcrux.yaml`. Choose
   anywhere; the emitted file is location-independent (see edge cases).
   Cancelling either picker aborts with no file written and no snackbar.
4. A snackbar reports **`Imported N test(s) into <path>`**, the file opens as
   a new workspace tab, and it is added to the recents list.
5. Read the file. It opens with a header comment naming the source directory
   and, if anything did not translate cleanly, an `# Import warnings (n):`
   block listing each code and message. Every emitted test carries `name:`,
   the synthesized `top:`, `riscv.test` and `riscv.extension`.
6. Repeat with **File → Import riscv-formal Checks…** against a `checks/`
   directory. Same two-picker flow; the emitted file carries one test per
   `.sby`, `riscv.formal.sby_file`, and `riscv.formal.group`.

**Step-by-step — the CLI.** Neither sub-command launches a window; both
print what they wrote and exit (0 on success, 2 on any failure).

```bash
# Everything, with the DUT command the loader requires (see below).
simcrux import-riscv-arch-test ~/src/riscv-arch-test \
  --out ./simcrux.yaml \
  --isa rv32imc_zicsr_zifencei \
  --toolchain-prefix riscv64-unknown-elf- \
  --reference-model spike \
  --word-size 4 \
  --target-command './my_core --elf {elf} --signature {signature}'

# Just two extensions.
simcrux import-riscv-arch-test ~/src/riscv-arch-test --extensions I,M …

# The formal check set.
simcrux import-riscv-formal ~/src/riscv-formal/cores/picorv32/checks \
  --out ./formal.yaml --isa rv32imc --groups insn,reg

# Either sub-command's own usage.
simcrux import-riscv-arch-test --help
```

**Edge cases, and the reason each choice was made.**

- **`--target-command` is the one input an import cannot derive**, and the
  loader **requires** it in `mode: normal` — it is the command that runs
  *your* core for one architectural test. Supply it and the emitted config
  loads with zero errors and zero warnings. Omit it and the importer raises
  `missing_target_command`, the emitted file names it in its header comment,
  the GUI shows the warning-flavoured snackbar, and opening the file
  produces a loader error that says exactly which key is missing. All three
  of those are deliberate: the alternative is a file that looks fine and
  cannot run. There is no GUI field for it — filling it in is a one-line
  edit of a file the user now owns, and the scripted path already has the
  flag.
- **Two pickers, never a bespoke dialog.** The FuseSoC importer writes next
  to the `.core` file it read. These two cannot: the input is a directory
  inside somebody else's git checkout, and a generated file dropped into it
  shows up as untracked in their `git status` or fails outright on a
  read-only checkout. So the source and the destination are separate picks.
  An import-options dialog was rejected — it is a new shared-chrome surface
  suite UI consistency would then require in all four apps, for flags the
  CLI already exposes.
- **The import runs before the save dialog.** A wrong-directory pick is the
  common mistake, and there is no reason to make someone name an output file
  for an import that was never going to produce one.
- **The emitted file resolves from wherever it is opened**, not from wherever
  the importer ran. `arch_test.suite_path`, `formal.checks_dir`,
  `demo_signatures` and `formal.demo_outputs` are absolutized by the
  importers; `riscv.test` is relative to `suite_path` and
  `formal.sby_file` is relative to `checks_dir`. Move the file, open it from
  a Finder-launched build whose cwd is `/`, and it still resolves.
- **`--out` defaults to `./simcrux.yaml` in the working directory**, never
  inside the scanned tree — same reasoning as the two-picker GUI flow.
- **A multi-task `.sby` becomes one test per task**, with `multi_task_sby`
  raised. One `sby` invocation over several tasks prints several `DONE (…)`
  lines into one result row, which is precisely the fan-out the job model
  cannot represent (§18.3).
- **`--mode demo`** points either sub-command at a committed corpus of
  pre-captured outputs instead of a real checkout and emits `mode: demo`.
  That is how the shipped `examples/riscv-*-demo/` shape is reproducible
  from a command rather than by hand, and it spawns nothing.
- **`--mode riscof_passthrough` is refused**, with an explanation rather than
  a bare "invalid value": it is a run mode a user writes into their own
  config, and there is nothing for an importer to enumerate under it.
- **A wrong path is an import error, not a usage error.** Pointing at a
  directory with no `<ext>/src/*.S` beneath it, or no `.sby` files, exits 2
  with a message that names what was expected — including the reminder to
  run `python3 checks/genchecks.py` first.

| Check | Automatable? | How |
|---|---|---|
| Both sub-commands enumerate a realistic layout into one test per test/proof | **Yes** | `test/integration/riscv_import_fixture_test.dart` |
| The emitted YAML loads through the real `ConfigLoader` with zero errors | **Yes** | same file |
| …**and zero warnings** | **Yes** | same file |
| Every emitted path resolves against the suite / checks dir, not the cwd | **Yes** | same file |
| A `--mode demo` import runs end to end through the real `LocalJobScheduler` with a launcher that throws on any spawn | **Yes** | same file |
| Omitting `--target-command` warns *and* the loader refuses the result | **Yes** | same file |
| `--extensions` / `--groups` filters, case-insensitively | **Yes** | same file |
| A multi-task `.sby` expands per task and raises `multi_task_sby` | **Yes** | same file |
| Every flag maps to the right `defaults.riscv` key | **Yes** | `test/services/import/riscv_import_cli_test.dart` |
| `--target-command` is split like a shell splits it; placeholders survive | **Yes** | same file |
| A wrong path raises `RiscvImportException`, a bad flag `RiscvImportCliException` | **Yes** | same file |
| Both sub-command words reach the bootstrap without the primary parser seeing their flags | **Yes** | `test/core/cli/cli_arg_parser_test.dart` |
| Both actions are open-core, File-category, menu + palette, no chord | **Yes** | `test/core/shortcuts/` (`simcrux_action_test`, `menu_layout_test`, `shortcut_bindings_test`) |
| Locale sweep (en / zh_CN / zh / ja / ko) of the three new snackbars and two labels | **Yes** | `test/static/l10n_house_style_guard_test.dart` + `simcrux_action_test.dart` |
| The directory picker and the save dialog really appear, in that order | **No** | Manual — `FilePicker` is a platform channel |
| An import of a **real** `riscv-arch-test` checkout (thousands of tests) completes and the dashboard renders the result | **No** | Manual; needs the real checkout |


## 19. Standalone headless binary (`bin/simcrux.dart`)

### 19.1 What it does (plain language)

A Flutter-free `simcrux` executable, built with `tool/build_cli.sh`
(`dart build cli`, output at `build/cli/bundle/bin/simcrux`), mirroring
LintCrux's `bin/lintcrux.dart` / `LintcruxCli` split. It exists because
an Edalize/CI node must run without a window or a display server — the
desktop `bootstrap()` boots the Flutter engine before it reads a single
argument, so even its early-return headless branches need `dart:ui`.
`SimcruxCli` (`lib/core/cli/simcrux_cli.dart`) reaches the same
services those branches use — `CiRunner`, `FuseSoCImporter`,
`RiscvImportCli`, `DashboardBundleWriter` — through plain constructor
wiring: `--ci` with all `--export` targets and gates, `--import-fusesoc`,
`import-riscv-arch-test` / `import-riscv-formal`, `export-dashboard`,
`--help`. Anything else (a bare project path, no args) prints usage and
exits `2` — a CI binary that ran nothing must not exit `0`. It is also what
a FuseSoC/Edalize EDAM backend needs to drive SimCrux without a desktop
session.

Two deliberate differences from the desktop invocations: the binary's
telemetry is the no-op service unconditionally (never transmits —
silence is never consent, and it keeps `crux_telemetry`'s Flutter-bound
half out of the link), and the open-core binary carries the no-op
`--fail-on-regression` policy (the Pro CLI constructs its own
`SimcruxCli` with the real one).

Supporting seams this shipped: `lib/core/telemetry/
crux_telemetry_headless.dart` (the pure-Dart subset of `crux_telemetry`,
mirroring LintCrux's shim), `ConfigLoader` now imports
`crux_license_core.dart` (the Flutter-free barrel), and
`fail_on_regression_policy.dart` imports `package:riverpod` rather than
the Flutter-bound barrel.

### 19.2 Setup

```bash
tool/build_cli.sh          # builds + smoke-tests build/cli/bundle/bin/simcrux
```

### 19.3 Step-by-step expected behavior

1. `tool/build_cli.sh` compiles without error — **this is the proof the
   CLI import closure is Flutter-free**; a `package:flutter` import
   anywhere in it fails the build here.
2. `simcrux --ci simcrux.yaml --export junit=report.xml` on a real
   project with a real simulator: runs the regression, prints the
   summary line, writes valid JUnit XML, exit `0` all-pass / `1` at
   threshold.
3. `simcrux --import-fusesoc <core>` writes the `simcrux.yaml` beside
   the core with the importer's warning comments, exit `0`; a broken
   core exits `2`.
4. `simcrux` with no headless work prints the usage block and exits `2`.
5. `--reset` / `--no-restore` (the suite launch-recovery flags) are
   tolerated and stripped, exactly as `bootstrap()` does.

### 19.4 Edge cases

- A missing / malformed `simcrux.yaml` under `--ci` exits `2`, never a
  silent `0`.
- The binary never prompts (no consent dialog, no picker) — every
  interactive surface belongs to the desktop app.

### 19.5 Tier-gate scenarios

Open Core — the binary ships free. `--fail-on-regression` stays inert
(no-op policy), same as an open-core desktop `--ci` run.

### 19.6 Automation Assessment

| Test | Coverage | File |
|---|---|---|
| Help / unknown flag / nothing-headless / launch-flag stripping | `[Coverage: UNIT]` | `test/core/cli/simcrux_cli_test.dart` |
| `--ci` pass / fail / missing-config / JUnit export via a scripted driver | `[Coverage: UNIT]` | `test/core/cli/simcrux_cli_test.dart` |
| `--import-fusesoc` happy + broken paths | `[Coverage: UNIT]` | `test/core/cli/simcrux_cli_test.dart` |
| Headless telemetry shim surface | `[Coverage: UNIT]` | `test/core/telemetry/crux_telemetry_headless_test.dart` |
| `dart build cli` Flutter-freeness + smoke test | `[Coverage: MANUAL]` | `tool/build_cli.sh` |
| Real-simulator end-to-end (`icarus` + JUnit) | `[Coverage: MANUAL]` | §19.3 step 2 |

---

## 20. Screen reader and keyboard regions

### 20.1 What it does (plain language)

The desktop window can be used by ear and by keyboard alone. At launch,
keyboard focus lands on **Open Config…** on the start screen, so a screen
reader announces a named button rather than the window's class name. F6 and
Shift+F6 move between the window's regions — toolbar, start screen or the
tab's docks and dashboard, and the bottom chrome (statistics strip and status
bar) — and Tab stays inside a region until its controls are exhausted. Each
results-table row is one Tab stop, its check box, announced as one sentence:
"*status*: *suite* / *test*, *simulator*, ran in *runtime*"; Space toggles
its check box and Enter opens the test in the inspector. The sortable column
headers are announced as buttons. In the Tests dock a suite header is a
button that says whether it is expanded or collapsed, and each test is named
with its latest status ("tx_basic, Fail", or "not run"). A config that fails
to load is spoken — the error pane's title and detail — as well as drawn.
Tab chips are buttons named after the tab, selected when active, and each
chip's close button names its tab ("Close uart.yaml"). The statistics strip's
disclosure is announced as "Statistics". A user who binds a bare Space or
Enter to an action still activates the focused button with those keys. The
Keyboard Shortcuts settings list announces how to operate it and says "no
shortcut" for an unbound action. No user-visible string contains an arrow
glyph; menu paths are written `File > Open Config…`.

`WorkspaceScreen` (`lib/features/workspace/screens/workspace_screen.dart`) is
the `CruxFocusRegionScope`; the row change is in
`lib/features/dashboard/widgets/dashboard_results_table.dart`. The manual
protocol is §20.3.

### 20.2 Setup

A release build, not a debug run. Windows with NVDA or macOS with VoiceOver,
screen reader on. A config with a few results — the kit's flattened demo
config (demo mode spawns no simulator) or any project after one run.

### 20.3 Step-by-step expected behavior

1. Launch with no tabs open. The screen reader announces "SimCrux" and
   "Open Config… button". `[Coverage: WIDGET]`
2. Press F6 repeatedly: focus cycles toolbar, start screen, and back; the
   status bar region is skipped while it holds no control.
   `[Coverage: UNIT]` (crux-shared) + `[Coverage: MANUAL]`
3. Open a config and run it. Tab to the results table: each row is announced
   once, as the sentence above, followed by "check box not checked". Space
   checks it; Enter opens that test in the Details dock. `[Coverage: WIDGET]`
4. Tab through the Tests dock: "uart button expanded", "tx_basic, Pass
   button". Enter on a suite header collapses it and is announced as
   "collapsed"; its tests leave the Tab order. `[Coverage: WIDGET]`
5. Open a config whose YAML does not parse: the screen reader speaks
   "Couldn't load this project" and the reason, without moving focus.
   `[Coverage: WIDGET]` + `[Coverage: MANUAL]`
6. Tab to a column header: announced as "Status button", "Suite button", and
   so on; Enter sorts. `[Coverage: WIDGET]` + `[Coverage: MANUAL]` for the sort
7. Bind a bare Space to Run Regression in Settings > Keyboard Shortcuts, Tab
   to a toolbar button and press Space: the button activates and no run
   starts. `[Coverage: WIDGET]`
8. Settings > Keyboard Shortcuts: entering the list announces the keyboard
   hint; an unbound action is announced as "no shortcut". `[Coverage: MANUAL]`

### 20.4 Edge cases

- A row's check box no longer shares a Tab stop with the row itself; the
  row's click is pointer-only, and Enter on the check box is its keyboard
  form. `[Coverage: WIDGET]`
- A late subscriber to a run in progress — the rows table after a sort or
  filter change while one long test is still running — shows the results so
  far at once, not "Loading results…" until the next result lands.
  `[Coverage: UNIT]`
- The tab chip is announced as "simcrux.yaml button selected" with its full
  path as the description. `[Coverage: WIDGET]`
- Open Config… from the start screen with Enter: the focused button is
  rebuilt away when the tab replaces the start screen, and focus moves into
  the dashboard (the first filter preset) rather than being left on the
  window, so the screen reader announces a named control. `[Coverage: WIDGET]`

### 20.5 Tier-gate scenarios

Open Core — every tier. The Pro empty workspace (`EmptyWorkspaceState`) wraps
the same start screen and inherits the launch focus.

### 20.6 Automation Assessment

| Test | Coverage | File |
|---|---|---|
| Launch focus, start-screen walk, transcript golden | `[Coverage: WIDGET]` | `test/accessibility/screen_reader_test.dart`, `test/accessibility/goldens/start_screen.txt` |
| Open Config… by keyboard through the picker leaves focus on a named control | `[Coverage: WIDGET]` | `test/accessibility/screen_reader_test.dart` |
| Results dashboard walk: one sentence per row, no nameless check box, transcript golden | `[Coverage: WIDGET]` | `test/accessibility/screen_reader_test.dart`, `test/accessibility/goldens/results_dashboard.txt` |
| Tests dock walk: suite headers expand/collapse as buttons, tests carry their status, transcript golden | `[Coverage: WIDGET]` | `test/accessibility/screen_reader_test.dart`, `test/accessibility/goldens/tests_dock.txt` |
| Enter on a results row opens it in the inspector; Space toggles its check box | `[Coverage: WIDGET]` | `test/features/dashboard/widgets/dashboard_results_table_test.dart` |
| A failed config load is announced with the error pane's text | `[Coverage: WIDGET]` | `test/features/workspace/widgets/regression_tab_content_test.dart` |
| Every `currentRun` subscriber gets the run as it stands | `[Coverage: UNIT]` | `test/services/result_store/in_memory_result_store_test.dart` |
| The statistics disclosure is named "Statistics" | `[Coverage: WIDGET]` | `test/features/statistics/widgets/simcrux_stats_strip_test.dart` |
| Tab close buttons name their tab in every locale | `[Coverage: WIDGET]` | `test/features/workspace/widgets/simcrux_viewer_tab_bar_strings_test.dart` |
| Bare Space / Enter bindings yield to the focused control | `[Coverage: WIDGET]` | `test/core/shortcuts/shortcut_manager_widget_test.dart` |
| No arrow, box-drawing or private-use glyph in any locale | `[Coverage: UNIT]` | `test/static/speakable_strings_test.dart` |
| What NVDA or VoiceOver actually says, task completion by ear | `[Coverage: MANUAL]` | §20.3 |

---

## 21. Opening a design manifest (`<design>.crux-project`)

### 21.1 What it does (plain language)

A design manifest is a small YAML file named after the design —
`uart_tx/uart_tx.crux-project` — that tells each EDACrux product which file it
owns. SimCrux opens the regression config its `simulation:` entry names. It
opens from **Open Config…** on the start screen, from **File → Open Config…**
(both dialogs list `.crux-project` files), and as a positional argument to the
desktop app, where a design directory holding exactly one manifest works too.
All three routes go through `openConfigAsTab`
(`lib/features/workspace/widgets/open_config_tab.dart`) and
`CruxProjectResolver`
(`lib/features/workspace/services/crux_project_resolution.dart`).

A manifest named just `.crux-project` (the old name, hidden by file pickers and
Finder) still opens, and an info snack bar says what to rename it to. A
manifest that cannot be opened — invalid, no `simulation:` entry, a config that
is not on disk — and a directory holding more than one manifest open nothing
and say why in an error snack bar. Every message is localized.

### 21.2 Setup

A design directory `uart_tx/` holding `sim/simcrux.yaml` (any working project)
and `uart_tx.crux-project`:

```yaml
version: 1
name: uart_tx
artifacts:
  simulation: sim/simcrux.yaml
```

### 21.3 Step-by-step expected behavior

1. Start screen → **Open Config…**: `uart_tx.crux-project` is listed and
   selectable without showing hidden files. Opening it adds a
   `simcrux.yaml` tab for `sim/simcrux.yaml`, and the recents list gains that
   config, not the manifest.
2. **File → Open Config…**: the same, from the menu.
3. Terminal: `simcrux uart_tx/uart_tx.crux-project` and `simcrux uart_tx/`
   each open the same tab; running both on one command line opens one tab.
4. Rename the manifest to `.crux-project` and open it (the dialog needs hidden
   files shown, Cmd+Shift+. on macOS): the tab opens and a snack bar says to
   rename the file to `uart_tx.crux-project`.
5. Put `uart_tx.crux-project` and a copy `old.crux-project` in `uart_tx/` and
   run `simcrux uart_tx/`: no tab opens, and an error snack bar names both
   files.
6. Remove the `simulation:` entry: opening the manifest opens nothing and the
   snack bar says to add one. Point it at a missing file: the snack bar names
   the path.
7. macOS: in Finder, **Get Info** on `uart_tx.crux-project` lists SimCrux under
   **Open with**.

### 21.4 Edge cases

- `notes.crux-project.txt` is not a manifest: it is opened as whatever it is.
- The extension matches case-insensitively (`UART.CRUX-PROJECT`).
- Opening the directory and opening the manifest give the same design identity,
  so cross-probing is unaffected by the route.
- `simcrux --ci` takes the `simcrux.yaml` itself; it does not read manifests.

### 21.5 Tier-gate scenarios

Open Core — every tier and every build.

### 21.6 Automation Assessment

| Test | Coverage | File |
|---|---|---|
| Named, case-insensitive, legacy, directory, ambiguous, invalid, no-entry and missing-config resolution | `[Coverage: UNIT]` | `test/features/workspace/services/crux_project_resolution_test.dart` |
| A named manifest, a design directory, a legacy name and an ambiguous directory on the command line | `[Coverage: WIDGET]` | `test/features/dashboard/widgets/cli_regression_bootstrapper_test.dart` |
| Refusal messages and their locale sweep | `[Coverage: WIDGET]` | `test/features/workspace/widgets/open_config_tab_test.dart` |
| Both Open Config… dialogs list `.crux-project`; Finder Open With | `[Coverage: MANUAL]` | platform file dialog |

---

## 22. Opening a file from Finder (macOS)

### 22.1 What it does (plain language)

SimCrux registers four document types on macOS: `.yaml`/`.yml` project
files, `<design>.crux-project` manifests, `.simcrux-session` files and
`.simcrux-workspace` documents. Opening one from Finder, running
`open -a SimCrux <file>`, or dropping it on the Dock icon opens it the way the
same path on the command line would: a project, manifest or session file
becomes a tab, and a workspace document loads as `--workspace` loads it. This
works whether SimCrux was already running or the open launched it.

**`.yaml`/`.yml` are registered at `LSHandlerRank` `Alternate`**, so SimCrux
is listed under **Open With** for them but is never the default application
for every YAML file on the machine — it is an extension SimCrux shares with
every other tool that reads it. A double-click on `simcrux.yaml` therefore
opens whatever the user has chosen for YAML until they point it at SimCrux
themselves (Get Info → Open with → Change All). SimCrux's own extensions,
`.simcrux-session` and `.simcrux-workspace`, stay at owner rank and open on a
double-click. `.crux-project` is the suite's shared manifest and all four
products register it, all four at `Alternate`: none of them owns it, so
macOS asks which to open one with rather than ranking the four itself.

A double-click is a zero-click open of whatever file was clicked, so it takes
no shortcut: the project loads through the same config loader, with the
project-tooling gate closed unless the user opened it (§ project tooling in
`docs-site/docs/projects-and-simulators.md`), and its tab is armed, not run,
unless **Settings → General → Run the regression when a config is opened** is
on (§17).

The native half is `application(_:open:)` in `macos/Runner/AppDelegate.swift`,
registered in `MainFlutterWindow.swift`; the Dart half is
`lib/core/platform/incoming_file_service.dart`, and the routing is
`CliRegressionBootstrapper`. Windows and Linux receive files as command-line
arguments and are unaffected.

### 22.2 Setup

A release build of SimCrux in `/Applications` (a `flutter run` build is not
registered with Launch Services the same way), a project directory with a
`simcrux.yaml`, a manifest beside it (§21.2), and a saved `.simcrux-workspace`.

### 22.3 Step-by-step expected behavior

1. Quit SimCrux. In Finder, right-click `simcrux.yaml` → **Open With →
   SimCrux**: SimCrux launches with that project open in a tab, armed, not
   running.
2. With SimCrux running, open a second project's `.yml` the same way: it opens
   in a new tab; the first tab stays.
3. Select two project files in Finder, right-click → **Open With → SimCrux**:
   both open, one tab each.
4. Open the `.crux-project` manifest with **Open With → SimCrux** (no
   product owns the extension): the config its `simulation:` entry names
   opens.
5. Double-click the `.simcrux-workspace` — no Open With needed, SimCrux owns
   that extension: the workspace loads, as `simcrux --workspace <file>` would.
6. Drop a `simcrux.yaml` on the Dock icon: it opens.
7. Get Info on a `simcrux.yaml`: SimCrux is offered under **Open with** and is
   not the default until chosen. Choose it, **Change All…**, then
   double-click: SimCrux opens it.
8. Open a project whose `simulators:` entry sets `path:`, with
   **Settings → Simulators → Let project files choose simulator binaries and
   environment** off: the project loads with the advisory naming the key and
   the switch, and nothing runs.

### 22.4 Edge cases

- Opening a project that is already open does not open a second tab for it.
- A workspace document that cannot be read leaves the current workspace as it
  was, as `--workspace` does.
- A first run, with the licence agreement still to accept: the double-clicked
  project opens behind the agreement dialog.

### 22.5 Tier-gate scenarios

Open Core — every tier and every build.

### 22.6 Automation Assessment

| Test | Coverage | File |
|---|---|---|
| The channel contract: launch file first, later files after, nothing without a native half, nothing off macOS | `[Coverage: UNIT]` | `test/core/platform/incoming_file_service_test.dart` |
| A double-clicked config, `.yml`, session, manifest and workspace each open as their command-line spelling does; argv first; files opened while running; behind the first-run EULA gate; subscription ends with the widget | `[Coverage: WIDGET]` | `test/features/dashboard/widgets/cli_regression_bootstrapper_test.dart` |
| A tab's load uses the default-closed tooling gate and does not run | `[Coverage: UNIT]` | `test/features/dashboard/widgets/cli_regression_bootstrapper_test.dart` |
| `.yaml`/`.yml` and `.crux-project` are registered `Alternate` and SimCrux's own extensions are not | `[Coverage: STATIC]` | `test/static/macos_document_open_handler_test.dart` |
| The Swift half compiles | `[Coverage: BUILD]` | `flutter build macos` |
| Finder double-click, `open -a`, Dock drop on a real Mac | `[Coverage: MANUAL]` | release build |

---

## 23. Seeing the first-run dialogs again (`--reset-eula`, `--reset-telemetry-consent`)

### 23.1 What it does

The license agreement and the usage-statistics question each appear once per
installation. Two testing aids put them back: `--reset-eula` forgets the
accepted agreement version, `--reset-telemetry-consent` forgets the
usage-statistics answer. The desktop app acts on either at startup, before
anything reads the stored value, so the dialog appears on that same launch.
The standalone `simcrux` binary accepts both and does nothing with them.

### 23.2 Setup

An installation that has already accepted the agreement.

### 23.3 Expected behavior

1. Launch with `--reset-eula`: the agreement is presented on that launch.
2. Accept it, quit, launch without the flag: it is not presented again.
3. Launch with `--reset-eula --reset-telemetry-consent` on a build where
   telemetry is live: the agreement first, then the usage-statistics
   question.
4. `--help` lists `--reset-eula`; a misspelling such as `--reset-eulas` is
   still refused with exit `2`.
5. `simcrux --reset-eula --ci <project>` from the standalone binary runs the
   regression as it would without the flag.

### 23.4 Edge cases

- If the preferences store cannot be written, the flag does nothing and the
  launch proceeds; it is a testing aid, never a user-facing failure.

### 23.5 Tier-gate scenarios

Open Core — every tier and every build.

### 23.6 Automation Assessment

| Test | Coverage | File |
|---|---|---|
| `bootstrap` with `--reset-eula` removes the stored acceptance; without it the acceptance is kept | `[Coverage: UNIT]` | `test/app_reset_eula_test.dart` |
| The parser accepts the flag, with and without `--ci`, lists it in `--help`, and still rejects an unknown flag | `[Coverage: UNIT]` | `test/core/cli/cli_arg_parser_test.dart` |
| The standalone binary accepts both reset flags | `[Coverage: UNIT]` | `test/core/cli/simcrux_cli_test.dart` |
| The agreement is presented again on a real installation | `[Coverage: MANUAL]` | release build |

---

## 9+. Subsequent features

Add a new top-level section in the same commit set that ships the feature.

---

## 99. Sign-off

- [ ] All shipped-feature sections above signed off
- [ ] Open Core SHA: ____________________
- [ ] Verifier: ____________________
- [ ] Date: ____________________
- [ ] Platforms: ____________________
