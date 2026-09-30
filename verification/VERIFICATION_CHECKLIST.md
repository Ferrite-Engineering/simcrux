# SimCrux (Open Core) — Verification Checklist

> **Purpose.** Quick pre-release sign-off list. For step-by-step instructions, fixture inventory, and rationale, see `VERIFICATION_GUIDE.md` (sibling, this folder).
>
> **Pro overlay.** If you are signing off a Pro build, run this checklist first, then run the Pro overlay's own verification checklist for the Pro/Enterprise delta.

---

## Release metadata

- SimCrux version: ____________________
- Open Core SHA: ____________________
- Verifier: ____________________
- Date: ____________________
- Platform(s) tested: ____________________

---

## Pre-flight

- [ ] All fixtures present under `verification/fixtures/` — `[Coverage: MANUAL]`
- [ ] Simulators installed on the verifier's machine for the phase under test (Icarus + Verilator + optionally GHDL + Cocotb) — `[Coverage: MANUAL]`

---

## Foundation

> Shipped: tri-platform CI matrix, SQLite-backed persistent trend store, and the localized empty-canvas launch surface. (`ResultStore` is deliberately in-memory; persistence is the `TrendStore`.) See VERIFICATION_GUIDE.md §3.

### CI matrix (Linux / macOS / Windows)

- [ ] `analyze` job (Linux): pub-get → build_runner → gen-l10n → `flutter analyze --fatal-infos --fatal-warnings` → `dart format --set-exit-if-changed` all pass — `[Coverage: AUTOMATED — GitHub Actions]`
- [ ] `test` job runs green on all three OSes (`ubuntu`/`macos`/`windows`, `fail-fast: false`) — `[Coverage: AUTOMATED — GitHub Actions]`
- [ ] `build-desktop` (×3) + `build-web` release builds succeed and upload artifacts — `[Coverage: AUTOMATED — GitHub Actions]`

### SQLite trend-store round-trip

- [ ] Trend points written before a restart are present after relaunch (persistence at `<applicationSupport>/trends.db`) — `[Coverage: AUTOMATED — flutter test (sql_trend_store_test.dart, 'persistence across reopen')]`
- [ ] First point implicitly creates the run row; first-time test reports `previousStatus = null`; batch insert fires one `dataChanged`; empty batch is a no-op — `[Coverage: AUTOMATED — flutter test]`
- [ ] Store opens at the latest schema version, migrating older files — `[Coverage: AUTOMATED — flutter test (sql_migrations_test.dart)]`

### Empty-canvas launch surface

- [ ] Cold boot with no project lands on the empty-canvas state (0 tabs; "No recent configs yet." when empty) — `[Coverage: AUTOMATED — flutter test --tags integration (empty_canvas_boot_test.dart)]`
- [ ] Locale sweep (`en`/`zh_CN`/`ja`/`ko`) renders the primary actions without overflow — `[Coverage: AUTOMATED — flutter test (empty_canvas_content_test.dart)]`
- [ ] Switching theme preset flips MaterialApp brightness live — `[Coverage: AUTOMATED — flutter test --tags integration (theme_switch_test.dart)]`

## Icarus + Verilator + Dashboard

> Shipped: the `SimulatorDriver` contract with Icarus + Verilator drivers, the `LocalJobScheduler` happy path, the regression dashboard (counts + inspector drill-in), and the `simcrux.yaml` load path. See VERIFICATION_GUIDE.md §4.

### SimulatorDriver contract (Icarus + Verilator)

- [ ] Icarus pass/fail fixtures compile (`iverilog`) + run (`vvp`) and drive green/red dashboard rows — `[Coverage: AUTOMATED — flutter test + integration (icarus_driver_test.dart, fixture_pipeline_test.dart)]`
- [ ] Missing binary → `SimulatorNotAvailableException` surfaces as a `fail` row with a Settings → Simulators remediation hint (not an opaque `?`) — `[Coverage: AUTOMATED — flutter test]`
- [ ] `cancel` kills the in-flight process and escalates SIGTERM→SIGKILL after grace — `[Coverage: AUTOMATED — flutter test (verilator_driver_test.dart)]`
- [ ] Verilator: `-Wall -Wno-fatal` (warnings never fail the build), `--timing` + event-driven `sim_main.cpp` on Verilator 5, `simulators.verilator.options.args` appended; `verilator_timing` fixture passes — `[Coverage: AUTOMATED — flutter test (verilator_driver_test.dart) + --tags integration (fixture_pipeline_test.dart)]`

### JobScheduler happy path

- [ ] Parallelism bounded by `RegressionRequest.concurrency`; shared resource lock serializes; timeout cancels + reports `timeout` — `[Coverage: AUTOMATED — flutter test (local_job_scheduler_test.dart)]`
- [ ] `TestStarted`/`TestLog`/`TestFinished` emitted in order; exit codes classify pass/fail — `[Coverage: AUTOMATED — flutter test]`
- [ ] Default `NoopRetryPolicy` emits no retries; a re-run policy is capped by the scheduler-side ceiling — `[Coverage: AUTOMATED — flutter test]`

### Regression dashboard + inspector drill-in

- [ ] Status bar shows total/pass/fail/running/skipped counts (all-zero when no run active) — `[Coverage: AUTOMATED — flutter test (dashboard_status_bar_test.dart, dashboard_providers_test.dart)]`
- [ ] Filter/sort update the results table; selecting a row drives the inspector (details + log, dash for missing exit code) — `[Coverage: AUTOMATED — flutter test + integration (inspector_details_test.dart, seeded_run_dashboard_test.dart)]`
- [ ] Inspector "Open Source" button hands the selected test's resolved source path off to the configured editor — `[Coverage: AUTOMATED — flutter test --tags integration (inspector_open_source_test.dart)]`
- [ ] View-mode toggle switches the dashboard between table and heatmap; heatmap renders one cell per test and a cell tap drives the same inspector selection as a table row — `[Coverage: AUTOMATED — flutter test --tags integration (dashboard_heatmap_view_mode_test.dart)]`

### Test config YAML round-trip (load → model)

- [ ] Valid `simcrux.yaml` loads with merged defaults; parameterized templates expand to deterministic ids — `[Coverage: AUTOMATED — flutter test (config_loader_test.dart)]`
- [ ] Malformed YAML reports structured `file:line:col` errors, accumulated not fail-fast; no-simulator and unknown `pass_fail.type` reported; includes-cycle + oversized-sweep rejected pre-spawn — `[Coverage: AUTOMATED — flutter test]`

## GHDL, Cocotb, FuseSoC, Web Dashboard

> Shipped: GHDL + Cocotb + UVM detector, web dashboard, composite detector UI, streaming JSON, mixed-language designs, and FuseSoC `.core` import have all shipped.

### GHDL driver

- [ ] `test/fixtures/projects/vhdl_pass/` opens cleanly in SimCrux; `pass_basic` reports pass when ghdl is installed — `[Coverage: AUTOMATED — flutter test --tags integration]`
- [ ] `test/fixtures/projects/vhdl_fail/` reports fail end-to-end — `[Coverage: AUTOMATED — flutter test --tags integration]`
- [ ] `--vcd=`, `--fst=`, `--wave=` flags appear on the `ghdl -r` command for the three `WaveformFormat` values; not present when `capture: never` — `[Coverage: AUTOMATED — flutter test]`
- [ ] `ghdl` missing surfaces as `unknown` with a remediation hint — `[Coverage: AUTOMATED — flutter test]`

### Cocotb driver (Makefile wrap)

- [ ] `test/fixtures/projects/cocotb_dff/` opens cleanly in SimCrux when `make` + `cocotb-config` + `iverilog` are installed — `[Coverage: MANUAL]`
- [ ] `simulators.cocotb.options.sim` overrides the underlying simulator — `[Coverage: AUTOMATED — flutter test]`
- [ ] `parameters.sim` per-test override wins over the project-level option — `[Coverage: AUTOMATED — flutter test]`
- [ ] `cocotb.tests` / `cocotb.pass` / `cocotb.fail` / `cocotb.skip` / `cocotb.test.<name>.status` / `cocotb.test.<name>.sim_time_ns` appear on the inspector's Metrics tab for a Cocotb run — `[Coverage: AUTOMATED — flutter test]`
- [ ] A failing Cocotb run whose `make` exits 0 (Cocotb 1.9) is a FAIL with no `pass_fail:` block, including a 1.9/2.0 `results.xml` with no count attributes — `[Coverage: AUTOMATED — flutter test]`
- [ ] `docs/cocotb-strategy.md` documents the Makefile-wrap decision and the trigger conditions for revisiting — `[Coverage: MANUAL]`

### UVM report parser + UvmReportDetector

- [ ] `pass_fail: { type: uvm_report }` round-trips through the config loader with default thresholds (1 fatal / 1 error) — `[Coverage: AUTOMATED — flutter test]`
- [ ] `fatal_threshold` / `error_threshold` / `warning_threshold` round-trip when explicitly set — `[Coverage: AUTOMATED — flutter test]`
- [ ] Composite `all_of: [exit_code, uvm_report]` correctly fails when the UVM summary reports errors despite a zero exit code — `[Coverage: AUTOMATED — flutter test]`
- [ ] Parser tolerates both summary-table format and per-message-only output — `[Coverage: AUTOMATED — flutter test]`
- [ ] No UVM signal at all classifies as `unknown` (composite fall-through path) — `[Coverage: AUTOMATED — flutter test]`

### SimulatorDriverRegistry

- [ ] All four drivers (icarus / verilator / ghdl / cocotb) are reachable via the default `simulatorDriverRegistryProvider` — `[Coverage: AUTOMATED — flutter test]`
- [ ] Existing Icarus / Verilator `simcrux.yaml` files continue to load and run unchanged — `[Coverage: AUTOMATED — flutter test]`

### Streaming SARIF-like JSON writer

- [ ] `output: { streaming: true }` in `simcrux.yaml` produces `results.ndjson` + `results.summary.json` next to the project file — `[Coverage: MANUAL]`
- [ ] `--ci` mode produces the same files without an explicit `output:` block — `[Coverage: MANUAL]`
- [ ] An interrupted run leaves a readable NDJSON file with `summary == null` — `[Coverage: AUTOMATED — flutter test]`
- [ ] `StreamingResultsReader` + `StreamingResultsHydrator` round-trip rows back into the existing exporter pipeline — `[Coverage: AUTOMATED — flutter test]`
- [ ] Bounded-memory benchmark (100K-row synthetic stream) completes within process limits — `[Coverage: AUTOMATED — flutter test]`
- [ ] `output.results_path` / `output.summary_path` resolve against the project file's directory; `../`, an absolute path elsewhere, or a symbolic link that leads out stops the load at the value's line and column, and `--allow-project-tooling` lifts it — `[Coverage: AUTOMATED — flutter test (config_loader_output_paths_test.dart, project_output_path_test.dart)]`
- [ ] The writer refuses a path that leads out before creating or truncating anything, including a link that appears mid-run before the summary is written — `[Coverage: AUTOMATED — flutter test (streaming_results_writer_test.dart, ci_runner_test.dart)]`

### Composite detector UI

- [ ] Settings → Detectors section renders with empty-state body when no detectors are defined — `[Coverage: AUTOMATED — flutter test]`
- [ ] Adding a reusable detector persists across app restart — `[Coverage: MANUAL]`
- [ ] `simcrux.yaml` referencing `{type: use, name: <name>}` resolves to the stored tree — `[Coverage: AUTOMATED — flutter test]`
- [ ] Unknown reference produces a structured `ConfigLoaderError` with the path — `[Coverage: AUTOMATED — flutter test]`
- [ ] Detector cycle is detected before runtime — `[Coverage: AUTOMATED — flutter test]`
- [ ] Composite editor renders nested AND/OR children with add/remove buttons — `[Coverage: AUTOMATED — flutter test]`
- [ ] Locale sweep (en/zh_CN/ja/ko) renders without exceptions — `[Coverage: AUTOMATED — flutter test]`
- [ ] Existing inline detector definitions continue to load unchanged — `[Coverage: AUTOMATED — flutter test (full config_loader_test.dart suite)]`

### Web dashboard

- [ ] `flutter build web --target lib/main_web.dart` succeeds and produces a working `build/web/` directory — `[Coverage: AUTOMATED — workflow_dispatch CI job]`
- [ ] `simcrux export-dashboard ./out --web-bundle ./build/web` writes `simcrux-results.json` and copies the bundle alongside — `[Coverage: AUTOMATED — flutter test (DashboardBundleWriter)]`
- [ ] `simcrux export-dashboard ./out --results path/to/results.ndjson` synthesizes the consolidated JSON from the streaming NDJSON — `[Coverage: AUTOMATED — flutter test]`
- [ ] Served bundle renders the results table, filter chips, inspector dialog, and status-bar summary — `[Coverage: MANUAL]`
- [ ] Locale sweep (en/zh_CN/ja/ko) renders without exceptions — `[Coverage: AUTOMATED — flutter test (WebDashboardScreen locale sweep)]`
- [ ] `?results=<url>` query parameter overrides the same-origin fetch — `[Coverage: MANUAL]`

### Mixed-language designs

- [ ] `sources:` accepts both legacy bare strings and the object form `{ path, language }` — `[Coverage: AUTOMATED — flutter test (config_loader_mixed_language_test.dart)]`
- [ ] Unknown `language:` value raises a structured config-load error — `[Coverage: AUTOMATED — flutter test]`
- [ ] `MixedLanguageValidator` flags Icarus against a `.vhd` source / GHDL against a `.v` source — `[Coverage: AUTOMATED — flutter test (mixed_language_validator_test.dart)]`
- [ ] `MixedLanguageValidator` admits the Verilog + VHDL + Python triple under Cocotb — `[Coverage: AUTOMATED — flutter test]`
- [ ] `CocotbDriver` auto-derives `TOPLEVEL_LANG=verilog` from a `.v`-dominant source list — `[Coverage: AUTOMATED — flutter test (cocotb_driver_test.dart)]`
- [ ] `CocotbDriver` auto-derives `TOPLEVEL_LANG=vhdl` from a `.vhd`-dominant source list — `[Coverage: AUTOMATED — flutter test]`
- [ ] Per-test `parameters.TOPLEVEL_LANG` overrides auto-derivation — `[Coverage: AUTOMATED — flutter test]`
- [ ] Mixed-language fixture (`test/fixtures/projects/mixed_language/`) loads through `ConfigLoader().load()` — `[Coverage: AUTOMATED — flutter test (fixture_pipeline_test.dart)]`
- [ ] Per-source language overrides participate in `TOPLEVEL_LANG` dominance — `[Coverage: AUTOMATED — flutter test]`

### FuseSoC `.core` import

