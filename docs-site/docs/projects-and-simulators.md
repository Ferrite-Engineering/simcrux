# Projects & simulators

A SimCrux project is a `simcrux.yaml` file describing your test suites and the
simulators that run them. This page is the reference for the config schema —
suites, tests, inheritance, includes, filelists, `<design>.crux-project`
manifests —
and for the simulator drivers and how each is configured.

## The simcrux.yaml schema {#schema}

A project declares a schema `version`, optional `defaults:`, and one or more
named `suites:`, each with a list of `tests:`. The current schema version is
`'1'`, and `version:` is required.

```yaml
version: '1'

defaults:
  simulator: icarus    # default driver for tests that don't override it
  pass_fail: { … }     # see Pass/fail detection (default: exit_code)
  waveform: { … }      # see Waveforms & debug
  timeout: 60s         # optional — 300s when omitted
  riscv: { … }         # optional — see RISC-V below

simulators:            # optional — per-driver binary overrides
  icarus:
    source: custom     # system (default behaviour) | bundled | custom
    path: /opt/eda/iverilog/bin   # required when source is custom — GATED
    env: { LM_LICENSE_FILE: '2100@lic' }   # optional extra environment — GATED
    options: {}        # optional — read by cocotb, and `args` by verilator

output:                # optional — where --ci writes its streaming results
  results_path: build/results.ndjson   # inside this directory — GATED outside

includes:
  - shared.simcrux.yaml   # resolved relative to this file

suites:
  axi:
    description: AXI4-Lite protocol regression.
    simulator: verilator    # optional — overrides defaults.simulator
    timeout: 5m
    sources:
      - rtl/axi_common.sv   # merged with each test's sources
    include_dirs:
      - rtl/include
    defines:
      AXI_DATA_WIDTH: '32'
    resources:
      - pcie_lane_0
    tests:
      - name: burst
        top: tb_axi_burst
        sources:
          - rtl/axi_burst.sv
          - tb/axi_burst_tb.sv
        defines:
          BURST_LEN: '16'
        parameters:          # forms the unique test id suffix
          BURST_LEN: '16'
        seed: 42             # optional — pins one seed
        timeout: 30s
```

