# Welcome to SimCrux

SimCrux is a simulation regression manager and results dashboard for the
open-source HDL simulators — Icarus Verilog, Verilator, GHDL and Cocotb. It
replaces the Makefile-plus-shell-plus-`grep` regression rig with one
declarative `simcrux.yaml`, a parallel orchestrator that isolates and times
out tests properly, and an interactive results table you click into instead
of grep through. This guide is written for the people who run simulations for
a living: it is precise about config keys, simulator drivers, pass/fail
detectors, and the keyboard you will actually use.

!!! tip "New here?"
    Start with [Installation & first regression](getting-started.md), then take
    the [interface tour](interface.md). If you already have a working Makefile
    flow, jump to [Projects & simulators](projects-and-simulators.md) to see how
    it maps onto a `simcrux.yaml`, or read the
    [migration guides](migrating/index.md). Prefer to learn by doing? The
    [Cookbook](cookbook.md) walks complete workflows step by step.

**SimCrux does not ship any simulator.** Install the ones you want to drive
and put them on your `PATH` — see
[Installation & first regression](getting-started.md#simulators).

## Three steps: Run. Track. Debug. {#simulators}

SimCrux drives the open-source simulators behind one driver abstraction. You
declare which simulator each test uses; SimCrux compiles it, runs it, captures
`stdout`/`stderr`, applies your pass/fail rules, stores the result in a local
SQLite history, and renders it in a filterable dashboard with links to the log
and the waveform.

| Simulator | Language | `simulator:` value | How it is invoked |
|---|---|---|---|
| Icarus Verilog | Verilog / SystemVerilog | `icarus` | `iverilog -g2012` compile → `vvp` run |
| Verilator | Verilog / SystemVerilog | `verilator` | `verilator --cc --exe --build`, then the built model |
| GHDL | VHDL | `ghdl` | Analyse → elaborate → run with `--std=08 --ieee=synopsys` |
| Cocotb | Python testbench over any of the above | `cocotb` | `make` in the test's working directory; per-testcase results read from cocotb's `results.xml` |

Two further simulator ids drive RISC-V verification flows: `riscv_arch`
(architectural-test signature comparison) and `riscv_formal` (riscv-formal
bounded proofs through SymbiYosys). See
[Projects & simulators](projects-and-simulators.md#riscv).

## One app, four tiers {#tiers}

SimCrux ships as a single application. The free **Open Core** runner is fully
featured on its own; **Pro** and **Enterprise** add capability on top without
changing anything you already use, and **Education** grants the Pro feature
set free to verified students. This documentation covers all four. Wherever a
feature requires a paid tier, you will see a badge next to its name:

| Badge | Meaning |
|---|---|
| *(none)* | Open Core. Free and open source. No account, no license key, no time limit. |
| <span class="tier tier-pro">Pro</span> | Pro tier. Trend charts, flaky-test detection, seed and parameter sweeps, baselines and run comparison, PR annotations, custom driver plugins, and multi-project workspaces. |
| <span class="tier tier-enterprise">Enterprise</span> | Enterprise tier. A shared team results database fed by CI, org-wide retention thresholds from a signed policy file, distributed execution of `--ci` runs on your own cluster scheduler, and the audit log. |
| <span class="tier tier-edu">EDU</span> | Education tier. Every Pro feature, free for verified students, non-commercial. |

!!! note "What a badge costs you"
    Open Core is free. A badge in the app or in these docs marks a feature that
    asks for a Pro, Enterprise or EDU license. See [Tiers & licensing](licensing.md) for the full picture.

## How this guide is organized {#map}

**Getting started**

- [Installation & first regression](getting-started.md) — platforms, pointing
  SimCrux at your simulators, a minimal config, your first run.
- [The interface](interface.md) — the toolbar, the results table, the heatmap,
  the Details panel, the Log Viewer, the command palette, tabs and diagnostics.
- [Appearance & themes](appearance-and-themes.md) — the six built-in color
  presets, color overrides, and `.crux-theme.json` theme packs.
- [Keyboard & mouse reference](keyboard-mouse.md) — every default shortcut, the
  actions that ship unbound, and rebinding.
- [Tiers & licensing](licensing.md) — what each tier unlocks, and
  entering a license key.

**Running regressions**

- [Projects & simulators](projects-and-simulators.md) — the `simcrux.yaml`
  schema, inheritance, `includes:`, `.f` filelists, `<design>.crux-project`
  manifests, and the
  simulator drivers.
- [Running tests](running-tests.md) — run, cancel and re-run; concurrency;
  timeouts; resource locks; the live log; file watching.
- [Pass/fail detection](pass-fail-detection.md) — exit code, string and regex
  matchers, composite rules, the UVM and Cocotb detectors, golden compare, and
  the reusable detector library.
- [The results dashboard](results-dashboard.md) — the table, sorting, filter
  chips, test-name filtering, presets, the status bar, the heatmap and the
  Details panel.
- [Waveforms & debug](waveforms-and-debug.md) — capture policy, *Debug in
  WaveCrux*, re-run with waveform, and opening testbench source.

**Track & ship**

- [Trends, flaky tests & seeds](trends-and-flaky.md) — trend charts, calendar
  heatmaps, regression alerts, flaky-test detection, and seed sweeps.
  <span class="tier tier-pro">Pro</span>
- [Baselines, CI & exports](baselines-ci-exports.md) — baseline comparison,
  JUnit / JSON / CSV / HTML exports, `--ci`, and PR annotations.
- [Command line & CI](cli.md) — the full flag surface, exit codes and
  subcommands, including the standalone headless binary.
- [CI recipes](ci.md), [Publishing the results dashboard](ci-integration.md)
  and [The web dashboard](web-mode.md) — GitHub Actions, GitLab and Jenkins,
  and the read-only web viewer.
- [Team results database](team-database.md) — the shared PostgreSQL results
  store. <span class="tier tier-enterprise">Enterprise</span>
- [Cross-probe & the suite](integrations.md) — the CXP link to WaveCrux, NetCrux
  and LintCrux, editor integration, and multi-project workspaces.

**Administration** — [Org-wide configuration](administration.md) for the person
deploying SimCrux across a fleet. <span class="tier tier-enterprise">Enterprise</span>

**Cookbook** — [task-driven recipes](cookbook.md): run your first regression,
triage failures into the waveform, hunt down flaky tests, run a seed sweep.

## Conventions used in this guide {#conventions}

- Keyboard shortcuts are written macOS first: ++cmd+o++ / ++ctrl+o++. Where only
  one key is shown, it applies to every platform (for example ++f5++ to run a
  regression).
- `Monospace` marks file names, config keys, CLI flags, and anything you type.
  **Bold** marks labels you click in the app.
- A <span class="tier tier-pro">Pro</span>,
  <span class="tier tier-enterprise">Enterprise</span> or
  <span class="tier tier-edu">EDU</span> badge beside a heading means everything
  under it requires that tier.
- SimCrux is a desktop app for Linux, macOS and Windows. A read-only
  [web dashboard](web-mode.md) shows exported results in a browser.
- **Known issue** boxes describe current behaviour that differs from the
  design. They are removed when the fix ships.

!!! note "Quick links"
    [Download SimCrux](https://simcrux.app/download) ·
    [Open source](https://edacrux.app/open-source) ·
    [Pricing](https://simcrux.app/pricing) ·
    [Run your first regression](cookbook-first-regression.md)