- [ ] CAPI2 header check rejects non-CAPI2 files with a structured exception — `[Coverage: AUTOMATED — flutter test (fusesoc_importer_test.dart)]`
- [ ] Simple single-target `.core` imports cleanly with zero warnings and round-trips through `ConfigLoader().parse()` — `[Coverage: AUTOMATED — flutter test (fusesoc_fixture_test.dart)]`
- [ ] Multi-target `.core` produces one suite per target with `toplevel:`; packaging targets (no `toplevel:`) are silently skipped — `[Coverage: AUTOMATED — flutter test]`
- [ ] Tool routing: `default_tool: icarus / verilator / ghdl / cocotb` produces the correct `simulator:` id — `[Coverage: AUTOMATED — flutter test]`
- [ ] Vendor / unrecognized tools fall back to `icarus` with `unsupported_tool` warning — `[Coverage: AUTOMATED — flutter test]`
- [ ] `paramtype: vlogparam` routes to `parameters:`, `vlogdefine` routes to `defines:` — `[Coverage: AUTOMATED — flutter test]`
- [ ] File-typed parameters surface `complex_parameter` warning and are skipped — `[Coverage: AUTOMATED — flutter test]`
- [ ] Top-level `vpi:` / `generators:` / `scripts:` blocks produce the corresponding `unsupported_*` warnings — `[Coverage: AUTOMATED — flutter test]`
- [ ] Non-HDL `file_type` (`xdc`, `tclSource`) surfaces `non_hdl_file_type` warning and keeps the file in `sources:` — `[Coverage: AUTOMATED — flutter test]`
- [ ] `simcrux --import-fusesoc <path>` CLI flag parses correctly and writes a `simcrux.yaml` next to the source — `[Coverage: AUTOMATED — flutter test (cli_arg_parser_test.dart, fusesoc_fixture_test.dart)]`
- [ ] Welcome screen exposes `Import FuseSoC .core File…` button across en/zh_CN/ja/ko — `[Coverage: AUTOMATED — flutter test (welcome_screen_test.dart locale sweep)]`
- [ ] GUI: importing a file with warnings shows a snackbar with the warning count; "Open in SimCrux" loads the synthesized YAML — `[Coverage: MANUAL]`
- [ ] Documentation: `docs-site/docs/fusesoc-import.md` describes the supported subset — `[Coverage: MANUAL — review]`

## Workspace + Multi-Tab + Split-Pane

### Empty-canvas state

- [ ] Fresh install → window opens to the SimCrux empty-canvas card with localized headline + subtitle in en/zh_CN/zh/ja/ko — `[Coverage: AUTOMATED — flutter test (empty_canvas_content_test.dart locale sweep)]`
- [ ] Four primary actions present and labeled per active locale: Open Config… / Open Session… / Open Workspace… / New Config — `[Coverage: AUTOMATED — flutter test]`
- [ ] Recent-configs list renders entries from `AppSettings.recentProjectPaths`; "No recent configs yet." placeholder when empty — `[Coverage: AUTOMATED — flutter test]`
- [ ] Opening a config from the picker hides the empty-canvas state and renders the per-tab dashboard scaffold — `[Coverage: MANUAL]`
- [ ] "New Config" creates an empty-payload tab that renders the projectScreenPlaceholder — `[Coverage: MANUAL]`

### Multi-tab workspace

- [ ] `simcrux a.yaml b.yaml c.yaml` opens three tabs in argv order — `[Coverage: AUTOMATED — flutter test (cli_arg_parser_test.dart)]`
- [ ] Per-tab provider isolation: filter / sort / selection / view-mode mutations stay scoped to their tab — `[Coverage: AUTOMATED — flutter test (simcrux_tab_overrides_test.dart)]`
- [ ] Tab bar chip drag reorders within a pane — `[Coverage: MANUAL]`
- [ ] Right-click chip context menu has Close Tab / Close Other / Close Tabs to the Right + disabled "Move to New Window" — `[Coverage: MANUAL]`
- [ ] In-progress regression in tab A survives switching to tab B and back; tab A's run state is intact on return — `[Coverage: MANUAL]`

### Split-pane

- [ ] Cmd/Ctrl+\\ splits the workspace into two side-by-side panes — `[Coverage: MANUAL]`
- [ ] Active pane shows a subtle border / accent — `[Coverage: MANUAL]`
- [ ] Per-pane provider isolation: `paneRenderStatsProvider` samples in pane A do not surface in pane B — `[Coverage: AUTOMATED — flutter test (simcrux_pane_overrides_test.dart)]`
- [x] `splitPaneRight` creates a second pane; `moveTabToPane` reassigns a tab's pane; emptying a pane collapses back to single-pane — `[Coverage: AUTOMATED — flutter test --tags integration (workspace/split_pane_test.dart)]`
- [ ] Drag tab from one pane's tab bar onto the other pane's tab bar moves it; source pane re-targets its active tab — `[Coverage: MANUAL]`
- [ ] Command palette → Close Pane closes the active pane and merges its tabs into the survivor — `[Coverage: MANUAL]`
- [ ] Command palette → Focus Other Pane toggles the active-pane indicator — `[Coverage: MANUAL]`
- [ ] Command palette → Move Tab to Other Pane moves the active tab — `[Coverage: MANUAL]`
- [ ] Closing the last tab in a non-active pane auto-collapses back to single-pane — `[Coverage: MANUAL]`

### Workspace persistence

- [x] Auto-managed `workspace.json` auto-saves on tab mutation and restores tabs on the next load — `[Coverage: AUTOMATED — flutter test --tags integration (workspace/restore_round_trip_test.dart)]` (approximates close+relaunch by flushing the debounced save and re-reading through a fresh `WorkspaceService`; pane-layout + active-selection restoration on a real relaunch remains `[Coverage: MANUAL]`)
- [x] File → Save Workspace As… writes a parseable `.simcrux-workspace` JSON document; File → Open Workspace… (`loadFrom`) round-trips it back — `[Coverage: AUTOMATED — flutter test --tags integration (workspace/named_workspace_test.dart)]`
- [ ] `simcrux --workspace <path>` (or File → Open Workspace…) replaces the current workspace — `[Coverage: AUTOMATED (parser) — flutter test (cli_arg_parser_test.dart); MANUAL (end-to-end)]`
- [ ] No "unsaved changes?" prompt under any tab/pane mutation — `[Coverage: MANUAL]`
- [ ] Corrupt `workspace.json` falls back to `Workspace.empty()` without crashing; the broken file is preserved — `[Coverage: AUTOMATED — flutter test (simcrux_workspace_codec_test.dart)]`

### Tab export as `.simcrux-session`

- [ ] File → Export Tab as Session… writes a `.simcrux-session` for the active tab — `[Coverage: MANUAL]`
- [ ] Opening a `.simcrux-session` adds a new tab to the current workspace — `[Coverage: MANUAL]`

### CLI behavior

- [ ] `simcrux` with no args → empty-canvas state — `[Coverage: MANUAL]`
- [x] `simcrux a.yaml b.yaml c.yaml` opens three tabs, one per positional config — `[Coverage: AUTOMATED — flutter test --tags integration (tabs/cli_multi_config_test.dart)]`
- [ ] `--workspace` + positional configs both honored together — `[Coverage: AUTOMATED (parser) — flutter test]`
- [ ] `simcrux --help` lists `--workspace` alongside the other options — `[Coverage: AUTOMATED — flutter test]`
- [ ] `--ci` loads the project at the tier from `--license-file` / `SIMCRUX_LICENSE_FILE` / the policy file (offline validation, grace on expiry); an unreadable explicit license file exits `2` before running; a machine file resolves only when the shared `crux/license/install.fingerprint` (or, before it exists, the adopted legacy `simcrux.fingerprint`) names its fingerprint — `[Coverage: AUTOMATED — flutter test (headless_license_tier_test.dart, simcrux_cli_test.dart, app_ci_driver_injection_test.dart)]`

### Auto-reload + scheduler isolation

- [ ] A file change in tab A's source re-runs tab A only; tab B is untouched — `[Coverage: AUTOMATED — flutter test (per_tab_auto_reload_test.dart)]`
- [ ] A broken-YAML load error in tab A banners in tab A only; tab B neither shows nor clears it — `[Coverage: AUTOMATED — flutter test (simcrux_tab_overrides_test.dart)]`
- [ ] No root-scoped provider reads per-tab state without being listed in `simcruxTabOverrides` (open-core-mode effective list; transitive reach included) — `[Coverage: AUTOMATED — flutter test (test/static/per_tab_provider_scope_leak_test.dart)]`
- [ ] Inspector → **Open full log** shows the launching tab's buffer (search / jump-to-line / Copy all operate on it), never the "No log output" empty state over a streaming inspector — `[Coverage: AUTOMATED — flutter test (log_viewer_dialog_test.dart, two-container shape, mutation-verified)]` + `[Coverage: STATIC — crux-shared route_mounted_scope_leak_test.dart]` (guide §6.4a)
- [ ] Cross-suite AutoReloadMode setting applies to every open tab — `[Coverage: MANUAL]`
- [ ] Each tab has its own `regressionRunnerProvider` notifier instance — `[Coverage: AUTOMATED — flutter test (per_tab_scheduler_isolation_test.dart)]`
- [ ] Each run executes at most its own concurrency (4 in the app, `--max-parallel` under `--ci`); runs in separate tabs are bounded separately, with no process-wide cap — `[Coverage: MANUAL — see VERIFICATION_GUIDE.md 6.8 known limitation]`

### Split-pane SimcruxAction values

- [ ] `splitPaneRight` bound to Cmd/Ctrl+\\ — `[Coverage: AUTOMATED — flutter test (shortcut_bindings_test.dart)]`
- [ ] `closePane` / `focusOtherPane` / `moveTabToOtherPane` are command-palette / menu-only (no default keyboard binding) — `[Coverage: AUTOMATED — flutter test]`
- [ ] Keyboard-shortcut conflict resolution (Guide §8.6) — default keymap is collision-free; rebinding an action onto another's chord shows asymmetric warnings (winner "Takes precedence over …", shadowed "Won't fire — shadowed by …") + a summary banner with the count; at runtime the **remapped** action fires (deterministic, not enum-order) — `[Coverage: UNIT]` (`test/core/shortcuts/shortcut_conflicts_test.dart`) + `[Coverage: WIDGET]` (`test/core/shortcuts/shortcut_manager_widget_test.dart`, `test/features/settings/widgets/shortcuts_settings_section_test.dart`)
- [ ] Command palette always reachable (Guide §8.7) — Open Command Palette appears under the Help menu (not in the palette itself); after unbinding Cmd/Ctrl+Shift+P it is still reachable via Help → Command Palette — `[Coverage: UNIT]` (`test/core/shortcuts/action_category_test.dart`)
- [ ] Action labels render in en/zh_CN/zh/ja/ko — `[Coverage: AUTOMATED — flutter test (simcrux_action_test.dart locale sweep)]`

## Cross-Probing & CXP Integration

### CXP server lifecycle
- [ ] CXP server binds on `127.0.0.1:54325` by default (verify via `lsof -i :54325`) — `[Coverage: PARTIAL — flutter test for provider lifecycle; manual lsof for OS-process visibility]`
- [ ] Manifest file `simcrux-<pid>-<startedAtMillis>.json` appears in the **suite-shared** directory (`~/Library/Application Support/crux/cxp/peers/` on macOS — NOT the per-app container, which peers in other apps cannot see) on start, removes on stop, and its `started_at` refreshes every ~30 s while running (heartbeat) — `[Coverage: AUTOMATED — simcrux_cxp_discovery_test.dart; shared-dir resolver + heartbeat crux_cxp peer_connectivity_test.dart]`
- [ ] Toggle "Enable cross-probe (CXP)" off → server stops + manifest removed; toggle on → server restarts with fresh manifest — `[Coverage: AUTOMATED — cxp_server_provider_test.dart]`
- [ ] Changing the port restarts the server on the new port — `[Coverage: AUTOMATED — cxp_server_provider_test.dart]`
- [ ] Invalid port (99999 or 0) → inline error "Enter a port between 1 and 65535."; no setting change — `[Coverage: AUTOMATED — settings_remote_control_section_test.dart]`

### Peer discovery + cross-probe panel
- [ ] Cross-probe panel opens via command palette → "Open Cross-Probe Panel" and via Tools menu — `[Coverage: MANUAL — desktop menu integration]`
- [ ] Status header reads "Cross-probe running on port 54325" when enabled, "Cross-probe is disabled." when off — `[Coverage: AUTOMATED — cross_probe_panel_test.dart]`
- [ ] Connected peers section lists every non-simcrux peer with productName + version + host:port + peerId — `[Coverage: AUTOMATED — cxp_discovery_provider_test.dart + panel widget]`
- [ ] **Unreachable-peer indicator:** a discovered peer whose dial keeps failing (closed port / stale manifest) shows a persistent amber "Couldn't reach <peer>" warning under the peer list within ~5 s; it clears on recovery/removal, hides SimCrux's own product, and renders nothing when all peers are reachable; localized in all five locales — `[Coverage: AUTOMATED — cross_probe_panel_test.dart (widget) + cxpDialFailuresProvider in cxp_discovery_provider_test.dart + simcrux_cxp_discovery_test.dart (service getters)]` + visual/multi-process `[Coverage: MANUAL]`
- [ ] "Send selection to <Product>" delivers a `NotifySelection` carrying the active test id; outbound event appears in Recent activity — `[Coverage: PARTIAL — outbound emit unit-tested; multi-process flow MANUAL]`
- [ ] Recent activity buffer trims to 50 entries; "Clear" button empties the buffer and disables when already empty — `[Coverage: AUTOMATED — cross_probe_panel_test.dart]`
- [ ] Foreign peer manifest disappearing from the shared directory removes the peer row within ~2 scan ticks — `[Coverage: AUTOMATED — simcrux_cxp_discovery_test.dart]`
- [ ] **Mutual connect:** SimCrux + a second suite app on one machine end up MUTUALLY CONNECTED within ~5 s (discovered manifest → symmetric connector dial → inbound Hello on both servers); rows persist past 5 minutes (heartbeat); SimCrux never lists itself; panel shows the **Discovery directory** line naming the shared path — `[Coverage: AUTOMATED — simcrux_cxp_discovery_test.dart "… end up MUTUALLY CONNECTED"; crux_cxp peer_connectivity_test.dart]` + real two-app flow `[Coverage: MANUAL]`
- [ ] **Connector-link routing (pin `20b7305`):** presence (mutual connect) does NOT imply traffic routes — a full peer stack's `server.inbound` genuinely receives a request sent over the connector-dialed link, and SimCrux's own `server.inbound` genuinely receives the reply — `[Coverage: AUTOMATED — simcrux_cxp_discovery_test.dart "end-to-end product traffic over the connector-dialed link…"]`

