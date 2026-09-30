# SimCrux (Open Core) — Integration Test Status

Flutter `integration_test/` suite exercising a fully running open-core SimCrux
build (started via `bootstrap` from `package:simcrux/app.dart`). Harness:
`integration_test/helpers/app_driver.dart` (`bootSimcrux` + `pumpUntil` /
`rootContainer` / workspace round-trip primitives). Mirrors the WaveCrux /
NetCrux harness; never `pumpAndSettle(Duration)`. SimCrux boots into an
`UncontrolledProviderScope`, so `rootContainer` reads the container off the
outermost scope widget.

**Seeded-run harness** (`integration_test/helpers/seeded_run.dart`): drives
the real pipeline (ConfigLoader → LocalJobScheduler → PassFailDetector →
per-tab result store) against an in-process `ScriptedDriver` registered as
`icarus`, so journeys exercise the dashboard / inspector / trend surfaces
against a completed run without real simulators or process spawns.
`writeSeededProject` emits a real on-disk `simcrux.yaml`; `tabContainerFor`
reaches the live per-tab `ProviderContainer`; multi-element outcome scripts
vary per re-run (flakiness seeding, used by the Pro suite).

## Running

Desktop-only. Run each file in its own invocation; retry on the environmental
macOS app-relaunch error.

```bash
flutter test integration_test/workspace/restore_round_trip_test.dart -d macos
```

## Implemented (green on macOS)

- [x] Cold-boot empty-canvas state — `workspace/empty_canvas_boot_test.dart`
      (also the harness smoke test)
- [x] Workspace auto-save + restore round-trip —
      `workspace/restore_round_trip_test.dart`
- [x] Theme preset switch flips MaterialApp brightness —
      `theme/theme_switch_test.dart`
- [x] Seeded run → dashboard → inspector —
      `dashboard/seeded_run_dashboard_test.dart` (CLI-opened project through
      the real scheduler + exit_code detector; covers table population,
      pass/fail outcome rendering, status-chip filter, name sort both
      directions, row select → inspector details + log preview from the real
      log buffers). Caught + fixed a real defect on landing:
      `InMemoryResultStore.currentRun` closed on completion, so any post-run
      provider rebuild (filter/sort change) left the dashboard stuck on
      "Loading results…".
- [x] CXP server lifecycle — `remote/cxp_server_lifecycle_test.dart` (real
      `SimCruxCxpServer` on an OS-picked port via the factory seam: starts on
      boot, TCP-connectable, stops on `cxpServerEnabled` off, restarts on
      re-enable).
- [x] Named workspace save / reset / open round-trip —
      `workspace/named_workspace_test.dart` (ported from NetCrux's
      `integration_test/workspace/named_workspace_test.dart`; drives the live
      `saveAs` / `resetWorkspace` / `loadFrom` notifier API).
- [x] Split-pane + move-tab-between-panes mutation contract —
      `workspace/split_pane_test.dart` (ported from NetCrux's
      `integration_test/workspace/split_pane_test.dart`).
- [x] CLI multi-config open → tab structure —
      `tabs/cli_multi_config_test.dart` (ported from NetCrux's
      `integration_test/tabs/cli_multi_file_test.dart`; each config is
      suite-less so `ConfigLoader` fails fast and deterministically, no real
      simulator process ever spawns). Caught + fixed a real defect on
      landing: `ProjectWorkspaceSync` (`lib/features/workspace/providers/
      project_workspace_sync.dart`) committed its "previous registry
      snapshot" from the *pre-mutation* read at the top of each convergence
      pass instead of the *post-mutation* state after that pass's own
      recorder actions ran. Under the real open-core `NoopProjectRegistry`
      (strict replace-on-open), recording a second tab evicts the first
      tab's registry entry; the next pass then misread its own prior action
      as an external change and either closed the first tab's live
      workspace tab outright or forced the workspace's active tab back to
      it — silently losing/reactivating tabs any time 2+ tabs were opened
      in sequence (exactly the CLI multi-config shape). Fixed by committing
      the post-mutation snapshot in a `finally` block; regression-covered in
      `test/features/workspace/providers/project_workspace_sync_test.dart`
      (new "single-project (NoopProjectRegistry / open-core) registry"
      group, which — unlike the rest of that file — exercises the real
      `NoopProjectRegistry` default instead of the multi-project test
      double).

## Dashboard / inspector residuals (closed out)

The seeded-result-set prerequisite is solved (`helpers/seeded_run.dart`);
all previously-tracked residual surfaces are now journey-covered. No open
items remain.

- [x] Inspector source navigation (Open Source button → editor hand-off) —
      `dashboard/inspector_open_source_test.dart` (seeded run, row select,
      Open Source button, `editorLauncherProvider` overridden at the root
      container with an `EditorLauncher` wired to a recording
      `processStarter` fake — mirrors `test/features/inspector/services/
      editor_launcher_test.dart`'s `_RecordingStarter` / `_FakeProcess`
      shape; asserts the fake recorded the resolved absolute testbench
      source path and default line/column).
- [x] Heatmap view-mode switch against a seeded run —
      `dashboard/dashboard_heatmap_view_mode_test.dart` (seeded run,
      `DashboardViewModeToggle` tap flips `dashboardViewModeProvider` from
      table to heatmap, `DashboardHeatmapView` renders one cell per seeded
      test keyed by `Tooltip` message, and a cell tap drives the shared
      `selectedTestIdProvider` selection same as a table row tap).