| Key | Level | Meaning |
|---|---|---|
| `name:` | test | Required. The test name; the test id is `<suite>/<name>`. |
| `top:` | test | Required. The top-level module or entity to elaborate and run. |
| `simulator:` | defaults, suite, test | Required at one of the three levels: `icarus`, `verilator`, `ghdl`, `cocotb`, `riscv_arch` or `riscv_formal`. There is no built-in default, so a test that inherits none does not load. |
| `sources:` | suite, test | HDL (and testbench) files, relative to the project file. `.f` filelists are expanded. |
| `include_dirs:` | suite, test | Include / library search directories. |
| `defines:` | suite, test | Preprocessor defines, `KEY: 'value'`. |
| `timeout:` | defaults, suite, test | Wall-clock budget. A bare number of seconds or a number with `ms`, `s`, `m` or `h`: `90`, `90s`, `1m`. See [Per-test timeouts](running-tests.md#timeouts). |
| `resources:` | suite, test | Named locks; tests sharing one never run concurrently. See [Resource locks](running-tests.md#locks). |
| `pass_fail:` | defaults, suite, test | The detector. See [Pass/fail detection](pass-fail-detection.md). |
| `waveform:` | defaults, suite, test | `capture:` and `format:`. See [Capture policy](waveforms-and-debug.md#policy). |
| `parameters:` | test | Named values that form the test id. A list value is a sweep axis. See [Seed sweeps](trends-and-flaky.md#sweeps). |
| `seed:` / `seeds:` | test | One pinned seed, or a list / range to sweep. See [Seed sweeps](trends-and-flaky.md#sweeps). |
| `description:` | suite | Free text. |
| `includes:` | top level | Other project files to merge in. |
| `output:` | top level | Where `simcrux --ci` writes `results.ndjson` and `results.summary.json`. See [Streaming results](baselines-ci-exports.md#streaming-results). |

`parameters:` values make up the test id (`axi/burst+BURST_LEN=16`) but are
**not** passed to Icarus, Verilator or GHDL. The cocotb driver reads a few
reserved keys from it — see [Cocotb versions and options](#cocotb).

!!! note "`bundled` does not bundle anything yet"
    SimCrux ships no simulator binaries. `source: bundled` and `source: system`
    behave identically today — both resolve the bare executable name
    (`iverilog`, `vvp`, `verilator`, `ghdl`, `make`) against your `PATH`.
    `bundled` is a reserved value. Use `source: custom` with `path:` when you
    need an explicit location.

    `path:` may name the directory holding the tools, or the executable itself
    when the driver runs a single tool (`verilator`, `ghdl`). Use a directory
    for Icarus, which runs both `iverilog` and `vvp` from it.

!!! warning "Keys that choose a program are off until you allow them"
    These keys choose which program SimCrux runs, the environment it runs
    under, or a file outside the project that a run overwrites:

    | Keys | Without permission |
    |---|---|
    | `simulators.<id>.path`, `simulators.<id>.env` | Ignored, with a load advisory |
    | `riscv` `target.command`, `riscof.command`, `compile.command`, `formal.command` | The project does not load |
    | `riscv` `reference.path`, `toolchain.path`, `toolchain.prefix`, `riscof.binary`, `formal.sby_binary` | Ignored, with a load advisory; the conventional name is looked up on `PATH` |
    | `output.results_path`, `output.summary_path` outside the project directory | The project does not load |

    A project file that sets one is running code decided by whoever wrote the
    file, or, for the `output:` paths, having `--ci` create and truncate a
    file of their choosing anywhere you can write, and `.yaml` files open in SimCrux by double-click, so a project file
    you cloned or downloaded is not automatically yours. So SimCrux honors
    them only once you say so:

    - In the app, turn on **Settings → Simulators → Let project files choose
      simulator binaries and environment**. Until then each advisory or error
      names the file and line.
    - Headless, pass `--allow-project-tooling`.

    Nothing else in the file is gated — `source:`, `options:`, `sources:`,
    detectors, sweeps and the rest load normally. **Settings → Simulators →
    Binary path** is unaffected too: that value is yours, not the file's.

    This does not make an untrusted project safe to *run*. Running tests runs
    the project's own code whatever engine runs it: a cocotb `Makefile` and
    Python test module, the C++ Verilator builds, a SymbiYosys `.sby` job, or
    a testbench that calls `$system`. Opening a project never runs it unless
    you turned on **Settings → General → Run the regression when a config is
    opened**, so read a project you did not write before you press Run.

!!! note "Settings → Simulators"
    The desktop app's **Settings → Simulators → Binary path** override is
    applied to runs started from the app as a `source: custom` binary, unless
    the project's `simulators:` entry for that simulator names its own binary
    (`source: custom` with a `path`) — then the project file wins. An entry that
    only sets `options:` keeps them and still takes the Settings path.
    `simcrux --ci` reads only the project file, so the equivalent of the
    Settings switch there is `--allow-project-tooling`.

## Opening a design with `<design>.crux-project` {#crux-project}

A design usually spans more than one EDACrux product — the dump in WaveCrux,
the RTL in NetCrux, the lint project in LintCrux, the regression suite in
SimCrux. Without help that is four file-open rituals, each with its own recents
list and its own chance of picking a stale file.

A design manifest at the root of your design replaces all four. It is a small
YAML file named after the design — `uart_tx.crux-project` — that you write once
and check in alongside the RTL:

```yaml
# uart_tx/uart_tx.crux-project
version: 1
name: uart_tx

design:
  top: uart_tx
  sources:
    - rtl/uart_tx.v

artifacts:
  waveform:   sim/uart_tx.vcd
  lint:       project.lintcrux
  simulation: simcrux.yaml
```

Open it in any of the four products and that product opens the part it owns.
SimCrux opens the `simulation` artifact — the `simcrux.yaml` the manifest
points at. Every path is relative to the manifest's own directory, so the file
travels with the repository. In SimCrux, open a manifest with **Open Config…**
on the start screen or **File → Open Config…** — both dialogs list
`.crux-project` files beside `.yaml` and `.yml` — or name it on the command
line: `simcrux uart_tx/uart_tx.crux-project`. On the command line the design
directory works too (`simcrux uart_tx/`), as long as it holds exactly one
manifest; with more than one, SimCrux opens nothing and names them. `simcrux
--ci` takes the `simcrux.yaml` itself.

All four products also derive the same design identity from it, so
cross-probing between them works exactly as it does when you open each file by
hand — the manifest is a shortcut, not a different mode.

!!! note
    **Everything except `version` is optional.** A manifest with no
    `simulation:` artifact, or one whose config is not on disk, is refused with
    a message saying so rather than a failure. Keys a newer release understands
    and an older one does not are ignored, so a manifest never becomes
    unopenable.

!!! note "The old `.crux-project` file name"
    A manifest named just `.crux-project`, with nothing before the dot, still
    opens, and SimCrux tells you what to rename it to — the design directory's
    name plus `.crux-project`. File pickers and Finder hide files whose names
    start with a dot, and a later release stops reading the old name.

A design manifest holds no view state and no personal settings — it says what
the design *is*, not how you last looked at it.

## Defaults & inheritance {#inheritance}

Settings cascade from the project's `defaults:`, to the suite, to the individual
test — the test wins last. `sources:`, `include_dirs:` and `resources:` are
appended to the suite's lists, so a suite can declare shared RTL once and each
test adds only its own testbench. `defines:` and `riscv:` merge key by key with
the test's value winning. Every other key (`simulator`, `timeout`, `pass_fail`,
`waveform`) replaces the inherited value outright.

`defaults:` accepts `simulator`, `pass_fail`, `waveform`, `timeout` and `riscv`.
Shared `sources:`, `include_dirs:`, `defines:` and `resources:` belong on the
suite.

## Splitting config with includes {#includes}

For large projects, split the config across files and pull them together with
`includes:`. You can keep one file per IP block or per team and a thin
top-level file that stitches them together.

```yaml
# simcrux.yaml
version: '1'
includes:
  - suites/alu.simcrux.yaml
  - suites/uart.simcrux.yaml
```

Included files are resolved relative to the including file, recursively, with
cycle detection. Their suites and `simulators:` entries are merged in; on a
conflict (same suite name, same simulator id) the including file wins. The
including file's `defaults.simulator`, `pass_fail`, `waveform`, `timeout` and
`riscv` fill gaps in an included file's own `defaults:`.

## Filelists and FuseSoC import {#filelists}

**`.f` filelists** — any `sources:` entry ending in `.f` is expanded when the
project loads, so you reuse the source manifest your other tools consume:

```text
# rtl/core.f — paths resolve relative to this file's own directory
+incdir+include
+define+SYNTHESIS=1
-I ../common/include
-DWIDTH=32
cpu.sv
alu.sv
```

The expander understands one path per line, `#` and `//` comment lines,
`+incdir+<dir>`, `+define+KEY=VALUE`, `-I<dir>` / `-I <dir>` and
`-D<KEY=VALUE>` / `-D <KEY=VALUE>` (a bare `KEY` means `KEY=1`). Include
directories and defines are merged into the test's `include_dirs:` and
`defines:`. Globs are not expanded, here or in `sources:`.

**FuseSoC `.core` import** — **File → Import FuseSoC .core File…**
(++cmd+i++ / ++ctrl+i++) or `simcrux --import-fusesoc <file>` reads a CAPI2
`.core` file and writes a `<name>.simcrux.yaml` next to it with the sources, top
module and simulator filled in. From there you edit it like any other config.
See [Importing FuseSoC files](fusesoc-import.md).

### Mixed-language designs {#mixed-language}

`sources:` accepts bare strings and an object form with an explicit
`language:`:

```yaml
sources:
  - rtl/cpu.v                                  # language inferred (verilog)
  - rtl/cpu.sv                                 # language inferred (systemverilog)
  - rtl/legacy_pkg.vhd                         # language inferred (vhdl)
  - { path: rtl/blob.bin, language: verilog }  # explicit override
  - { path: rtl/auto.v, language: auto }       # same as a bare string
```

The language is inferred from the file extension. Recognized `language:` values:
`auto` (default), `verilog`, `systemverilog` (or `system_verilog` / `sv`),
`vhdl` (or `vhd`), `python`. SimCrux does not pick a simulator for you: it
checks every test's sources against the configured simulator's languages when
the project loads.

| Simulator | Languages |
|---|---|
| `icarus` | Verilog, SystemVerilog |
| `verilator` | Verilog, SystemVerilog |
| `ghdl` | VHDL |
| `cocotb` | Verilog, SystemVerilog, VHDL and Python |

A test whose sources include a file its simulator cannot handle fails to load
with a message like:

> Test `cpu_unit/alu_basic` requires VHDL support (file `rtl/legacy.vhd`); the
> configured simulator `icarus` only supports Verilog / SystemVerilog. Switch
> the simulator to `ghdl` or `cocotb`, or remove the file.

## Validation {#validation}

On open, and again on every run, SimCrux loads the config and reports problems
before running anything: YAML syntax errors, a missing or unsupported
`version`, a suite without `tests`, a test without `name` or `top` or with no
`simulator:` at any level, unknown
values for enumerated keys (`capture:`, `format:`, `source:`, `language:`,
detector `type:`), malformed detectors, include cycles, sweeps that expand too
far, and the language mismatches above. Each message names the file and line.
The project does not load until they are fixed.

Validation does not check that source files exist (apart from `.f` filelists,
which must be readable) or that a simulator binary is installed — those surface
when the test runs, as a compile failure or an `unknown` result. Unrecognized
keys are ignored rather than rejected.

**Tools → Tab Diagnostics…** shows the loaded config's path, schema version,
and suite and test counts (see [Diagnostics](interface.md#diagnostics)).

## The simulator drivers {#drivers}

SimCrux invokes each simulator through a driver that handles compile, run,
output capture and waveform selection. SimCrux builds each command line itself;
only the Verilator driver takes extra flags (below).

| Driver | `simulator:` | Pipeline | Notes |
|---|---|---|---|
| Icarus | `icarus` | `iverilog -g2012 -o sim.vvp -s <top> -I… -D… <sources>` → `vvp sim.vvp` | The generation is fixed at `-g2012`. |
| Verilator | `verilator` | `verilator --cc --exe --build … [--timing] -Wall -Wno-fatal [args] sim_main.cpp <sources>` → `./obj_dir/V<top>` | SimCrux generates `sim_main.cpp`. Warnings are printed and captured but never fail the build. |
| GHDL | `ghdl` | analyse → elaborate → run, always with `--std=08 --ieee=synopsys` | `include_dirs:` become `-P<dir>` library search paths. Writes the waveform itself. |
| Cocotb | `cocotb` | `make` in the test's working directory, with `SIM`, `TOPLEVEL` and `TOPLEVEL_LANG` | Copies the test's `sources:` (list your `Makefile` and Python module there too) into the working directory. |
| RISC-V architectural tests | `riscv_arch` | Your core's command per test, then a signature comparison | See [RISC-V](#riscv). |
| riscv-formal | `riscv_formal` | One SymbiYosys `sby` job per bounded proof | See [RISC-V](#riscv). |

### Verilator flags {#verilator}

- **Warnings do not fail the build.** The driver passes `-Wall -Wno-fatal`:
  lint findings such as an unused signal or a module name that does not match
  its file name are printed in the log, and the test still runs. An `%Error`
  still fails the compile.
- **`#` delays work on Verilator 5.** The driver reads `verilator --version`
  once and, on 5 or newer, passes `--timing` and generates a `sim_main.cpp`
  that advances to each scheduled event. If a Verilator 5 simulation runs out
  of events without reaching `$finish`, it exits `1` with
  `simulation ran out of events before $finish` rather than passing. On
  Verilator 4 the generated main steps time one unit at a time until
  `$finish`.
- **Extra flags.** `simulators.verilator.options.args` is split like a shell
  command line (quotes and backslashes work) and passed after the driver's own
  flags, so it can add or override them:

```yaml
simulators:
  verilator:
    options:
      args: "-Wno-WIDTH -O3 -DSIMULATION=1"
```

### Cocotb versions and options {#cocotb}

The driver is tested against **cocotb 1.9 through 2.1** and detects nothing at
run time: the output parsers accept every format those versions emit, which
matters because `cocotb-config` often lives in a virtualenv SimCrux cannot see.
Cocotb 2.1 requires **Python 3.9 or newer** and no longer publishes 32-bit
builds.

Results come from the `results.xml` cocotb writes beside each run — an xUnit
report it has produced since 1.x — in preference to the end-of-run summary
table, which changes between releases. A run that produces no report falls back
to the table, and then to `make`'s exit code. Per-testcase status and simulated
time are recorded as `cocotb.*` metrics on the result. The report's outcomes are
counted from its test cases, so the 1.9 and 2.0 formats (which carry no failure
counts on the suite) are read correctly.

Cocotb 1.9's `make` exits `0` even when tests fail. With no `pass_fail:`
configured, a failing report still makes the test a **fail**: the driver does
not pass that `0` on to the default `exit_code` detector. See
[Pass/fail detection](pass-fail-detection.md#parsers).

The driver derives `TOPLEVEL_LANG` from the test's dominant source language
(ties break Verilog → SystemVerilog → VHDL, and per-source `language:` overrides
count). `parameters.TOPLEVEL_LANG: vhdl` (or `verilog`) on the test always
wins. With no HDL sources, cocotb's own Makefile default applies.

`simulators.cocotb.options` accepts the following. Each is also settable per
test under `parameters:`, which wins (and, like any parameter, becomes part of
the test id). Nothing is emitted unless you set it.

| Option | Cocotb variable | Effect |
|---|---|---|
| `sim` | `SIM` | Underlying simulator (default `icarus`) |
| `max_failures` | `COCOTB_MAX_FAILURES` | Abandon the regression after N failures. Cocotb 2.1+ |
| `random_order` | `COCOTB_RANDOM_TEST_ORDER` | `"true"` shuffles test order within a stage, to surface order dependence. Cocotb 2.1+ |
| `preview` | `COCOTB_PREVIEW` | Opt into a cocotb preview feature, e.g. `xfail_in_results` |

A per-test `parameters.MODULE` is passed as both `MODULE` and
`COCOTB_TEST_MODULES`.

```yaml
simulators:
  cocotb:
    options:
      sim: verilator
      max_failures: "5"
      preview: xfail_in_results
```

`max_failures` must be a positive integer. Any other value — in
`simulators.cocotb.options` or a cocotb test's `parameters:` — stops the project
from loading, with the file and line.

With `preview: xfail_in_results`, cocotb reports `@cocotb.xfail` tests as
`XFAIL` rather than `PASS` and adds an `XFAIL=n` counter. SimCrux counts those
as expected outcomes, so a run whose tests all xfail by design is a pass.

### RISC-V {#riscv}

`riscv_arch` compares architectural-test signatures against a reference model
(with the `golden_compare` detector), and `riscv_formal` runs riscv-formal
bounded proofs through SymbiYosys. Both are configured through a `riscv:` block
that inherits like `defaults:` → suite → test. Rather than write it by hand,
generate it with **File → Import RISC-V Architectural Tests…** /
**File → Import riscv-formal Checks…** or the matching
[CLI subcommands](cli.md#subcommands), and try the toolchain-free `mode: demo`
projects under `examples/` in the repository. The compatibility and formal
verdicts are open core in every tier; the Pro **Compatibility** and
**Formal proofs** screens are analysis views over them.

`riscv.formal.check` names the proof's task directory inside the test's working
directory, which `sby -f` deletes and recreates, so it must be a single file
name such as `insn_add_ch0`: a path (`../..`, `/abs/dir`, anything with `/` or
`\`), `.` or `..` stops the project from loading, with the file and line.

## Custom driver plugins <span class="tier tier-pro">Pro</span> {#plugins}

Pro adds custom driver plugins: an external program, speaking a documented
subprocess protocol, that teaches SimCrux a simulator id it does not ship.
Manage them in **Settings → Custom Driver Plugins** — also opened by
**Tools → Manage Driver Plugins…** — which asks for a one-time safety
acknowledgment before SimCrux scans the plugin directory or starts any plugin.
**Tools → Reload Driver Plugins** re-scans the directory after a change. A
built-in driver always wins over a plugin with the same simulator id.

Each `compile` and `run` request hands the plugin the whole test: its top
module, sources and their languages, include directories, defines, parameters,
seed, timeout and waveform policy. The plugin is started from the directory its
`manifest.yaml` is in. The protocol, including the fields of the test
description, is specified in `include/simcrux_driver_plugin_abi.md` in the SimCrux source tree.

!!! note
    No vendor-simulator plugin is available yet.

!!! note "Next"
    With a project that loads, move on to [Running tests](running-tests.md) for
    execution, concurrency, timeouts and resource locks, and
    [Pass/fail detection](pass-fail-detection.md) for the detector reference.