### notify_selection emit
- [ ] Selecting a different test broadcasts `NotifySelection(kind=test, path=<suite>/<name>...)` — `[Coverage: AUTOMATED — notify_selection_emitter_test.dart + conformance suite]`
- [ ] "Open testbench source" broadcasts `NotifySelection(kind=source, path=<absolute>)` — `[Coverage: AUTOMATED — notify_selection_emitter_test.dart]`
- [ ] Same-value writes are debounced (no re-emit) — `[Coverage: AUTOMATED — notify_selection_emitter_test.dart]`
- [ ] CXP disabled → no emit — `[Coverage: AUTOMATED — notify_selection_emitter_test.dart]`
- [ ] With a workspace mounted, selections made in the ACTIVE tab container broadcast (the emitter tracks the active tab, re-attaching on tab switch) — `[Coverage: AUTOMATED — notify_selection_emitter_test.dart]`
- [ ] A real connector-linked peer (server + manifest writer + discovery + connector, no manual `Subscribe`) receives the broadcast on its own `server.inbound` — the connector auto-subscribes every link on handshake — `[Coverage: AUTOMATED — notify_selection_emitter_test.dart "broadcasts reach a real connector-linked peer…"]`

### Inbound request_highlight + request_open_source handlers
- [ ] RequestHighlight(test) for a test in the loaded config selects it in the ACTIVE tab's scope + acks honored:true — `[Coverage: AUTOMATED — inbound_request_handler_test.dart + conformance suite]`
- [ ] RequestHighlight(test) for an unknown test id (or with no config loaded) acks honored:false with reason "not found"; no state change — `[Coverage: AUTOMATED — inbound_request_handler_test.dart]`
- [ ] Inbound selection/filter mutations land in the ACTIVE tab container; dormant root instances stay untouched — `[Coverage: AUTOMATED — inbound_request_handler_test.dart (workspace-mounted group)]`
- [ ] A `RequestHighlight` arriving over a real connector-dialed link (full peer product, not a raw client) still lands in the ACTIVE tab container, and the peer's own `server.inbound` genuinely receives the ack back — `[Coverage: AUTOMATED — inbound_request_handler_test.dart "…over a REAL connector-dialed link…"]`
- [ ] RequestHighlight(source) records the explicit source selection + acks honored:true — `[Coverage: AUTOMATED]`
- [ ] RequestHighlight(signal/net/port/instance/scope) filters the dashboard by the leaf identifier + acks honored:true — `[Coverage: AUTOMATED]`
- [ ] RequestHighlight(breakpoint) acks honored:false with reason mentioning "breakpoint editor" — `[Coverage: AUTOMATED]`
- [ ] RequestHighlight(marker/rule) acks honored:false with a clear reason — `[Coverage: AUTOMATED]`
- [ ] RequestOpenSource shells to the configured editor + acks honored:true; malformed template acks honored:false — `[Coverage: PARTIAL — stub launcher AUTOMATED; real editor handoff MANUAL]`
- [ ] **Containment (CXP §11):** a `request_open_source` path, a `request_open_artifact` record or path hint, or a highlight's `crux.design_id` fallback that lies outside the directories the user has opened (every tab's config directory, every recent project's directory, the active config's source and include directories) acks honored:false with a reason that never repeats the path, and no editor opens — `[Coverage: AUTOMATED — inbound_request_handler_test.dart "CXP §11 containment" group (the handler's own check, mutation-verified), simcrux_cxp_conformance_test.dart (refused at the server through the production factory), simcrux_cxp_server_test.dart (refused before inbound), cxp_workspace_link_test.dart (the roots)]`
- [ ] **Peer auth:** a peer whose `hello` does not carry the token SimCrux published in its discovery manifest is refused `unauthorized` — `[Coverage: AUTOMATED — simcrux_cxp_server_test.dart, simcrux_cxp_conformance_test.dart]`

### "Debug in WaveCrux" originator flow
- [ ] Button appears on selected test result rows; tooltip explains WaveCrux must be running — `[Coverage: MANUAL — visual]`
- [ ] Click with connected WaveCrux peer → snackbar "Sent to WaveCrux (<peerId>)." + WaveCrux opens the waveform — `[Coverage: PARTIAL — dispatcher logic AUTOMATED; WaveCrux opens-waveform MANUAL]`
- [ ] `NotifySelection` carrying `simcrux.suggested_signals` metadata precedes the `RequestHighlight` — `[Coverage: AUTOMATED — debug_in_wavecrux_dispatcher_test.dart]`
- [ ] No WaveCrux peer → snackbar "WaveCrux is not connected. ..." + no outbound events — `[Coverage: AUTOMATED]`
- [ ] CXP disabled → snackbar pointing at Settings → Remote Control — `[Coverage: AUTOMATED]`
- [ ] Test without captured waveform → snackbar "This test did not capture a waveform. ..." — `[Coverage: AUTOMATED]`
- [ ] **Delivery is observed, not assumed:** dispatching to a real connector-linked WaveCrux-style peer (full stack, not a raw client) proves genuine RECEIPT on the peer's own `server.inbound` and the ack's genuine receipt on SimCrux's own `server.inbound` — not merely `dispatch()` returning `outcome: dispatched` — `[Coverage: AUTOMATED — debug_in_wavecrux_dispatcher_test.dart "connector-linked peer (production topology)"]`

### Settings → Remote Control
- [ ] Section appears between Editors and Detectors — `[Coverage: MANUAL]`
- [ ] Switch reflects current `cxpServerEnabled`; port field reflects current `cxpServerPort` — `[Coverage: AUTOMATED — settings_remote_control_section_test.dart]`
- [ ] Settings round-trip via `SimcruxSettingsCodec` (`simcrux.cxpServerEnabled`, `simcrux.cxpServerPort`) — `[Coverage: AUTOMATED — codec tests]`
- [ ] All five locales (en/zh_CN/zh/ja/ko) render the section without exception — `[Coverage: AUTOMATED — locale sweep]`

### Cross-suite end-to-end
- [ ] With SimCrux + WaveCrux running, a failing-test "Debug in WaveCrux" opens the .vcd in WaveCrux and the cursor lands on a sensible default — `[Coverage: MANUAL — two running apps]`

## Pro re-run + heatmap seams

### `RegressionRunner.submitSpecs` (open-core)
- [ ] Submits a partial regression against the active `RegressionConfig` without overwriting `activeConfigProvider` — `[Coverage: AUTOMATED — regression_runner_test.dart]`
- [ ] Empty specs list is a silent no-op — `[Coverage: AUTOMATED]`
- [ ] No active config (project closed) is a silent no-op — `[Coverage: AUTOMATED]`
- [ ] Submitted specs are registered with `reRunQueryServiceProvider` automatically (no caller-side tracking needed) — `[Coverage: AUTOMATED]`

### Action toolbar (§8.3.1) + `extraDashboardActionsProvider` (open-core)
- [ ] `SimcruxToolbar` shows the curated open-core buttons (Run / Stop / Re-run Selected / Search) at the top of the dashboard; each dispatches the same action as its menu/palette equivalent (tooltips = localized action labels); scrolls horizontally when narrow — `[Coverage: WIDGET — simcrux_toolbar_test.dart]` + `[Coverage: MANUAL]` (Run actually starts a regression)
- [ ] **Re-run Selected runs exactly one test** on a multi-suite project — not the selected test plus every other suite — and a subsequent plain Run Regression still runs the full config (`activeConfigProvider` was never narrowed) — `[Coverage: WIDGET — simcrux_action_handlers_test.dart]` + `[Coverage: MANUAL]` (real simulator)
- [ ] **Close All Tabs confirms first**: the dialog appears; Cancel and barrier-dismiss both leave every tab open; Confirm closes every open workspace tab; no registry involvement, no PRO badge; dialog copy translated in all five ARB files — `[Coverage: WIDGET — simcrux_action_handlers_test.dart, confirm_dialog_test.dart]`
- [ ] **No silent no-ops**: Run / Stop / Re-run Selected / Close Project / Close All Tabs with no project open each show the "no project is open" snack; Re-run Selected with no selection shows the "no test is selected" snack — `[Coverage: WIDGET — simcrux_action_handlers_test.dart]`
- [ ] **Snacks match badges**: an absent opener produces "requires SimCrux Pro"; the Pro-tier multi-project actions (`switchProject`, `reopenRecentProject`, `closeAllProjects`) each render a PRO badge **and** show the Pro-gated snack — no action shows an info snack that contradicts its badge — `[Coverage: WIDGET — simcrux_action_handlers_test.dart, simcrux_action_test.dart]`
- [ ] `extraDashboardActionsProvider` default returns an empty list (open-core toolbar shows only the four general buttons) — `[Coverage: AUTOMATED — dashboard_actions_extensions_test.dart]`
- [ ] Pro extension widgets fold into the toolbar after a divider when the provider is populated (no standalone `DashboardActionsRow`) — `[Coverage: WIDGET — simcrux_toolbar_test.dart fold-in case]`

### `riscvCompatibilityOpenerProvider` (open-core, Guide §18.4)
- [ ] Default returns `null` (no opener registered) — `[Coverage: AUTOMATED — riscv_compatibility_opener_test.dart]`
- [ ] The default is tier-independent at every `LicenseTier` × `kBetaPeriod` combination — `[Coverage: AUTOMATED]`
- [ ] Override surfaces a callable opener — `[Coverage: AUTOMATED]`
- [ ] **The compatibility verdict is never gated by this seam**: an unlicensed post-beta build still runs `riscv_arch` and still renders per-test pass/fail in the ordinary dashboard — `[Coverage: AUTOMATED — Pro overlay `ungated_verdict_test.dart`]` + `[Coverage: MANUAL]` (post-flip build)

### `riscvFormalOpenerProvider` (open-core, Guide §18.6)
- [ ] Default returns `null` (no opener registered) — `[Coverage: AUTOMATED — riscv_formal_opener_test.dart]`
- [ ] The default is tier-independent at every `LicenseTier` × `kBetaPeriod` combination — `[Coverage: AUTOMATED]`
- [ ] Override surfaces a callable opener — `[Coverage: AUTOMATED]`
- [ ] **The formal verdict is never gated by this seam**: an unlicensed post-beta build still runs `riscv_formal`, still renders per-property pass/fail in the ordinary dashboard, and still carries the counterexample VCD on `waveformPath` — `[Coverage: AUTOMATED — Pro overlay `ungated_formal_verdict_test.dart`]` + `[Coverage: MANUAL]` (post-flip build)

### `seedFailureHeatmapOpenerProvider` (open-core)
- [ ] Default returns `null` (no opener registered) — `[Coverage: AUTOMATED — seed_failure_heatmap_opener_test.dart]`
- [ ] Override surfaces a callable opener — `[Coverage: AUTOMATED]`
- [ ] `SimcruxAction.openSeedFailureHeatmap` dispatched from the command palette is a silent no-op in an open-core build — `[Coverage: MANUAL — visual]`
- [ ] Action label renders in every locale (en/zh_CN/zh/ja/ko) — `[Coverage: AUTOMATED — locale sweep through action label tests]`

### Plugin-SDK action opener seams (Guide §8.8)
- [ ] `pluginManagerOpenerProvider` / `reloadPluginsOpenerProvider` default to `null`; both actions surface the Pro-gated snackbar in an open-core build — `[Coverage: MANUAL — visual]` (populated case covered by the Pro guide)

### Trend retention enforcement + App Diagnostics trend-store section (Guide §8.9)
- [ ] `RegressionRunner` applies `retentionPolicyProvider` against the trend store after every completed run; ingestion past the policy horizon prunes — `[Coverage: AUTOMATED — regression_runner_test.dart retention group]`
- [ ] Unlimited policy leaves ingested points in place; `storageStats` reflects reality — `[Coverage: AUTOMATED]`
- [ ] App Diagnostics dialog's Trend store section renders summary / size-unknown / empty states across all five locales — `[Coverage: AUTOMATED — app_diagnostics_dialog_test.dart]`

### Registry↔workspace sync + empty-canvas seam (Guide §8.11)
- [ ] Recorder: opening a config tab records the project into the registry (active follows the active tab; closing a tab closes the project → recents; empty-path tabs skipped) — `[Coverage: AUTOMATED — project_workspace_sync_test.dart]`
- [ ] Follower: registry-originated open/setActive opens-or-activates the matching tab; registry-originated close closes it (delta-based — the boot emission never wipes restored tabs) — `[Coverage: AUTOMATED]`
- [ ] Loop safety: serialized convergence loop settles (mutation counters stop growing); replace-on-open (Noop) registries detected and mirrored active-tab-only — `[Coverage: AUTOMATED]`
- [ ] `emptyCanvasContentBuilderProvider` default null → `WorkspaceScreen` renders the built-in `EmptyCanvasContent`; Pro override case covered in the Pro repo — `[Coverage: AUTOMATED — existing WorkspaceScreen render paths]`
- [ ] `ProjectTabStrip` removed (superseded by the crux_workspace viewer tab bar) — no dangling references or ARB keys — `[Coverage: AUTOMATED — analyzer + gen-l10n]`

### Multi-project action seams + PR-annotation seams (Guide §8.10)
- [ ] `switchProject` / `reopenRecentProject` / `closeAllProjects` are `LicenseTier.pro`, render a PRO badge in the command palette and a ` (PRO)` suffix in the native menu bar, and each surfaces "requires SimCrux Pro" when its opener is null — `[Coverage: WIDGET — simcrux_action_handlers_test.dart]` + `[Coverage: UNIT — simcrux_action_test.dart]`
- [ ] `closeAllTabs` is `LicenseTier.openCore`, renders **no** badge, and closes every open workspace tab after confirmation — the free capability that `closeAllProjects` used to provide — `[Coverage: WIDGET — simcrux_action_handlers_test.dart]`
- [ ] `pinActiveProject` routes through `pinActiveProjectOpenerProvider`; open core shows "requires SimCrux Pro" even with a project open — `[Coverage: WIDGET — simcrux_action_handlers_test.dart]`
- [ ] `dispatchPrAnnotations` / `configurePrAnnotationTarget` route through `prAnnotationDispatchOpenerProvider` / `prAnnotationSettingsOpenerProvider`; open core shows "requires SimCrux Pro" — `[Coverage: WIDGET — simcrux_action_handlers_test.dart]`

## Color Theming & Customization (suite-wide)

See VERIFICATION_GUIDE.md §9 for step-by-step instructions.

- [ ] Picking `WaveCrux Light` flips MaterialApp brightness to light — `[Coverage: MANUAL]`
- [ ] Picking `WaveCrux Dark` from light state flips brightness back to dark — `[Coverage: MANUAL]`
- [ ] Picking `Solarized Dark` re-tints toolbar / scaffold / panel backgrounds with Solarized hues — `[Coverage: MANUAL]`
- [ ] Picking `Oscilloscope` re-tints chrome with phosphor-green-on-black — `[Coverage: MANUAL]`
- [ ] Active preset survives an app restart — `[Coverage: MANUAL]`
- [ ] Per-token chrome override: edit `toolbar.background`, observe immediate repaint, reset clears it — `[Coverage: MANUAL]`
- [ ] Import `.crux-theme.json` via Theme pack browser: pack appears in installed list, Activate applies tokens — `[Coverage: MANUAL]`
- [ ] Export active theme writes a valid `.crux-theme.json` — `[Coverage: AUTOMATED]` (`crux_theme` package suite)
- [ ] No exception in en / zh_CN / ja / ko locale sweeps for Settings → Appearance — `[Coverage: MANUAL]`

## Orchestration Robustness & Performance

See VERIFICATION_GUIDE.md §10 for step-by-step instructions. Bulk runs against the
in-process fake process runner — no real simulator needed.

Process lifecycle & tree-reaping (Guide §10.1):
- [ ] 12 process-lifecycle edge cases pass — `[Coverage: INTEGRATION]` (`process_lifecycle_edge_cases_test.dart`)
- [ ] SIGTERM-honoured exits record `killSignal: SIGTERM`; SIGTERM-ignored escalate to SIGKILL — `[Coverage: INTEGRATION]`
- [ ] Cocotb grandchildren are tree-reaped (zero orphaned `liveHandles`) — `[Coverage: INTEGRATION]`
- [ ] Orchestration golden corpus replays match committed `expected_results.ndjson` (both fixture trees) — `[Coverage: INTEGRATION]` (`orchestration_golden_test.dart`)
- [ ] Each scenario's committed `simcrux.yaml` **loads through the real `ConfigLoader`** and its specs mirror the ones the scheduler runs (name / suite / `top` / seed / timeout) — `[Coverage: INTEGRATION]` (`orchestration_golden_test.dart`)
- [ ] Opening any `verification/fixtures/orchestration/*/generated/simcrux.yaml` via **File → Open Project** succeeds (no `ConfigLoaderException`) — `[Coverage: MANUAL]`
- [ ] `dart run tool/generate_orchestration_fixtures.dart` regenerates the corpus cleanly — `[Coverage: AUTOMATED]`

Runaway-regression & resource guards (Guide §10.2):
- [ ] A multi-axis sweep over 10 000 specs (e.g. 100×100×2) is rejected before any spawn — `[Coverage: UNIT]` (`config_expansion_fuzz_test.dart`)
- [ ] Imported FuseSoC configs hit the same expansion ceiling — `[Coverage: UNIT]`
- [ ] 1e6 captured stdout lines stay bounded with a non-zero dropped counter — `[Coverage: UNIT]` (`driver_stdout_bounded_test.dart`)
- [ ] Retained dumps prune to keep-last-N / total-byte ceiling across every run — `[Coverage: UNIT]` (`cross_run_dump_retention_test.dart`)
- [ ] A catastrophic regex over a 4 MB log returns under its deadline (isolate killed) — `[Coverage: UNIT]` (`regex_detector_redos_test.dart`)

Persistence durability & crash recovery (Guide §10.3):
- [ ] A truncated / garbled `results.ndjson` tail is trimmed to the last complete record, idempotently — `[Coverage: UNIT]` (`persistence_recovery_edge_cases_test.dart`)
- [ ] Retention prune + `VACUUM` shrinks the on-disk trend DB — `[Coverage: HYBRID]` (`sql_recovery_test.dart`)
- [ ] An unfinalized run is marked `interrupted`, not silently passed — `[Coverage: HYBRID]`
- [ ] A corrupt DB is renamed aside (never deleted), a fresh one opens in its place, and the damaged bytes are byte-identical at `trends.db.corrupt-…` — `[Coverage: HYBRID]` (`sql_recovery_test.dart`)
- [ ] A future `user_version` → `CruxSchemaVersionSkewException` naming both versions and the backup — `[Coverage: HYBRID]`
- [ ] The production `trendStoreProvider` resolves to a working store after a quarantine and raises the App Diagnostics notice (never a raw `DatabaseException` error state) — `[Coverage: HYBRID]` (`trend_store_provider_corruption_test.dart`)
- [ ] App Diagnostics shows the damaged-database card naming the quarantined file, and the pre-upgrade `.bak` when one exists — `[Coverage: WIDGET]` (`trend_store_recovery_card_test.dart`)
- [ ] **Rebuild from results.ndjson…** replays a `--ci` archive: every trend-point field round-trips, a complete run is not relabelled interrupted, a second pass over the same archive recovers 0, and the archive is never rewritten — `[Coverage: HYBRID]` (`trend_store_rebuild_test.dart`)
- [ ] Manual, once per release: the end-to-end damage → notice → rebuild pass in VERIFICATION_GUIDE.md §10.3.1 — `[Coverage: MANUAL]`

Determinism & seed surfacing (Guide §10.4):
- [ ] Each driver surfaces the effective seed (requested or derived) and injects it where the simulator supports it — `[Coverage: UNIT]` (`effective_seed_surfacing_test.dart`)
- [ ] `config_hash` changes when the test list / parameter set changes — `[Coverage: UNIT]` (`config_hash_guard_test.dart`)
- [ ] The first flaky retry replays the effective (clock-derived) seed — `[Coverage: INTEGRATION]` (`seed_replay_test.dart`)
- [ ] `jobSchedulerProvider` injects `retryPolicyProvider` into `LocalJobScheduler` (an override reaches the run loop, not the `NoopRetryPolicy` default) and the scheduler invokes `PreparableRetryPolicy.prepareForRun` at run start before the first test — `[Coverage: INTEGRATION]` (`retry_policy_wiring_test.dart`)

Long-run memory soak (Guide §10.5):
- [ ] `dart run tool/soak/regression_soak.dart` shows RSS roughly flat between 1000-test checkpoints — `[Coverage: HYBRID]`
- [ ] The log ring keeps a flat retained working set (75% ≈ 100%) — `[Coverage: HYBRID]` (`memory_soak_test.dart`)
- [ ] The streaming writer keeps an O(1) footprint across 10k results; the store never pins full logs — `[Coverage: HYBRID]`

Dashboard / aggregation performance at scale (Guide §10.6):
- [ ] A 10k-row results table realizes only the visible rows (virtualized) — `[Coverage: WIDGET]` (`dashboard_render_test.dart`)
- [ ] Streaming run: 2 000 fast-arriving results coalesce to a bounded handful of rows rebuilds (leading edge immediate, trailing edge flushes the final state; per-result full-pipeline recompute is the mutation) — `[Coverage: WIDGET]` (`dashboard_render_test.dart` streaming scenario)
- [ ] The per-test trend aggregate is served by the composite index (no SCAN / temp-sort) — `[Coverage: HYBRID]` (`trend_query_index_test.dart`); the raw < 200 ms wall-clock budget is nightly-only — `[Coverage: BENCH]` (`trend_query_wallclock_bench_test.dart`)
- [ ] A 100k-line log opens ring-bounded, not materializing all lines — `[Coverage: UNIT]` (`inspector_log_render_test.dart`)

Static guardrails + CI self-enforcement (Guide §10.7):
- [ ] No `test/services/**` file spawns a real OS process (real spawns live in `test/integration/**`) — `[Coverage: STATIC]` (`no_real_process_spawn_in_unit_tests_test.dart`)
- [ ] Every orchestration fixture lives under `generated/` (no loose files) — `[Coverage: STATIC]` (`orchestration_fixture_layout_test.dart`)
- [ ] Every scenario has `simcrux.yaml` + `behaviors.json` + a golden — `[Coverage: STATIC]` (`orchestration_fixture_companion_test.dart`)
- [ ] Every committed `simcrux.yaml` in both corpora **parses** through `ConfigLoader` (presence is not validity) — `[Coverage: STATIC]` (`orchestration_fixture_companion_test.dart`)
- [ ] `test/integration/**` real-simulator tests skip cleanly when the binary is absent (never fail CI) — `[Coverage: HYBRID]`

Lifecycle robustness (Guide §10.8):
- [ ] **File → Quit mid-regression leaves no surviving simulator process** — check `ps` for `vvp` / `verilator` / `python` descendants after quitting — `[Coverage: MANUAL]`
- [ ] Window close and Cmd-Q / Alt-F4 reap identically (`AppExitGuard` → `AppLifecycleListener.onExitRequested`) — `[Coverage: MANUAL]`
- [ ] Runs started in **background tabs** are reaped too (the registry is app-scoped) — `[Coverage: MANUAL]`
- [ ] A wedged driver delays the quit by at most 8 s and never blocks it — `[Coverage: UNIT]` (`app_exit_coordinator_test.dart`)
- [ ] Quit drains in-flight runs before calling exit — `[Coverage: WIDGET]` (`simcrux_action_handlers_test.dart` → `group('quit')`)
- [ ] A shared `resources:` lock is held by exactly one test at a time; waiters served FIFO; no double-grant under a forced interleaving — `[Coverage: UNIT]` (`resource_lock_table_test.dart`)
- [ ] `--ci` against an unregistered simulator exits **non-zero** and prints the `unknown` count — `[Coverage: UNIT]` (`ci_runner_test.dart`)
- [ ] The `--ci` summary's printed components sum to its printed total (every status shown) — `[Coverage: UNIT]` (`ci_runner_test.dart`)
- [ ] `--export` creates missing parent directories; the summary line is printed before exports, and a target that cannot be written is reported on stderr, the rest are written, exit `2` — `[Coverage: UNIT]` (`ci_runner_test.dart` → `exports`)
- [ ] Load advisories (a sweep the tier did not expand) print on stderr as `warning: path:line:col: message` — `[Coverage: UNIT]` (`ci_runner_test.dart`)
- [ ] `--fail-on-vacuous` flips a vacuous-only run from exit 0 to exit 1; default stays 0 — `[Coverage: UNIT]` (`ci_runner_test.dart`)
- [ ] A `kill -9` mid-run leaves the trend-store run marked `interrupted` after relaunch (reconciliation runs at store open) — `[Coverage: HYBRID]` (`sql_recovery_test.dart` → `reconcileAtOpen:`)
- [ ] A `--ci` run that errors mid-flight flushes its NDJSON and writes **no** `summary` line — `[Coverage: UNIT]` (`ci_runner_test.dart`)
- [ ] A driver log-stream error reaches a terminal event instead of hanging to timeout — `[Coverage: UNIT]` (`driver_stream_error_test.dart`)
- [ ] Editing tests in the config editor reuses the scheduler (an in-flight run stays cancellable); scheduler retention is bounded — `[Coverage: UNIT]` (`job_scheduler_cache_test.dart`)

Trend-store query cost, retention correctness, dump growth (Guide §10.9):
- [ ] `recentDeltas` costs exactly **one** SQL statement regardless of test count (was one per test in the newest run) — `[Coverage: UNIT]` (`trend_query_count_test.dart`)
- [ ] `distinctTestIds` costs one statement; `recentTrendsFor` chunks 1 000 ids into ≤3 — `[Coverage: UNIT]` (`trend_query_count_test.dart`)
- [ ] `recentTrendsFor` returns points identical to per-test `recentTrend` (bulk/single equivalence) — `[Coverage: UNIT]` (`trend_query_count_test.dart`)
- [ ] The recent-runs window is served by `idx_runs_started` (migration v3) with no `TEMP B-TREE` — `[Coverage: UNIT]` (`trend_query_count_test.dart`)

**Cancel-path instance correctness + dispose safety (Guide §10.10, §10.11):**

- [ ] Stop cancels a run whose scheduler the LRU has evicted (open five projects with distinct simulator paths, then Stop) — `[Coverage: UNIT]` (`regression_runner_test.dart`)
- [ ] Closing a tab mid-run raises no Riverpod lifecycle assertion and still lands the run's buffered trend points — `[Coverage: UNIT]` (`regression_runner_test.dart`)
- [ ] The trend query-count guards run as part of `flutter test` (file is `trend_query_count_test.dart`, not `_bench.dart`) — `[Coverage: UNIT]`
- [ ] `recentDeltas(limit:)` bounds the comparison window (a prior result older than the window reads as no-previous-status) — `[Coverage: UNIT]` (`sql_trend_store_test.dart`)
- [ ] Trend DB row count and on-disk size stay bounded across 30 synthetic runs — `[Coverage: HYBRID]` (`retention_bounds_disk_test.dart`)
- [ ] The `runs` table is pruned; no run row survives without a surviving result — `[Coverage: HYBRID]` (`retention_bounds_disk_test.dart`)
- [ ] An in-flight run (row written, results not yet flushed) is **not** pruned — `[Coverage: HYBRID]` (`retention_bounds_disk_test.dart`)
- [ ] `VACUUM` runs only when reclaimable space crosses the threshold, not on every retention pass — `[Coverage: HYBRID]` (`retention_bounds_disk_test.dart`)
- [ ] **Waveform dumps are capped across runs, not per run** — 5 runs × 4 dirs with `keepLastNFailures: 5` leaves 5 dirs total — `[Coverage: UNIT]` (`cross_run_dump_retention_test.dart`)
- [ ] A `.simcrux-keep` marker pins a test dir (or, at run level, a whole run) against pruning — `[Coverage: UNIT]` (`cross_run_dump_retention_test.dart`)
- [ ] Run directories emptied by pruning are swept, not left as empty shells — `[Coverage: UNIT]` (`cross_run_dump_retention_test.dart`)
- [ ] Regex guard isolates are pooled and reused; a deadline-killed worker is never returned to the pool and the pool recovers — `[Coverage: UNIT]` (`regex_isolate_pool_test.dart`)
- [ ] A long nightly regression's `<runRoot>/runs/` directory stays under the byte ceiling after many runs — `[Coverage: MANUAL]`

## About Box (suite-wide `crux_about_dialog`)

See VERIFICATION_GUIDE.md §11 for step-by-step instructions. Replaces the former Material `showAboutDialog` stub. Test: `test/features/about/simcrux_about_dialog_test.dart`.

- [ ] About SimCrux opens (dialog on desktop, route on mobile) with title "About SimCrux" — `[Coverage: AUTOMATED — simcrux_about_dialog_test.dart]`
- [ ] Version section shows version / build / commit / OS / arch / Flutter / Dart — `[Coverage: AUTOMATED]` (version + SHA asserted from stub)
- [ ] Branding banner shows "Ferrite Engineering" + copyright line — `[Coverage: AUTOMATED]`
- [ ] **Visit Website** opens `ferriteengineering.com` — `[Coverage: MANUAL — OS url_launcher]`
- [ ] **Copy Version Info** copies the structured paragraph + shows the confirmation snackbar — `[Coverage: MANUAL — OS clipboard]` (button-enabled asserted automated)
- [ ] Edition chip hidden for Open Core; EDU `EditionBadge` shown for an Educational license — `[Coverage: AUTOMATED]`
- [ ] Public Beta chip shown while `kBetaPeriod` is true — `[Coverage: MANUAL — build-flag dependent]`
- [ ] No exception in en / zh_CN / ja / ko locale sweeps — `[Coverage: AUTOMATED]`

## Update Mechanism (`crux_updates`)

See VERIFICATION_GUIDE.md §12. Open-core, every tier — no badge, no gate. Tests: `test/core/update/`, `test/features/update/`.

- [ ] Launch with a manifest advertising a newer version shows the "SimCrux `<version>` is available." strip — `[Coverage: AUTOMATED — update_status_machine_test.dart + update_banner_test.dart]`
- [ ] **View Changes** opens the manifest's `changelog_url`; absent `changelog_url` hides the button — `[Coverage: MANUAL — OS url_launcher]`
- [ ] **Update Now** opens `https://simcrux.app/download` — `[Coverage: AUTOMATED]` (target asserted; real launch MANUAL)
- [ ] Dismissal hides the strip for the session; a *newer* version re-surfaces it — `[Coverage: AUTOMATED — update_banner_test.dart]`
- [ ] A `mandatory` update, or a build below `min_supported_version`, renders **no** dismiss affordance — `[Coverage: AUTOMATED]`
- [ ] Help → **Check for Updates…** reports "up to date" / "couldn't check"; an available update reports through the banner only — `[Coverage: AUTOMATED]` (snackbar wording MANUAL)
- [ ] The About box carries a **Check for Updates…** button — `[Coverage: MANUAL]`
- [ ] Settings → General shows **Automatically check for updates**, on by default, with the data-sent explanation — `[Coverage: AUTOMATED — settings_general_section_test.dart]`
- [ ] Release build: Settings → General shows **Enable diagnostics**, off by default; turning it on enables Tools → Tab Diagnostics… (debug/profile builds hide the switch and always enable the action) — `[Coverage: AUTOMATED — settings_general_section_test.dart (switch persists); MANUAL — release build]`
- [ ] Turning the setting off suppresses the launch / periodic / on-resume checks (zero manifest requests) — `[Coverage: AUTOMATED — update_status_machine_test.dart]`
- [ ] A manual check still runs with the setting off — `[Coverage: AUTOMATED]`
- [ ] The setting survives a restart — `[Coverage: AUTOMATED — simcrux_settings_codec_test.dart]`
- [ ] A failed / malformed manifest never nags and never breaks a flow — `[Coverage: AUTOMATED]`
- [ ] The request is a single bodyless `GET` with only a `SimCrux/<version> (<os>)` User-Agent — `[Coverage: AUTOMATED]` (real proxy capture MANUAL)
- [ ] The web dashboard build never renders the banner, but still fetches the manifest for `server_time` — `[Coverage: MANUAL — web build]`
- [ ] Banner actions clear 44 dp; locale sweep en / zh_CN / ja / ko without overflow — `[Coverage: AUTOMATED — update_banner_test.dart]`
- [ ] `checkForUpdates` shows **no** PRO badge in the palette and no `" (PRO)"` suffix in the menu bar — `[Coverage: AUTOMATED — beta_infrastructure_actions_test.dart]`

## Beta Issue Reporter (`crux_issue_reporter`)

See VERIFICATION_GUIDE.md §13. Open to every tier — no badge, no gate. Files to `Ferrite-Engineering/simcrux`, independent of `kBetaPeriod`. Tests: `test/core/issue_reporter/`, `test/features/issue_reporter/`.

**PRIVACY — do this pass on every release, against a real project with real paths and a completed run:**

- [ ] **The Session State preview contains no `/` and no `\` — anywhere** — `[Coverage: AUTOMATED — issue_reporter_session_context_test.dart, "PRIVACY: a Session State body carries no file paths"]`
- [ ] No project path, source path, dump path, log path, or binary-override path — `[Coverage: AUTOMATED]`
- [ ] **No suite name, test name, or top-module name** — only counts — `[Coverage: AUTOMATED]`
- [ ] `Simulator binary overrides` is a bare count, never a path — `[Coverage: AUTOMATED]`
- [ ] A `--version` banner carrying an install prefix reads `(redacted)` — `[Coverage: AUTOMATED]`
- [ ] The Diagnostics section quotes no user path (a leak here is a defect in the logging call site) — `[Coverage: MANUAL]`

Flow:

- [ ] Help → **Submit Issue…**, the command palette, and the About box all open the reporter — `[Coverage: MANUAL]` (action wiring AUTOMATED)
- [ ] App & Environment is locked on; the other three toggle, and the preview updates live — `[Coverage: MANUAL]`
- [ ] Submit opens the pre-filled `Ferrite-Engineering/simcrux` new-issue page with the `bug_report.yml` template — `[Coverage: AUTOMATED]` (slug/template asserted; real launch MANUAL)
- [ ] The body is on the clipboard either way; an over-long body is dropped from the URL and the toast says so — `[Coverage: MANUAL]`
- [ ] Desktop: the screenshot PNG is written to temp and revealed in the file manager — `[Coverage: MANUAL — OS file manager]`
- [ ] A blank summary falls back to a SimCrux-named issue title — `[Coverage: MANUAL]`
- [ ] A startup warning logged before the first provider is constructed is already in the Diagnostics section — `[Coverage: MANUAL — real launch]`
- [ ] Session State still renders sensibly with no project open (`(none loaded)`, zero counts) — `[Coverage: AUTOMATED]`
- [ ] Locale sweep en / zh_CN / ja / ko: chrome localized, **markdown body deliberately English** — `[Coverage: AUTOMATED — simcrux_issue_reporter_strings_test.dart]`
- [ ] `submitIssue` shows **no** PRO badge in the palette and no `" (PRO)"` suffix in the menu bar — `[Coverage: AUTOMATED — beta_infrastructure_actions_test.dart]`
- [ ] Building with `--dart-define=BETA_PERIOD=false` does not change the target: the opened URL still targets `Ferrite-Engineering/simcrux` — `[Coverage: AUTOMATED — issue_reporter_overrides_test.dart]` (real flip MANUAL)

## Beta Expiry Gate (`crux_license` + `crux_updates`)

See VERIFICATION_GUIDE.md §14. Not a tier feature — gated by `kBetaPeriod`, not by licence. Tests: `test/features/beta_expiry/`.

- [ ] A plain build with no `--dart-define=BETA_EXPIRY` shows nothing at all — `[Coverage: AUTOMATED — beta_expiry_clock_tampering_test.dart]`
- [ ] An invalid `BETA_EXPIRY` (month 13, Feb 30, negative) is treated as absent, **not** as expired — `[Coverage: AUTOMATED]`
- [ ] Inside the warning window: a dismissible strip with the day count and a **Download** action — `[Coverage: AUTOMATED — beta_expiry_gate_test.dart]`
- [ ] The 1-day case uses the ICU `=1` singular — `[Coverage: AUTOMATED]`
- [ ] Dismissing the strip lasts the session; a resume clears the dismissal — `[Coverage: AUTOMATED]` (resume edge MANUAL)
- [ ] On/after the expiry date: a blocking, non-dismissable modal; nothing behind the barrier responds; back/Escape does not close it — `[Coverage: AUTOMATED]`
- [ ] **Quit SimCrux** shuts down through the `AppExitCoordinator` — no orphaned `vvp` / `verilator` / `make` process tree survives — `[Coverage: AUTOMATED]` (real process-tree reap MANUAL)
- [ ] Both Download actions open `https://simcrux.app/download` — `[Coverage: AUTOMATED]`
- [ ] **A device-clock rollback does not defer expiry below the last observed `server_time`** — `[Coverage: AUTOMATED — beta_expiry_clock_tampering_test.dart]` (real OS clock change MANUAL)
- [ ] A never-online install still works (no watermark ⇒ device clock governs) — `[Coverage: AUTOMATED]`
- [ ] The watermark is monotonic and survives relaunch — `[Coverage: AUTOMATED — observed_server_time_provider_test.dart]`
- [ ] The status is evaluated at startup and on resume only — a long regression is never interrupted mid-session — `[Coverage: MANUAL]`
- [ ] All affordances clear 44 dp; locale sweep en / zh_CN / ja / ko without overflow — `[Coverage: AUTOMATED]`
- [ ] **RELEASE-BLOCKING:** a `kBetaPeriod = false` build with a stale `--dart-define=BETA_EXPIRY=<past>` launches with **no** modal — `[Coverage: MANUAL — build-flag dependent]`

## Command palette keyboard operation (`crux_command_palette`)

See VERIFICATION_GUIDE.md §8.7.1. Shared-widget fix — re-verify in every Crux app. Tests: `crux-shared/packages/crux_command_palette/test/command_palette_test.dart`.

- [ ] **Enter runs the highlighted entry** in a release build (the shipped defect: highlighted row, Enter did nothing) — `[Coverage: AUTOMATED — done-action + key-event paths]` (real hardware keypress MANUAL)
- [ ] Numpad Enter behaves identically — `[Coverage: AUTOMATED]`
- [ ] ↑/↓ move the highlight and the query caret does **not** jump — `[Coverage: AUTOMATED]`
- [ ] Esc closes without dispatching, and closes exactly one route — `[Coverage: AUTOMATED]`
- [ ] Enter on "No matching commands." neither dispatches nor closes — `[Coverage: AUTOMATED]`
- [ ] A Pro-badged entry run via Enter behaves exactly as when clicked (badge + upgrade path) — `[Coverage: MANUAL]`
- [ ] With a Japanese/Korean IME mid-composition, Enter commits the composition; a second Enter runs the entry — `[Coverage: MANUAL]`

## Launch restore: tab dedupe + `restoreTabsOnLaunch` (`crux_workspace`)

See VERIFICATION_GUIDE.md §16. Shared-seam fix — LintCrux had the identical symptom. Tests: `test/features/workspace/providers/workspace_restore_and_dedupe_test.dart`, `test/features/dashboard/widgets/cli_regression_bootstrapper_test.dart`, `crux-shared/packages/crux_workspace/test/workspace_tab_identity_test.dart`, `crux-shared/packages/crux_io/test/path_identity_test.dart`.

- [ ] **Relaunching with the same positional config leaves one tab, not two** — `[Coverage: AUTOMATED]`
- [ ] **Seven relaunches still leave one tab** (the shipped defect was linear, unbounded growth) — `[Coverage: AUTOMATED]` (real relaunch MANUAL)
- [ ] A relative, dot-segment, symlinked, or differently cased argument all focus the existing tab — `[Coverage: AUTOMATED]`
- [ ] Two different configs still open two tabs; two blank `(new tab)`s stay separate — `[Coverage: AUTOMATED]`
- [ ] The same config named twice on one command line opens one tab — `[Coverage: AUTOMATED]`
- [ ] `flutter.settings.restoreTabsOnLaunch = false` starts with no tabs — `[Coverage: AUTOMATED]`
- [ ] Restore-off does **not** delete `workspace.json`; setting it back to `true` brings the session back — `[Coverage: AUTOMATED]`
- [ ] Restore-off plus a CLI argument yields exactly the CLI tab — `[Coverage: AUTOMATED]`
- [ ] Restore-on plus a CLI argument yields the restored tabs plus exactly one deduped CLI tab — `[Coverage: AUTOMATED]`
- [ ] An unreadable settings store restores rather than discarding the session — `[Coverage: AUTOMATED]`
- [ ] **A full session reset deletes all three locations** — `<appSupport>/workspace.json`, `<appSupport>/simcrux/workspace.json` (Pro registry), `<appSupport>/sessions/` — `[Coverage: MANUAL]`
- [ ] With the Pro overlay, the project registry does not re-seed a duplicate tab after restore — `[Coverage: MANUAL]`

## Opening a config arms the tab (`autoRunOnOpen`)

See VERIFICATION_GUIDE.md §17. Opening a config does not start the regression; auto-start is a setting, default **off**. Tests: `test/features/dashboard/providers/auto_run_on_open_test.dart`, `test/services/settings/simcrux_settings_codec_test.dart`, `test/features/settings/widgets/settings_general_section_test.dart`.

- [ ] **Default profile: opening a config loads it and runs nothing** — `[Coverage: AUTOMATED]` (real simulator processes MANUAL)
- [ ] Run Regression starts normally from the armed state — `[Coverage: MANUAL]`
- [ ] Settings → General → "Run the regression when a config is opened" is present and **off** by default — `[Coverage: AUTOMATED]`
- [ ] Turning it on restores auto-start; turning it off restores arming — `[Coverage: AUTOMATED]` (round trip MANUAL)
- [ ] The setting persists as `simcrux.autoRunOnOpen`, absent ⇒ off — `[Coverage: AUTOMATED]`
- [ ] File → Open and a blank tab's picker arm without running — `[Coverage: MANUAL]`
- [ ] A config that will not parse still reports its load error when only armed — `[Coverage: AUTOMATED]`
- [ ] **Auto-reload is unchanged**: "Sources changed — Re-run now?" and `AutoReloadMode.auto` behave exactly as before — `[Coverage: MANUAL]`
- [ ] An unreadable settings store resolves to **off** — never start a run nobody asked for — `[Coverage: AUTOMATED]`
- [ ] Toggle clears 44 dp; locale sweep en / zh_CN / zh / ja / ko without overflow — `[Coverage: AUTOMATED]`

## A project file may not choose what SimCrux runs (`allowProjectDefinedTooling`)

`simulators.<id>.path`, `simulators.<id>.env`, the `riscv` `target` /
`riscof` / `compile` / `formal` `command:` lists, and the `riscv` executable
paths (`reference.path`, `toolchain.path`, `toolchain.prefix`, `riscof.binary`,
`formal.sby_binary`) all decide which program SimCrux spawns and under what
environment. `.yaml` / `.yml` are registered SimCrux document
types, so a project file arrives by double-click, clone or download, and with
`autoRunOnOpen` on it never needs a click at all. The keys are refused unless
the user opted in. Tests:
`test/services/config/config_loader_project_tooling_test.dart`,
`test/features/settings/widgets/settings_simulators_section_test.dart`,
`test/services/settings/simcrux_settings_codec_test.dart`,
`test/core/cli/cli_arg_parser_test.dart`, `test/core/cli/simcrux_cli_test.dart`,
`test/services/config/config_loader_settings_labels_test.dart`.

- [ ] **Default profile: a config with `path:` / `env:` loads, both are ignored, and an advisory names the file and line** — `[Coverage: AUTOMATED]`
- [ ] **A config with a `riscv` executable path (`formal.sby_binary`, `reference.path`, `toolchain.path` / `.prefix`, `riscof.binary`) loads, the path is ignored, and an advisory names the key, file and line**; `riscv_formal` then spawns `sby` from `PATH` — `[Coverage: AUTOMATED]`
- [ ] A config with `riscv.formal.command` **fails to load**, like `target.command` — `[Coverage: AUTOMATED]`
- [ ] Every gate diagnostic names the switch by its on-screen label, held to `app_en.arb` — `[Coverage: AUTOMATED]`
- [ ] A dropped `source: custom` falls back to `system`, so **Settings → Simulators → Binary path** now applies to that simulator — `[Coverage: AUTOMATED]` (real spawn MANUAL)
- [ ] A config with `riscv.target.command` **fails to load**, naming the setting and the CLI flag — `[Coverage: AUTOMATED]`
- [ ] Settings → Simulators → "Let project files choose simulator binaries and environment" is present and **off** by default — `[Coverage: AUTOMATED]`
- [ ] Turning it on makes the same three configs load and honour their keys — `[Coverage: AUTOMATED]` (real spawn MANUAL)
- [ ] The setting persists as `simcrux.allowProjectDefinedTooling`, absent ⇒ off — `[Coverage: AUTOMATED]`
- [ ] `simcrux --ci` without `--allow-project-tooling` refuses the same way; with it, honours them — `[Coverage: AUTOMATED]`
- [ ] `simcrux import-riscv-arch-test --target-command …` prints how to let the file it wrote run — `[Coverage: MANUAL]`
- [ ] Toggle clears 44 dp; locale sweep en / zh_CN / zh / ja / ko without overflow — `[Coverage: AUTOMATED]`

## RISC-V architectural compatibility — `golden_compare` detector

See VERIFICATION_GUIDE.md §18. The seventh `pass_fail:` type: compare a DUT
output file against a committed golden and report the first divergent word
with its offset. **Architecture neutral** — RISC-V signatures are a
`profile:`, not the type. Fixtures: `verification/fixtures/golden_compare/`
(8 cases; regenerate with `dart run tool/generate_golden_compare_fixtures.dart`).
Tests: `test/domain/models/golden_comparator_test.dart`,
`test/domain/enums/golden_compare_profile_test.dart`,
`test/services/pass_fail_detector/golden_compare_detector_test.dart`,
`test/services/pass_fail_detector/golden_compare_fixtures_test.dart`,
`test/services/pass_fail_detector/pass_fail_detector_registry_test.dart`,
`test/services/job_scheduler/golden_compare_working_dir_test.dart`,
`test/services/config/config_loader_golden_compare_test.dart`,
`test/services/result_store/golden_metrics_roundtrip_test.dart`,
`test/domain/models/pass_fail_config_codec_test.dart`,
`test/features/settings/widgets/detector_spec_editor_test.dart`.

- [ ] Identical dumps report **pass** — `[Coverage: AUTOMATED]`
- [ ] **A first-word divergence reports fail at offset 0** (the off-by-one boundary) — `[Coverage: AUTOMATED]`
- [ ] A mid-file divergence reports the **first** divergence, not the last — `[Coverage: AUTOMATED]`
- [ ] A length divergence reports the offset where the shorter dump ran out; only the longer side carries a word — `[Coverage: AUTOMATED]`
- [ ] **An empty dump on either side reports `fail` — never `vacuous`** — `[Coverage: AUTOMATED]`
- [ ] **A missing dump on either side reports `fail` — never `unknown`** (an exit-0 run with no output must not become a pass) — `[Coverage: AUTOMATED]`
- [ ] Both dumps empty reports `fail`, not a vacuous pass — `[Coverage: AUTOMATED]`
- [ ] A directory where a dump was expected fails rather than throwing — `[Coverage: AUTOMATED]`
- [ ] Whitespace variance (CRLF, blank lines, trailing space) never changes the verdict under either profile — `[Coverage: AUTOMATED]`
- [ ] `profile: riscv_signature` folds case and `0x`; `profile: generic` does not — the fixture pair shares its bytes and reports opposite verdicts — `[Coverage: AUTOMATED]`
- [ ] Leading zeros are **not** stripped under either profile — `[Coverage: AUTOMATED]`
- [ ] The scheduler's real call site classifies against the run's own working directory, per test — `[Coverage: AUTOMATED]` (real simulator processes MANUAL)
- [ ] Synchronous `classify()` **throws** for `golden_compare`, including as a composite leaf — it never degrades to `unknown` — `[Coverage: AUTOMATED]`
- [ ] A `golden_compare` leaf nested in a `composite` is evaluated on the async path — `[Coverage: AUTOMATED]`
- [ ] `dut: `/`reference:` pointing at the same file is refused at load time — `[Coverage: AUTOMATED]`
- [ ] The generic profile requires both paths and reports **both** missing-path errors in one load — `[Coverage: AUTOMATED]`
- [ ] An unknown `profile:` is rejected and the error names the valid values — `[Coverage: AUTOMATED]`
- [ ] The unknown-`type:` error enumerates `golden_compare` among the valid types — `[Coverage: AUTOMATED]`
- [ ] `golden.*` metrics survive encode → decode → hydrate; the absent side stays absent rather than becoming an empty string — `[Coverage: AUTOMATED]`
- [ ] Settings → Detectors: the "Golden compare" chip seeds a valid RISC-V-profile node; profile dropdown and both path fields edit and persist — `[Coverage: AUTOMATED]` (real Settings round trip MANUAL)
- [ ] Locale sweep en / zh_CN / zh / ja / ko of the new editor fields without overflow — `[Coverage: AUTOMATED]`
- [ ] **No tier gate anywhere**: the verdict is produced at `LicenseTier.openCore` with `kBetaPeriod = false`, with no badge, cap or nag — `[Coverage: AUTOMATED]` (post-flip build MANUAL)
- [ ] A real `riscv-arch-test` run against a real reference model — `[Coverage: MANUAL]` (the `riscv_arch` driver; needs Sail/Spike + the RISC-V cross-compiler)

## RISC-V architectural compatibility — the `riscv_arch` driver

See VERIFICATION_GUIDE.md §18.2. The driver that runs the compatibility flow
(id `riscv_arch`), the `riscv:` YAML block and its **four** inheritance levels,
the per-component `RiscvToolchainProbe` with actionable per-platform guidance,
Python-traceback reduction, and **demo mode** — which is simultaneously the
offline demo path and the CI test path, and consumes the `golden_compare` corpus at
`verification/fixtures/golden_compare/` rather than a second fixture set.
Tests: `test/domain/models/riscv_config_test.dart`,
`test/services/config/config_loader_riscv_test.dart`,
`test/services/import/riscv_arch_test_importer_test.dart`,
`test/services/simulator/riscv_arch_driver_demo_test.dart`,
`test/services/simulator/riscv_arch_driver_normal_test.dart`,
`test/services/simulator/riscv_toolchain_probe_test.dart`,
`test/services/simulator/python_traceback_reducer_test.dart`,
`test/features/diagnostics/riscv_toolchain_report_view_test.dart`.

- [ ] The importer emits **one test per architectural test**, tagged with its extension — there is no fan-out anywhere downstream — `[Coverage: AUTOMATED]`
- [ ] Every emitted test carries a synthesized `top:` — without it the loader refuses the generated config — `[Coverage: AUTOMATED]`
- [ ] `riscv.test` is relative to `arch_test.suite_path`, which is pinned to the scanned root, so the compile does not depend on the process cwd — `[Coverage: AUTOMATED]`
- [ ] The importer emits the `golden_compare` / `riscv_signature` detector alongside the `riscv:` block, and the two agree on the signature filenames — `[Coverage: AUTOMATED]`
- [ ] The generated YAML loads through the real `ConfigLoader` — `[Coverage: AUTOMATED]`
- [ ] The generated YAML is readable, diffable and hand-editable, with a provenance header and every import warning — `[Coverage: MANUAL]`
- [ ] **`riscv:` inherits across all FOUR levels** — include file → project `defaults:` → suite → test — each level asserted independently — `[Coverage: AUTOMATED]`
- [ ] Nested `riscv:` blocks merge field-by-field: a suite that switches only `reference.model` keeps the project's `reference.path` — `[Coverage: AUTOMATED]`
- [ ] A swept / expanded child keeps its `riscv:` block — `[Coverage: AUTOMATED]`
- [ ] Completeness is validated on the **flattened** config, so plumbing in `defaults:` plus `test:` per test is accepted — `[Coverage: AUTOMATED]`
- [ ] Validation errors accumulate with `file:line:col` spans; an unknown `mode:` / `model:` names the valid values — `[Coverage: AUTOMATED]`
- [ ] `signature.dut` and `signature.reference` pointing at one file is refused at load time — `[Coverage: AUTOMATED]`
- [ ] A `riscv:` block on a non-`riscv_arch` test is inert, not an error — `[Coverage: AUTOMATED]`
- [ ] `riscv_arch` is absent from the simulator-language catalog on purpose; its tests are skipped by the mixed-language validator rather than flagged — `[Coverage: AUTOMATED]`
- [ ] **Demo mode runs the whole flow with no RISC-V toolchain and no network** — `[Coverage: AUTOMATED]` (on a clean machine MANUAL)
- [ ] Demo mode spawns **no subprocess at all** — `[Coverage: AUTOMATED]` (launcher throws if called)
- [ ] Demo mode fires **no toolchain probe** — skipped, not probed-and-tolerated — `[Coverage: AUTOMATED]`
- [ ] Demo mode is declared in config, never in the environment — one driver id, one code path, spawn steps skipped — `[Coverage: AUTOMATED]`
- [ ] Every committed corpus case replays to its `golden_compare` verdict, except `format_variance_generic`, which passes here because the driver is always on the `riscv_signature` profile — `[Coverage: AUTOMATED]`
- [ ] **A missing or empty signature reports `fail` — never `unknown`, never `vacuous`** — every demo case exits 0, so this is the trap that would turn a broken core green — `[Coverage: AUTOMATED]`
- [ ] A non-zero DUT exit fails even when the signatures agree — `[Coverage: AUTOMATED]`
- [ ] A programmatically-built spec with no usable `riscv:` block fails loudly with the loader's own message — `[Coverage: AUTOMATED]`
- [ ] The compile stage cross-compiles and then runs the reference model, in that order, and stops if the ELF was not produced — `[Coverage: AUTOMATED]`
- [ ] Spike gets `--isa` / `+signature=` / `+signature-granularity`; Sail gets `--test-signature` with the ELF last — `[Coverage: AUTOMATED]`
- [ ] `{elf}` / `{signature}` expand in `target.command`; an **unknown** placeholder is left verbatim, not blanked — `[Coverage: AUTOMATED]`
- [ ] `mode: riscof_passthrough` spawns the configured command, and its once-per-test limitation is stated at the config key — `[Coverage: AUTOMATED]`
- [ ] **A Python traceback is reduced to its final `SomeError: message` line** for the dashboard row, and the full trace is still in the stderr log — `[Coverage: AUTOMATED]`
- [ ] A missing binary raises `SimulatorNotAvailableException` and writes the component's actionable remediation into the compile stderr — `[Coverage: AUTOMATED]`
- [ ] The toolchain probe reports **per component** (cross-compiler / reference model / Python+RISCOF / Yosys+SymbiYosys); `detectVersion` returns its summary line and never throws — `[Coverage: AUTOMATED]`
- [ ] Every component × platform cell carries actionable guidance — what to install, from where — not a bare "not found" — `[Coverage: AUTOMATED]`
- [ ] **Windows says WSL2 where that is the honest answer** (Sail has no practical native build) rather than emitting a knowingly broken invocation — `[Coverage: AUTOMATED]` (on a real Windows host MANUAL)
- [ ] macOS guidance covers the Finder-PATH gotcha; Linux guidance names concrete packages — `[Coverage: AUTOMATED]`
- [ ] No guidance anywhere suggests SimCrux bundles or installs a toolchain — `[Coverage: AUTOMATED]`
- [ ] The App Diagnostics toolchain panel renders in all five locales × three platforms without overflow, down to a narrow width — `[Coverage: AUTOMATED]`
- [ ] The probe is lazy: opening the app spawns nothing; opening App Diagnostics is what pays for it — `[Coverage: MANUAL]`
- [ ] `golden.*` and `riscv.*` metrics reach `TestResult`, including `riscv.extension` and `riscv.signature.byte_offset` — `[Coverage: AUTOMATED]`
- [ ] `riscv.signature.byte_offset` scales with `signature.word_size` — `[Coverage: AUTOMATED]`
- [ ] `riscv.reference_model` is **absent** in demo mode — no model ran, so none is attributed — `[Coverage: AUTOMATED]`
- [ ] **No tier gate anywhere on the `riscv:` path** — reader, driver, probe, panel — at `LicenseTier.openCore` with `kBetaPeriod = false` — `[Coverage: AUTOMATED]` (post-flip build MANUAL)
- [ ] A real `riscv-arch-test` suite against a real reference model — `[Coverage: MANUAL]` (needs Sail/Spike + the RISC-V cross-compiler)
- [ ] A real RISCOF passthrough against an existing user flow — `[Coverage: MANUAL]`

## RISC-V formal proofs — the `riscv_formal` driver

See VERIFICATION_GUIDE.md §18.3. The driver that runs the riscv-formal
check set through SymbiYosys (id `riscv_formal`) — *N* independent bounded
proofs enumerated up front into one `TestSpec` each, the `riscv.formal:`
sub-block, per-property verdict / proof depth / wall time / counterexample
VCD, and **demo mode** over a hand-authored corpus of captured SymbiYosys
output at `verification/fixtures/riscv_formal/`.
Tests: `test/domain/models/sby_outcome_test.dart`,
`test/domain/models/sby_script_test.dart`,
`test/domain/models/riscv_formal_config_test.dart`,
`test/services/config/config_loader_riscv_formal_test.dart`,
`test/services/import/riscv_formal_check_importer_test.dart`,
`test/services/simulator/riscv_formal_driver_demo_test.dart`,
`test/services/simulator/riscv_formal_driver_normal_test.dart`,
`test/services/simulator/riscv_formal_fixtures_test.dart`.

- [ ] The importer emits **one test per bounded proof** — there is no fan-out anywhere downstream — `[Coverage: AUTOMATED]`
- [ ] A `.sby` with a `[tasks]` section becomes one test **per task**, with an import warning saying so — `[Coverage: AUTOMATED]`
- [ ] Every emitted test carries a synthesized `top:` — without it the loader refuses the generated config — `[Coverage: AUTOMATED]`
- [ ] The generated YAML loads through the real `ConfigLoader`, and is readable, diffable and hand-editable with a provenance header — `[Coverage: AUTOMATED]` (readability MANUAL)
- [ ] The emitted `pass_string` is the parser's own constant, so the detector and the driver cannot drift — `[Coverage: AUTOMATED]`
- [ ] **The verdict comes from SymbiYosys's `DONE (…)` line, never from the exit code** — `[Coverage: AUTOMATED]`
- [ ] **A log with no `DONE (…)` line reports `fail` even though the process exits 0** — the sharpest trap in this driver — `[Coverage: AUTOMATED]`
- [ ] **`UNKNOWN` reports `fail`** — an unproven property is not a passing property — `[Coverage: AUTOMATED]`
- [ ] **`TIMEOUT` reports `fail`, and NOT `TestStatus.timeout`** — that status means SimCrux killed the job — `[Coverage: AUTOMATED]`
- [ ] `ERROR` reports `fail` and surfaces SymbiYosys's own `ERROR:` line — `[Coverage: AUTOMATED]`
- [ ] **Nothing on this path is ever `unknown` or `vacuous`** — `unknown` hands the verdict back to the exit code, `vacuous` deletes the evidence — `[Coverage: AUTOMATED]`
- [ ] **A non-`PASS` verdict never reports exit code 0**, so the trap stays closed under the DEFAULT exit-code detector too; the withheld value is kept in `riscv.formal.process_exit_code` — `[Coverage: AUTOMATED]`
- [ ] `PASS` with a non-zero process exit is a `fail` — `[Coverage: AUTOMATED]`
- [ ] Worst outcome wins when a log carries several `DONE (…)` lines — `[Coverage: AUTOMATED]`
- [ ] **The counterexample VCD reaches `TestResult.waveformPath`** — absolute, existing, and on the field the CXP producer already consumes; no new result field — `[Coverage: AUTOMATED]`
- [ ] **The VCD survives on disk** because the scheduler sweeps only *successful* work dirs — `[Coverage: AUTOMATED]`
- [ ] An announced trace that is not on disk is reported as unresolved rather than recorded as a dangling path — `[Coverage: AUTOMATED]`
- [ ] Per-property metrics reach `TestResult`: verdict, proof mode, depth configured **and** depth reached, wall time with its source, engine, trace count — `[Coverage: AUTOMATED]`
- [ ] `riscv.formal.group` is what the Pro check-set coverage rollup groups on; an explicit `group:` wins over the derived one — `[Coverage: AUTOMATED]`
- [ ] `sby` is spawned in the **checks** directory, with `-d` pointed at the work directory — `[Coverage: AUTOMATED]`
- [ ] `{sby_file}` / `{task_dir}` / `{check}` expand in `formal.command`; an **unknown** placeholder is left verbatim — `[Coverage: AUTOMATED]`
- [ ] `riscv.formal:` reads and merges field-by-field at every inheritance level — `[Coverage: AUTOMATED]`
- [ ] Completeness is scoped by simulator id: a `formal:` block on a `riscv_arch` or third-party test is **inert, not an error** — `[Coverage: AUTOMATED]`
- [ ] `mode: riscof_passthrough` is refused for a bounded proof, with a message saying why — `[Coverage: AUTOMATED]`
- [ ] `riscv_formal` is absent from the simulator-language catalog on purpose; `sby` declares its own sources in the `.sby` — `[Coverage: AUTOMATED]`
- [ ] **Demo mode runs the whole flow with no Yosys, no SymbiYosys, no SMT solver and no network** — `[Coverage: AUTOMATED]` (on a clean machine MANUAL)
- [ ] Demo mode spawns **no subprocess at all** — `[Coverage: AUTOMATED]` (launcher throws if called)
- [ ] Demo mode is declared in config, never in the environment — one driver id, one code path, only the spawn skipped — `[Coverage: AUTOMATED]`
- [ ] The replayed log still streams as ordinary log lines, so the detector sees the same text it sees in production — `[Coverage: AUTOMATED]`
- [ ] The corpus is **hand-authored**, covers every verdict, and cannot silently lose a case — `[Coverage: AUTOMATED]`
- [ ] A missing `sby` yields the component's actionable per-platform remediation, not an errno; nothing offers to install or bundle a toolchain — `[Coverage: AUTOMATED]`
- [ ] A SymbiYosys Python traceback is reduced to one line for the row, full trace retained in the stderr log — `[Coverage: AUTOMATED]`
- [ ] **No new ARB strings** — the formal driver renders no widget of its own; the toolchain panel already covers SymbiYosys — `[Coverage: AUTOMATED]`
- [ ] **No tier gate anywhere on the formal path** — reader, driver, importer — at `LicenseTier.openCore` with `kBetaPeriod = false` — `[Coverage: AUTOMATED]` (post-flip build MANUAL)
- [ ] A real riscv-formal check set against a real RVFI-instrumented core — `[Coverage: MANUAL]` (needs Yosys + SymbiYosys + an SMT solver)
- [ ] A real counterexample VCD opened in WaveCrux — `[Coverage: MANUAL]` (the CXP coordinate is covered below)

## The CXP semantic stream coordinate — the producer

See VERIFICATION_GUIDE.md §18.7. `riscvStreamCoordinateFor` turns a
`TestResult` into the optional `coordinate` payload field CXP §9.9
(`https://edacrux.app/cxp#sec-9-9`) defines, so "Debug in WaveCrux" can say
*open this trace **at step 7***. Pure, and ungated. `RiscvResultKind` is the
open-core home of the compatibility and formal row discriminators, which the
Pro rollups delegate to.
Tests: `test/services/remote/cxp/riscv_stream_coordinate_test.dart`,
`test/features/remote/services/debug_in_wavecrux_dispatcher_test.dart`.

**Most of this group asserts silence, and that is the point.** CXP §9.9
rule 3 forbids emitting an index the producer cannot state in the named
stream's own index space, so no coordinate is the correct answer for nearly
every row.

- [ ] A **failing** bounded proof emits `riscv.formal.trace_step`, `sequence_index` = `depth_reached`, `sub_id` = the RVFI channel — `[Coverage: AUTOMATED]`
- [ ] It is **not** `riscv.rvfi.retire`: SimCrux does not know `rvfi_order`, and deriving one from a cycle count would be a fabricated index — `[Coverage: AUTOMATED]`
- [ ] **An architectural-compatibility row emits nothing, ever** — a signature byte offset is not a retire index, and `riscv_arch` produces no trace to address — `[Coverage: AUTOMATED]`
- [ ] A **proved** property emits nothing — there is no counterexample to point at — `[Coverage: AUTOMATED]`
- [ ] `UNKNOWN` / `TIMEOUT` / `ERROR` / `NO_OUTCOME` emit nothing — a coordinate would assert a counterexample exists — `[Coverage: AUTOMATED]`
- [ ] An unrecognized verdict token emits nothing, so a row written by a newer build is never read as a counterexample — `[Coverage: AUTOMATED]`
- [ ] An **announced-but-unresolved** trace emits nothing — the formal driver leaves `waveformPath` null precisely so this is distinguishable — `[Coverage: AUTOMATED]`
- [ ] A missing or non-numeric `depth_reached` emits nothing — **step 0 is a real, wrong answer, not a default** — `[Coverage: AUTOMATED]`
- [ ] Identity is the triple alone: dropping every attribute does not change where the receiver lands — `[Coverage: AUTOMATED]`
- [ ] **A demo row does emit**, and labels itself `riscv.mode = demo` so replayed evidence is never presented as measured — `[Coverage: AUTOMATED]`
- [ ] The coordinate is derived **after** the waveform-exists check, so it never accompanies a path the receiver cannot open — `[Coverage: AUTOMATED]`
- [ ] It rides the **`RequestHighlight`**, not only the courtesy `NotifySelection` — a receiver that dropped the notify would otherwise land at time zero believing it had obeyed — `[Coverage: AUTOMATED]`
- [ ] A caller passing no `result` still dispatches — the coordinate is additive to every existing call site — `[Coverage: AUTOMATED]`
- [ ] The two discriminators **partition** a mixed run: nothing claimed twice, nothing dropped — `[Coverage: AUTOMATED]`
- [ ] **No tier gate anywhere on this path** — the producer takes no tier input at all — `[Coverage: AUTOMATED]` (post-flip build MANUAL)
- [ ] A real counterexample handed to a running WaveCrux lands the cursor at the failing step — `[Coverage: MANUAL]` (needs the WaveCrux consumer)

## The two shipped demo projects — `examples/riscv-*-demo/`

See VERIFICATION_GUIDE.md §18.8. The openable half of demo mode: two
committed `simcrux.yaml` projects a person can pick from **File → Open
Config…** and run to completion with **no RISC-V toolchain installed**,
against the committed `golden_compare` and `riscv_formal` corpora. Discoverable at
`examples/`, with `examples/README.md` next to them.
Tests: `test/examples/riscv_demo_examples_test.dart`,
`test/services/config/config_loader_riscv_test.dart`
(demo-corpus path resolution).

- [ ] Both configs load through the **real `ConfigLoader`** with zero errors — `existsSync()` is not loadability, and asserting it is the bug this group exists to prevent — `[Coverage: AUTOMATED]`
- [ ] …and with **zero warnings** — an Open Core user post-beta sees a clean load, not an advisory — `[Coverage: AUTOMATED]`
- [ ] Every path inside each config resolves from its **committed** location; the corpus roots are relative to the config, never to the process cwd — `[Coverage: AUTOMATED]`
- [ ] `riscv.demo_signatures` and `riscv.formal.demo_outputs` are rooted at the project file's directory, the same treatment `sources:` gets — `[Coverage: AUTOMATED]`
- [ ] Install locations (`reference.path`, `toolchain.path`, `formal.sby_binary`) and every placeholder-bearing field are **left verbatim** — engine detection is untouched and `{elf}` is never corrupted into a path — `[Coverage: AUTOMATED]`
- [ ] Both run to completion through the **real `LocalJobScheduler`** with a launcher that **throws on any spawn** — `[Coverage: AUTOMATED]` (on a clean machine MANUAL)
- [ ] Compatibility: 8 tests, **3 pass / 5 fail**, across four extension suites — asserted by name in **both** directions, because an all-green report demonstrates nothing — `[Coverage: AUTOMATED]`
- [ ] Formal: 7 tests, **2 pass / 5 fail**, one per verdict — `PASS` / `FAIL` / `UNKNOWN` / `TIMEOUT` / `ERROR` / `NO_OUTCOME` all present — `[Coverage: AUTOMATED]`
- [ ] No row in either example reports `unknown`, `vacuous`, `skipped` or `cancelled` — any of those reads as a broken demo — `[Coverage: AUTOMATED]`
- [ ] `reg_timeout` reports **fail**, never `TestStatus.timeout` — `[Coverage: AUTOMATED]`
- [ ] The counterexample VCD still exists on disk when the run ends — `[Coverage: AUTOMATED]`
- [ ] **Both Pro dashboards populate from these exact runs** — four extension rows (`Zicsr` attested, `I`/`M`/`C` not), six property-group rows with no `(ungrouped)` bucket, provenance demo on every row and **no** reference model named — `[Coverage: AUTOMATED — Pro overlay `riscv_demo_examples_pro_test.dart`]`
- [ ] `examples/README.md` says what each demonstrates and that neither needs a toolchain — `[Coverage: MANUAL]`
- [ ] The **File → Open Config…** dialog really opens them on a machine with no RISC-V toolchain — `[Coverage: MANUAL]` (the whole point; do it on a clean machine)

## The two RISC-V importers' entry points

See VERIFICATION_GUIDE.md §18.9. `RiscvArchTestImporter` and
`RiscvFormalCheckImporter` were fully implemented and fully tested but had
**no caller anywhere in the application** — no menu item, no sub-command.
This group covers the doors, not the importers: **File → Import RISC-V
Architectural Tests…**, **File → Import riscv-formal Checks…**, and
`simcrux import-riscv-arch-test` / `simcrux import-riscv-formal`.
Fixtures: `test/fixtures/riscv_arch_test/`,
`test/fixtures/riscv_formal_checks/`.
Tests: `test/integration/riscv_import_fixture_test.dart`,
`test/services/import/riscv_import_cli_test.dart`,
`test/core/cli/cli_arg_parser_test.dart`,
`test/domain/enums/riscv_import_kind_test.dart`.

- [ ] Both menu items appear in the File menu's **first group**, under Open Config… and Import FuseSoC .core File… — `[Coverage: AUTOMATED]`
- [ ] Both are **open-core** (no tier badge), File-category, menu + palette, **no** default chord and **not** on the toolbar — `[Coverage: AUTOMATED]`
- [ ] The emitted YAML loads through the **real `ConfigLoader`** with zero errors — `existsSync()` is not loadability, and nothing had ever parsed either importer's output before this — `[Coverage: AUTOMATED]`
- [ ] …and with **zero warnings** — `[Coverage: AUTOMATED]`
- [ ] Every emitted path resolves against the absolutized `arch_test.suite_path` / `formal.checks_dir`, never against the process cwd — so the file works from wherever it is opened — `[Coverage: AUTOMATED]`
- [ ] A `--mode demo` import runs end to end through the **real `LocalJobScheduler`** with a launcher that **throws on any spawn** — `[Coverage: AUTOMATED]`
- [ ] Omitting `--target-command` raises `missing_target_command` **and** the loader refuses the emitted file naming `riscv.target.command` — a file that looks fine and cannot run is the failure mode — `[Coverage: AUTOMATED]`
- [ ] Supplying `--target-command` yields a config with **no warnings at all** — `[Coverage: AUTOMATED]`
- [ ] `--target-command` is split the way a shell splits it, and `{elf}` / `{signature}` survive verbatim — `[Coverage: AUTOMATED]`
- [ ] `--extensions` / `--groups` filter case-insensitively and leave no empty suite behind — `[Coverage: AUTOMATED]`
- [ ] A multi-task `.sby` expands into one test per task and raises `multi_task_sby` — `[Coverage: AUTOMATED]`
- [ ] `--out` defaults to `./simcrux.yaml`, **never** inside the scanned checkout — `[Coverage: AUTOMATED]`
- [ ] `--mode riscof_passthrough` is refused with an explanation, not a bare invalid-value message — `[Coverage: AUTOMATED]`
- [ ] A wrong path is a `RiscvImportException` (exit 2), a bad flag a `RiscvImportCliException` carrying the usage block — `[Coverage: AUTOMATED]`
- [ ] Neither sub-command's flags reach the primary option parser; neither launches a window — `[Coverage: AUTOMATED]`
- [ ] Locale sweep (en / zh_CN / zh / ja / ko) of the two labels and three snackbars — `[Coverage: AUTOMATED]`
- [ ] The GUI flow really shows a **directory** picker, then a **save** dialog pre-filled `simcrux.yaml`, and cancelling either aborts with nothing written — `[Coverage: MANUAL]` (platform channel)
- [ ] The warning-flavoured snackbar appears when the import raised warnings, and the emitted file's header comment lists them — `[Coverage: MANUAL]`
- [ ] An import of a **real** `riscv-arch-test` checkout completes and its hundreds of rows render in the dashboard — `[Coverage: MANUAL]` (needs the real checkout)
- [ ] An import of a **real** riscv-formal `checks/` directory after `genchecks.py` completes — `[Coverage: MANUAL]` (needs the real checkout)

## Telemetry — cross-platform end-to-end pass (staging)

> **Run 2026-08-05/06** against the **staging** dataset `crux_telemetry_dev`, from
> builds made with `--dart-define=TELEMETRY_DEV=true`. What is collected and the
> consent switches are described at `https://edacrux.app/telemetry`.
>
> **Method per cell.** Build with the dev flag, launch, let the app settle, quit,
> **launch again** — the launch flush ships the *previous* session's queue — quit,
> then read the dataset after the 60–90 s ingest delay. No UI interaction is needed,
> because under the dev flag consent `unset` counts as `enabled`.
>
> **Attribution.** All four products ship `0.6.0`, so `app_version` cannot separate
> the runs. Rows are attributed by **`installation_id` (`blob8`)**: every platform has
> its own app-support container or browser origin, so each run mints a distinct id
> (recorded below). Runs were serialised, so the UTC window corroborates the id.
> Bring-up probe rows are excluded by `blob2 = '0.6.0'` (probes are `8.8.x` / `9.8.x`
> / `9.9.x`), and the Worker's own contract fixture by
> `blob8 != '6f1b0d3e-2a44-4c9e-9f1a-8d5b7c2e4a10'`.

| Platform | `os` | `form_factor` expected | observed | Result |
|---|---|---|---|---|
| macOS 26.6 (Apple silicon), release | `macos` | `desktop` | `desktop` | **PASS** |
| Chrome 151, release web build | `web` | `web` | `web` | **PASS** — re-run 2026-08-06 after the D1 fix; installation `5a0805ba-6a39-40d3-b67e-5d3ada76f237` |
| Windows | `windows` | `desktop` | — | **DEFERRED** — no Windows machine on this host |
| Linux | `linux` | `desktop` | — | **DEFERRED** — no Linux machine on this host |
| iOS / Android | — | — | — | **N/A — SimCrux ships no mobile target.** The repo has `macos/`, `web/`, `windows/` and `linux/` runners and no `ios/` or `android/` directory, so there is no build to run and nothing is being deferred for want of hardware |

SimCrux has no device-class system and its derivation introduces none — `form_factor` is `web` or `desktop` and nothing else. `desktop` on macOS is the only answer it can give, and it gave it.

- [x] The passing row carried the right envelope: `product=simcrux`, `locale=en`, `country=US` (stamped at the edge), `license_tier=openCore`, and a normalized `session_start` — `[Coverage: MANUAL]` (staging dataset)
- [x] `_sample_interval = 1` on every row, so the `product/event_name/properties` index is not sampling at this volume — `[Coverage: MANUAL]`

**Installation ids** — Chrome web `5a0805ba-6a39-40d3-b67e-5d3ada76f237` (re-run 2026-08-06) · macOS `bef0950f-89a3-4f12-a6fd-b0b50eca9cbb`.

### Picking up the deferred cells on another machine

```bash
# On a Windows or Linux host:
flutter build windows --release --dart-define=TELEMETRY_DEV=true   # or: build linux
#   launch the built binary twice, quitting in between, then query the staging
#   dataset `crux_telemetry_dev` for the new installation id.
```

### The negative cases

- [x] **A beta build without the dev flag performs zero telemetry HTTP.** Primary
  evidence is the traffic-level beta-inert test — `[Coverage: PACKAGE]`
  (`crux_telemetry`'s `telemetryServiceProvider` suite, 64 tests, sweeps all 12
  `policy × consent` cells asserting an empty request list) — plus this repo's own
  group — `[Coverage: UNIT]` (`test/core/providers/telemetry_service_provider_test.dart`).
  Corroborated at runtime — `[Coverage: MANUAL]`: a NetCrux release built with **no**
  `--dart-define` was launched twice and **never created `telemetry_queue.jsonl` at
  all** (the live service is never constructed, so `record()` hits the no-op and
  nothing touches disk or the network), and the **production** dataset
  `crux_telemetry` holds **0 rows over 90 days**.
- [x] **Consent `disabled` with the dev flag sends nothing.** — **PASS** on the
  2026-08-06 re-run. Exercised on WaveCrux (shared gate; every product resolves
  the same `telemetryEnabledProvider` from `crux_telemetry`, so the fix is
  suite-wide). See D3 below.

### Defects found — all three FIXED on 2026-08-06

- [x] **D1 — web builds never transmit; the `web` `form_factor` is unreachable in
  practice.** All four products' release web builds produced **zero** rows across two
  page loads each, simcrux included. A full Chrome `--log-net-log` capture over a 90 s
  web session shows **zero requests to `telemetry.edacrux.app`** (the same capture
  holds 300 references to the page's own assets, so the capture itself is sound).
  Mechanism, reproduced hermetically against `LiveTelemetryService` with a
  `directoryFactory` that throws (exactly what web does): on web `path_provider` is
  unavailable, so `TelemetryEventQueue` degrades to memory-only and `load()` returns
  empty; `start()`'s launch flush therefore runs against an empty `_pending` and
  returns at `if (_pending.isEmpty) return;` **without arming anything**; the only
  remaining trigger is the 6-hourly timer, which no browser session survives. On
  desktop the disk queue carries events to the next launch, which is why only web is
  affected. **Not a shipping-harm defect today** (the pipeline is dark-launched until
  `kBetaPeriod` flips), but the field exists to answer "does the web build earn its
  maintenance" and it cannot. Fix is a design call between (a) backing the queue with
  the `TelemetryStorage` seam on web so it survives a reload, or (b) arming a short
  follow-up flush when the launch flush finds the queue empty — (b) changes the
  documented "this session's events go out on the next six-hourly tick or the next
  launch" contract on every platform. **Lives in
  `crux-shared/packages/crux_telemetry`. **FIXED 2026-08-06** in
  `crux_telemetry` 0.3.0 (crux-shared `1c30b1f`) — option (b), scoped to the
  volatile queue only, so desktop and mobile keep the documented contract
  verbatim: where `hasPersistentBacking()` is false, `record()` arms one flush
  per `volatileFlushInterval` (60 s) and the host's hidden/paused/detached
  signal flushes too. Verified above.**
- [x] **D2 — `form_factor` races the first layout (WaveCrux only).** WaveCrux's
  derivation reads a size that is pushed from inside `MaterialApp.builder`, while the
  envelope is resolved at launch-flush time, ahead of it; on a Pixel Tablet the same
  build in the same orientation reported `desktop` three times and `tablet` once.
  **SimCrux is not affected**: its `telemetryFormFactorFor` takes `isWeb` and
  nothing else, so it has no size to race. **FIXED 2026-08-06** in WaveCrux; the
  shared half is `telemetryFormFactorProvider` becoming `Provider<String?>`,
  where `null` means "not knowable yet" and the flush defers rather than
  reporting a pre-layout default. SimCrux keeps returning a value — `kIsWeb` is a
  compile-time constant, so there is no race to lose and deferring would cost a
  flush interval to answer a question that was never open. Stated in the
  override; see WaveCrux's checklist §13A.3.
- [x] **D3 — a stored consent of `disabled` still transmits under the dev flag.**
  Exercised on WaveCrux: with `flutter.telemetry.consent = disabled` and a
  `TELEMETRY_DEV=true` build, two launches produced a real row in the staging dataset
  from the very installation whose consent is `disabled`. Cause:
  `TelemetryConsentStore.build()` publishes `TelemetryConsentState.unset`
  **synchronously** and loads the persisted value asynchronously, while
  `telemetryEnabledProvider` computes `consent == enabled || (dev && consent ==
  unset)` — so for the first frames of a cold start a stored `disabled` is
  indistinguishable from "not answered", and under the dev flag the gate opens.
  **Blast radius is dev builds only**: with `dev == false` the beta branch
  short-circuits synchronously during the beta, and post-flip the gate reads
  `consent == enabled`, where `unset` fails safe. No shipping build is affected and
  the beta promise is intact — but the documented dev-flag guarantee (a stored
  `disabled` never transmits) is broken. The 36-cell gating matrix cannot catch this: it seeds consent by assigning
  `notifier.state` directly, so **no cell exercises a value read back through
  storage**. Fix: gate the dev-flag `unset` promotion on the store having settled (it
  already owns a `loaded` completer), and add a storage-backed cell to the matrix.
  **SimCrux shares the gate, so it is affected identically.** Lives in
  `crux-shared/packages/crux_telemetry` and needs a submodule-pin bump in all four
  products. **FIXED 2026-08-06** in `crux_telemetry` 0.3.0: the dev-flag
  promotion of `unset` now waits on `telemetryConsentReadyProvider`, the same
  `loaded` signal the disclosure already waited on, and the package gained a
  pre-load group that seeds *storage* behind a gated read — the gap that let
  this through. Pinned at crux-shared `1c30b1f`.

  One consequence worth recording, because it was found only by re-running on a
  real client: waiting for the store creates a window, and the window is not
  incidental — the store's read does not *start* until something reads the
  telemetry graph, so the first event of every launch falls inside it by
  construction. Resolving the no-op there **discarded** that event, which on web
  is the whole session. The gate is therefore a tri-state now
  (`TelemetryGate { open, closed, pending }`) and `PendingTelemetryService`
  buffers the window, replaying into the live service when the gate opens and
  dropping the buffer when it closes. The beta never enters that state.**

---

## Standalone headless binary (guide §19)

- [ ] `tool/build_cli.sh` compiles `bin/simcrux.dart` and the smoke test passes — the Flutter-freeness proof — `[Coverage: MANUAL]`
- [ ] `simcrux --ci <config> --export junit=<path>`: summary line, valid JUnit XML, exit `0`/`1` by threshold — `[Coverage: UNIT]` (`simcrux_cli_test.dart`) + `[Coverage: MANUAL]` with a real simulator
- [ ] `simcrux --import-fusesoc <core>` writes the `simcrux.yaml` + warnings, exit `0`; broken core → `2` — `[Coverage: UNIT]`
- [ ] Nothing-to-do invocations (bare project path, no args) print usage and exit `2`, never a silent `0` — `[Coverage: UNIT]`
- [ ] The binary transmits no telemetry (no-op service, unconditionally) — `[Coverage: UNIT]` (constructor default) + code review

---

## Screen reader and keyboard regions (guide §20)

- [ ] Launch with no tabs: focus is on Open Config… and the screen reader announces it — `[Coverage: WIDGET]` (`screen_reader_test.dart`) + `[Coverage: MANUAL]`
- [ ] F6 / Shift+F6 cycle toolbar, main surface and bottom chrome — `[Coverage: UNIT]` (crux-shared) + `[Coverage: MANUAL]`
- [ ] Each results row is one Tab stop announced as "*status*: *suite* / *test*, *simulator*, ran in *runtime*" — `[Coverage: WIDGET]` (`goldens/results_dashboard.txt`)
- [ ] On a results row, Space toggles the check box and Enter opens the test in the Details dock — `[Coverage: WIDGET]` (`dashboard_results_table_test.dart`)
- [ ] Tests dock: suite headers are "expanded"/"collapsed" buttons; each test is named with its status — `[Coverage: WIDGET]` (`goldens/tests_dock.txt`)
- [ ] A config that fails to load is spoken, not only drawn — `[Coverage: WIDGET]` (`regression_tab_content_test.dart`) + `[Coverage: MANUAL]`
- [ ] Changing sort mid-run never leaves the table on "Loading results…" — `[Coverage: UNIT]` (`in_memory_result_store_test.dart`)
- [ ] Tab close buttons name their tab; the stats disclosure is "Statistics" — `[Coverage: WIDGET]`
- [ ] Column headers announce as buttons — `[Coverage: WIDGET]`
- [ ] A bare Space or Enter binding does not steal activation from a focused button — `[Coverage: WIDGET]` (`shortcut_manager_widget_test.dart`)
- [ ] No arrow glyphs in any locale's strings — `[Coverage: UNIT]` (`speakable_strings_test.dart`)
- [ ] The guide §20.3 tasks complete by ear on at least one platform — `[Coverage: MANUAL]`

---

## Opening a design manifest (guide §21)

- [ ] **Open Config…** (start screen and File menu) lists `uart_tx.crux-project` without showing hidden files and opens the config its `simulation:` entry names — `[Coverage: MANUAL]` (platform dialog)
- [ ] `simcrux uart_tx/uart_tx.crux-project` and `simcrux uart_tx/` open the same tab — `[Coverage: WIDGET]` (`cli_regression_bootstrapper_test.dart`)
- [ ] A legacy bare `.crux-project` opens and the snack bar names the file to rename it to — `[Coverage: WIDGET]` (`cli_regression_bootstrapper_test.dart`)
- [ ] A directory holding two manifests opens nothing and names both — `[Coverage: WIDGET]` (`cli_regression_bootstrapper_test.dart`, `open_config_tab_test.dart`)
- [ ] Invalid, no-`simulation:` and missing-config manifests open nothing and say why, in every locale — `[Coverage: UNIT]` (`crux_project_resolution_test.dart`) + `[Coverage: WIDGET]` (`open_config_tab_test.dart`)
- [ ] macOS: Finder **Get Info** on a `.crux-project` lists SimCrux under **Open with** — `[Coverage: MANUAL]`

---

## Opening a file from Finder (guide §22)

- [ ] Quit SimCrux, open a `simcrux.yaml` with **Open With → SimCrux**: the app launches with that project in an armed, not running, tab — `[Coverage: MANUAL]` (release build)
- [ ] `.yaml`/`.yml` and `.crux-project` are offered under **Open with** but are not the default application until the user chooses SimCrux; `.simcrux-workspace` and `.simcrux-session` open on a double-click — `[Coverage: STATIC]` (`macos_document_open_handler_test.dart`, `platform_config_parity_test.dart`) + `[Coverage: MANUAL]`
- [ ] With SimCrux running, double-clicking a `.yml`, a `.crux-project`, a `.simcrux-session` or a `.simcrux-workspace` opens it as its command-line spelling does — `[Coverage: WIDGET]` (`cli_regression_bootstrapper_test.dart`) + `[Coverage: MANUAL]`
- [ ] `open -a SimCrux <file>` and a drop on the Dock icon open the file — `[Coverage: MANUAL]`
- [ ] A double-clicked project whose `simulators:` entry sets `path:` loads with the tooling advisory and runs nothing while the Settings switch is off — `[Coverage: UNIT]` (`cli_regression_bootstrapper_test.dart`) + `[Coverage: MANUAL]`
- [ ] The native channel contract (launch file first, then later files; silent without a native half) — `[Coverage: UNIT]` (`incoming_file_service_test.dart`); the Swift half compiles — `[Coverage: BUILD]`

---

## Seeing the first-run dialogs again (guide §23)

- [ ] On an installation that has accepted, `--reset-eula` presents the license agreement on that launch, and a relaunch without the flag does not — `[Coverage: UNIT]` (`app_reset_eula_test.dart`) + `[Coverage: MANUAL]`
- [ ] `--reset-eula --reset-telemetry-consent` shows both dialogs, the agreement first — `[Coverage: MANUAL]`
- [ ] `--help` lists `--reset-eula`, an unknown flag still exits `2`, and the standalone binary accepts both reset flags — `[Coverage: UNIT]` (`cli_arg_parser_test.dart`, `simcrux_cli_test.dart`)

---

## Subsequent features

---

## Sign-off

- [ ] All feature groups above signed off
- [ ] Pro overlay checklist ran cleanly (if signing off a Pro build)
- [ ] Cross-platform smoke pass (Linux + macOS + Windows) for any UI-affecting change
