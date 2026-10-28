# Command line & CI

SimCrux runs regressions without a window. Besides the desktop app's own
command line, it builds as a **standalone binary with no GUI in it at all** —
the thing you put in a CI runner or an Edalize flow, on an image that has no
display server and no reason to have one. This page is the full argument
surface, the exit codes, and the subcommands. Ready-made pipeline jobs are on
[CI recipes](ci.md).

## Two front doors, one argument surface {#two-front-doors}

```
simcrux [config.yaml] [options]
```

The same flags are accepted by two different executables, and which one you
want depends on whether a display exists:

- **The desktop app's command line.** Any invocation that is not one of the
  headless flows below opens the GUI. Useful for "open this project and show
  me", and for `--ci` on a machine that has the app installed. It is the only
  executable that runs the `--fail-on-regression` gate (on macOS,
  `SimCrux.app/Contents/MacOS/SimCrux`).
- **The standalone `simcrux` binary.** From 1.1 it ships with every release:
  `brew install ferrite-engineering/tap/simcrux-cli` on macOS (Apple silicon)
  and Linux, or the `simcrux-cli-<version>-<platform>` archive (`.zip` on
  macOS and Windows, `.tar.gz` on Linux) from the release's download prefix,
  one executable plus the licence; `simcrux --version` prints the version it
  is. It can also be built from `bin/simcrux.dart` in the open-source tree
  with `tool/build_cli.sh` (`dart build cli`), landing at
  `build/cli/bundle/bin/simcrux`. No window, no display server, no Flutter
  engine. It handles `--ci`, `--import-fusesoc`, the two RISC-V import
  subcommands, `export-dashboard` and `license`, and from 1.2 `import-sby`,
  `import-eqy` and the `flow` family. It does not carry the
  regression comparison engine, so it refuses `--fail-on-regression` with
  exit `2`.

!!! tip "It refuses to pretend"
    An invocation of the standalone binary that selects none of the headless
    flows — a bare project path, or no arguments at all — prints the usage block
    and exits `2` rather than reporting a run that never happened. And the
    standalone binary **never transmits telemetry**, under any setting.

When the desktop app's own executable runs `--ci` or `export-dashboard`, it
records anonymous usage counters only if usage statistics were turned on in that
app — it never asks, and a machine where the app has never been opened sends
nothing (see
[Updates, usage statistics & issue reporting](integrations/updates-and-feedback.md#usage-statistics)).

## Arguments {#arguments}

| Flag | What it does |
|---|---|
| `<config.yaml>` (positional) | Path to the `simcrux.yaml` project file. The desktop app also accepts a [`<design>.crux-project` manifest](projects-and-simulators.md#crux-project), or a design directory holding exactly one, and opens the config the manifest names. Omit it and the desktop app opens the start screen. The GUI opens one tab per positional path; `--ci` uses only the first, and needs the `simcrux.yaml` itself. |
| `--ci` | Run non-interactively. The process exit code reflects the regression outcome. |
| `--export <fmt>=<path>` | Write the run to `<path>`, creating its directory if needed. May be given more than once. Formats: `junit`, `json`, `csv`, `html`; any other format is a usage error (exit `2`) before anything runs. The summary line is printed first, on stdout; each `wrote <fmt> → <path>` confirmation goes to stderr. A target that cannot be written is reported on stderr, the others are still written, and the run exits `2`. |
| `--json` | Print the totals as one JSON document on stdout, and nothing else there: export confirmations, warnings and errors go to stderr, so `--json \| jq .totals` parses whatever other flags are given. Implies `--ci`. |
| `--filter <pattern>` / `-f` | Literal substring match against the test id (`suite/test`); non-matching tests are skipped. Not a glob. **`--ci` only**; ignored in the GUI. |
| `--max-parallel <n>` / `-j` | Concurrency for the run. Must be a positive integer; defaults to `4`. **`--ci` only** — the GUI always uses 4. |
| `--fail-threshold <n>` | In `--ci` mode, exit `1` when the number of failed, timed-out or `unknown` tests is `>= n`. Defaults to `1`, or to the organization's [failure ceiling](administration.md#ci-ceiling) where one is set; a value typed here always wins. |
| `--fail-on-vacuous` | In `--ci` mode, also count tests classified `vacuous` (the testbench completed without exercising its checks) toward `--fail-threshold`. |
| `--keep-failures <n>` | From 1.2. In `--ci` mode, how many failing tests' [work folders](#work-folders) to keep across runs. Defaults to `50`; a non-negative integer. The run's own failure folders are never removed and count toward `n`, so its results never point at a deleted counterexample; earlier runs' folders are removed oldest first, and each removal is listed on stderr. |
| `--baseline <path>` | A `results.ndjson` from an earlier `--ci` run, used by `--fail-on-regression`. |
| `--allow-project-tooling` | Honour the project file's tooling keys: `simulators.<id>.path` and `.env`; the `riscv` `target` / `riscof` / `compile` / `formal` `command:` lists; and the `riscv` executable paths `reference.path`, `toolchain.path`, `toolchain.prefix`, `riscof.binary` and `formal.sby_binary`. From 1.2 it also covers the [`formal:` block](formal.md#tooling)'s `command`, `extra_args`, `sby_binary`, `eqy_binary`, `ghdl_binary` and `tools`, and each [`flow:` entry](flow.md#flow-block)'s `launcher`, `librelane_binary`, `docker_image`, `fusesoc` (with `fusesoc.binary`), `extra_args` and `handoff`. Each of them chooses what this run executes or its environment, so without this flag a `command:` fails the load and the others are dropped with an advisory. It also lets `output.results_path` and `output.summary_path` point outside the project directory; without it such a path fails the load, because a `--ci` run creates and truncates those files. It also lets `simulators.<id>.options` values that `make` would expand (`$(`, `${`, a backtick), Verilator `options.args` that name a build tool (`-CFLAGS`, `-LDFLAGS`, `-MAKEFLAGS`, `--compiler`, `--make`, `--Mdir`, `--prefix`, `-o`, `-f`, `-F`) and cocotb `top` / `parameters` values with make expansions through; without it the options are dropped with an advisory and such a cocotb test does not load. Pass it only for project files you trust. The app takes the same decision in **Settings → Engines → Let project files choose simulator binaries and environment** (from 1.2; earlier versions call the category **Simulators**). See [Projects and simulators](projects-and-simulators.md#schema). |
| `--license-file <path>` | In `--ci` mode, the SimCrux license file to run under. See [License tier in CI](#license-in-ci). |
| `--fail-on-regression` <span class="tier tier-pro">Pro</span> | Exit `1` when a test that passed in `--baseline` now fails. Exit `2`, with an `error: regression gate:` line on stderr, when the `--baseline` file is missing, unreadable or holds no results, or when the run's license does not include the gate (see [License tier in CI](#license-in-ci)). Only the desktop app's executable, and from 1.2 `simcrux-pro`, run the gate, with `--ci` and a Pro, EDU or Enterprise license. The standalone `simcrux` binary and open-source builds refuse it: exit `2` and an `error: regression gate:` line naming the desktop executable. Without `--baseline` it warns and leaves the exit code unchanged. See [Baseline comparison](baselines-ci-exports.md#baseline). |
| `--import-fusesoc <core>` | Convert a FuseSoC `.core` file to `<name>.simcrux.yaml` next to it, print the output path and any warnings on stdout, and exit `0` (or `2` on failure). See [Importing FuseSoC files](fusesoc-import.md). |
| `--session <path>` | Opens one extra tab whose config path is the given path. No session document is parsed — this is not a session restore. |
| `--workspace <path>` | Load a saved workspace before opening positional projects. GUI only. |
| `--no-restore` | GUI only: launch without reopening the previous session's tabs. Nothing is deleted — try this first if the app hangs on startup. |
| `--reset` | GUI only: delete the saved workspace and per-tab session state, then launch empty. Settings and recent files are kept. |
| `--reset-telemetry-consent` | Testing aid: forget this installation's usage-statistics answer so the first-launch question appears again. The desktop app acts on it at startup whatever else is on the command line, `--ci` included; the standalone `simcrux` binary accepts it and does nothing. |
| `--reset-eula` | Testing aid: forget this installation's acceptance of the license agreement so it is presented again at launch. The desktop app acts on it at startup whatever else is on the command line, `--ci` included; the standalone `simcrux` binary accepts it and does nothing. Given together with `--reset-telemetry-consent`, the agreement appears first, then the usage-statistics question. |
| `--help` / `-h` | Print the full usage block and exit. |
| `--version` | Print `simcrux <version>` and exit `0`, before anything else runs. |

An unrecognized argument prints the error and the usage block on stderr and
exits `2` from either executable — the desktop app does not open a window for
it. A headless invocation of the desktop app (`--ci`, `--help`, the imports,
`export-dashboard`) exits as soon as it finishes.

## Work folders {#work-folders}

Each test runs in its own folder, `<scratch>/runs/<run_id>/<test>/`, in
SimCrux's own scratch directory:

- **Linux:** `$XDG_CACHE_HOME/simcrux`, or `~/.cache/simcrux` when
  `XDG_CACHE_HOME` is unset. Never the shared `/tmp`, where another user of
  the machine could make the folder first.
- **macOS:** `simcrux` in the per-user temporary directory (`$TMPDIR`).
- **Windows:** `simcrux` in `%TEMP%`.

SimCrux makes the `simcrux` folder readable by you alone, and refuses to use one
that is a symbolic link, that other users can write, or that belongs to another
user.
The simulator's or prover's logs, the waveform and, for a formal check, the
SymbiYosys work directory with its counterexample trace are written there, and
the `waveform_path` in the results points into it.

- **A passing test's folder is deleted** when the test finishes. (In the
  desktop app its waveform is first moved to a separate archive so it can still
  be opened.) So a passing formal check keeps no work folder to look at later.
- **A failing test's folder is kept**, across runs, up to a cap: the newest 50
  failure folders and 2 GiB in all, by default. `--keep-failures <n>` changes
  the count for a `--ci` run. The run that just finished never loses a folder
  to the cap: its failures count toward it, and older runs' folders are removed
  oldest first. A `--ci` run lists every folder it removed on stderr.
- **To keep a folder for good**, put an empty file named `.simcrux-keep` in it,
  or in the `runs/<run_id>/` folder above it to keep the whole run.
- **To put the folders somewhere else**, set `XDG_CACHE_HOME` for the run on
  Linux, for example `XDG_CACHE_HOME=/scratch/me simcrux project.yaml --ci`
  (`TMPDIR` on macOS, `TEMP` on Windows). There is no flag or project key for
  the location.

## License tier in CI {#license-in-ci}

A CI agent has no license stored by the SimCrux app, so `--ci` (from either
executable) looks for one in this order and uses the first it finds:

1. `--license-file <path>`
2. the file named by the `SIMCRUX_LICENSE_FILE` environment variable
3. the `license` key of your organization's
   [policy file](https://edacrux.app/policy-reference) — an inline key or a
   file path

The license is checked offline, exactly as the app checks it, with no network
call. The run prints one `simcrux: license: …` line on stderr saying which tier
it runs at and where the license came from. That tier decides what the
project loads with — Pro, EDU and Enterprise expand `seeds:` and `parameters:`
sweeps, Open Core does not — and whether `--fail-on-regression` runs: an Open
Core run that asks for it prints `error: regression gate: …` naming the tier it
resolved and exits `2` rather than passing a gate it did not evaluate. With no license anywhere, the run is Open Core and
prints nothing.

- A `--license-file` or `SIMCRUX_LICENSE_FILE` that cannot be read, or is empty,
  is an error: the run exits `2` before it starts, because a job that asked for
  a license should not quietly run without one.
- A license that is not valid for SimCrux, or has expired past its grace
  period, runs as Open Core and says why. An expired license keeps its tier
  during the grace period.
- A **machine file** — it starts `-----BEGIN MACHINE FILE-----`, and it is what
  offline activation issues — works only on the machine it was issued for.
  Anywhere else the run is Open Core and the license line says
  `wrongMachine`. A license key or a license file names no machine and works
  on any agent.

`--ci` learns which machine it is on from a fingerprint file,
`crux/license/install.fingerprint` in your user account's application-data
folder: `~/Library/Application Support` on macOS, `%LOCALAPPDATA%` on Windows,
and `$XDG_DATA_HOME` (default `~/.local/share`) on Linux. Every EDACrux
product on the computer, and its command-line tool, reads and writes that one
file, which is how a license counts a computer running several products as one
machine. It never reads the system keychain, so nothing on a build agent waits
on a prompt. On a workstation where you use the app, a machine file you
imported under **Settings → License** therefore also licenses `--ci` runs by
the same user. Earlier SimCrux releases kept the fingerprint in
`crux/license/simcrux.fingerprint` (under `%APPDATA%` on Windows); the first
run that finds no shared file adopts that value, so a machine file issued for
it keeps working. From 1.1, `simcrux license fingerprint` prints that
fingerprint and `simcrux license request --out <file>` writes the offline
activation request for it, both without the app and from either executable,
so a dedicated build agent can be issued a machine file too (see
[Subcommands](#subcommands)). A license key or a license file is still the
simpler choice for an agent, since neither names a machine.

```bash
# Store the license file as a CI secret file, then:
simcrux simcrux.yaml --ci --license-file "$SIMCRUX_LICENSE"
```

`type: use` detectors come from the app's **Settings > Detectors** library,
which `--ci` does not read: a project that references one fails to load with
exit `2` and a message naming the detector. Spell detectors out in
`simcrux.yaml` for anything CI runs.

## Exit codes {#exit-codes}

| Code | Meaning |
|---|---|
| `0` | All tests passed, or failures stayed below `--fail-threshold`. |
| `1` | At least `--fail-threshold` tests failed, timed out or ended `unknown` (plus `vacuous` ones under `--fail-on-vacuous`), or `--fail-on-regression` found a new failure. |
| `2` | SimCrux could not do what was asked: a usage error, a `simcrux.yaml` that fails to load, an import or export that could not be written, a `--fail-on-regression` baseline that could not be read, a license that does not include the regression gate, or a build without the regression comparison engine (the standalone binary), a test that was scheduled but never reported a result (stderr names it), or an unexpected error in the runner. |
| `3` | From 1.2, <span class="tier tier-enterprise">Enterprise</span>: an organization's threshold for implementation runs failed. See below. |

From 1.2 a `3` is possible when an organization's signed policy sets thresholds
for implementation runs and one of them fails: the desktop app's `--ci` returns
it over a run whose own code was `0` or `1`, and a `2` always stands over it.
See [Organization thresholds](flow-ci.md#org). The `simcrux flow` subcommands
have [their own table](flow-ci.md#exit-codes) and exit `64` for a bad command
line, where everything above keeps `2`. The standalone `simcrux` binary never
exits `3`.

A test ends `unknown` when SimCrux could not decide its outcome — for example
when its simulator binary could not be started, or no driver is registered for
its simulator id — so it always counts against the threshold.

## Examples {#examples}

```bash
# Open a project in the desktop app (the run starts when you press Run Regression)
simcrux my_project/simcrux.yaml

# Headless, with a JUnit report and an HTML dashboard; fail on any failure
simcrux my_project/simcrux.yaml --ci \
  --export junit=results/report.xml \
  --export html=results/dashboard.html

# Tolerate up to two known-flaky failures
simcrux my_project/simcrux.yaml --ci --fail-threshold 3

# Only the AXI4-Lite suite
simcrux my_project/simcrux.yaml --ci --filter axi4lite/

# JSON summary for downstream tooling
simcrux my_project/simcrux.yaml --json
# {"totals":{"pass":42,"fail":3}}

# Gate on new failures against a baseline (Pro): the desktop app's executable
/Applications/SimCrux.app/Contents/MacOS/SimCrux my_project/simcrux.yaml --ci \
  --license-file "$SIMCRUX_LICENSE" \
  --baseline baseline/results.ndjson --fail-on-regression
```

The regression gate runs only from the desktop app's executable. On Linux that
executable needs a display; see
[Which executable runs the gate](baselines-ci-exports.md#gate-executable).

## Subcommands {#subcommands}

A subcommand word must come **first**, and everything after it belongs to that
subcommand — the flags above are not available alongside one. Each accepts its
own `--help`.

| Subcommand | What it does |
|---|---|
| `simcrux export-dashboard <out-dir>` | Write a self-contained static results dashboard you can serve from any static host. |
| `simcrux import-riscv-arch-test <suite-path>` | Import a RISC-V architectural-test suite into a SimCrux project. |
| `simcrux import-riscv-formal <checks-path>` | Import a `riscv-formal` check set. |
| `simcrux import-sby <file.sby\|dir>` | From 1.2. Import a SymbiYosys job file, or every one in a directory, as one test per task. See [below](#import-sby). |
| `simcrux import-eqy <file.eqy>` | From 1.2. Import an EQY file as one test. See [below](#import-eqy). |
| `simcrux flow run\|ingest\|gate\|export` | From 1.2. Run, read, gate and export implementation runs. See [CI gate](flow-ci.md). |
| `simcrux flow gls <run-dir>` | From 1.2. Rerun a LibreLane run's tests against its gate-level netlist, functional simulation under Icarus. Exit codes `0`, `1`, `2`, `64`, `65`. See [Gate-level simulation](flow-gate-level.md#cli). |
| `simcrux-pro flow gls --sdf <corner> <run-dir>` | <span class="tier tier-pro">Pro</span> From 1.2. The same, with the delays of the run's SDF file and no timing checks; exit `77` without a Pro licence. See [Delay-annotated simulation](flow-gate-level.md#sdf). |
| `simcrux license fingerprint` | Print this install's machine fingerprint, the value a machine file is issued for. From 1.1. |
| `simcrux license request --out <file>` | Write an offline activation request for this install to `<file>`, as **Settings → License** would, without the app. From 1.1. |

!!! note "There is no `run` subcommand"
    The project path is a positional argument, not something you run a verb
    against — `simcrux simcrux.yaml --ci`, not `simcrux run --ci`. A word that is
    not one of the subcommands above is treated as a config path.

### `simcrux export-dashboard <out-dir>` {#export-dashboard}

Writes a self-contained dashboard bundle into `<out-dir>`:

- `simcrux-results.json` — copied verbatim from `--results <path>` if that file
  is already the consolidated form, or synthesized from a streaming
  `results.ndjson` otherwise.
- The contents of `--web-bundle <dir>` (typically `build/web/` from
  `flutter build web --target lib/main_web.dart`) copied alongside when
  supplied.

| Flag | Description |
|---|---|
| `--results <path>` | Source results file: a consolidated `simcrux-results.json` or a streaming `results.ndjson`. Defaults to `results.ndjson` in the current directory — `--ci` writes it next to `simcrux.yaml`, so pass `--results` when you run from elsewhere. A crash-truncated NDJSON file is repaired in place first. |
| `--web-bundle <dir>` | Pre-built Flutter web bundle. When provided its contents are copied alongside the JSON. |

```bash
# In a SimCrux source checkout: build the web viewer once.
flutter build web --target lib/main_web.dart --release

# In your project:
simcrux simcrux.yaml --ci
simcrux export-dashboard ./out --web-bundle /path/to/simcrux/build/web

# Serve ./out from any static host — GitHub Pages, S3, internal nginx.
```

See [The web dashboard](web-mode.md) for what the viewer shows and
[Publishing the results dashboard](ci-integration.md) for full CI recipes.

### `simcrux import-riscv-arch-test <suite-path>` {#import-riscv-arch-test}

Enumerates a [`riscv-arch-test`][arch-test] checkout into **one SimCrux test per
architectural test** and writes an inspectable `simcrux.yaml` you own. Nothing
is compiled, elaborated or run — the importer reads the directory layout and the
`.S` file names and exits.

SimCrux enumerates up front because one test declaration yields exactly one
result row. RISCOF emits *N* results per invocation, so the mismatch has to be
resolved before the scheduler — and resolving it in a file you can read, diff
and commit beats hiding it inside a driver where a mis-scanned directory is
invisible.

| Flag | Description |
|---|---|
| `--out <path>` / `-o` | Where to write the generated project file. Defaults to `./simcrux.yaml` — never inside the scanned checkout. |
| `--mode <normal\|demo>` | `normal` (default) enumerates a real checkout; `demo` enumerates a corpus of pre-captured signature pairs and emits `mode: demo`, which spawns nothing. |
| `--extensions <I,M,C>` | Comma-separated extension directories to import. Case-insensitive. Default: everything found. |
| `--target-command <cmd>` | **Required** for a config that loads in `--mode normal`: the command that runs *your* core for one architectural test. Quoted as one string and split the way a shell splits it. Use the `{elf}` and `{signature}` placeholders. The emitted file therefore carries a `command:`, so opening it needs **Settings → Engines → Let project files choose simulator binaries and environment** (**Simulators** before 1.2), and running it headless needs `--allow-project-tooling`. The importer prints a reminder. |
| `--isa <string>` | ISA string recorded once under `defaults.riscv.isa` and echoed onto every result. |
| `--toolchain-prefix <prefix>` | Cross-toolchain prefix, e.g. `riscv64-unknown-elf-`. Like `--toolchain-path` and `--reference-path`, it names a program SimCrux runs, so the loader ignores it until you allow project tooling. |
| `--toolchain-path <dir>` | Directory containing the cross-toolchain binaries. |
| `--reference-model <model>` | Reference model producing the golden signature: `spike` or `sail`. |
| `--reference-path <path>` | Path to the reference-model binary. |
| `--word-size <bytes>` | Bytes per signature word. Turns the comparison's word offset into the byte offset of the divergent instruction. |

```bash
simcrux import-riscv-arch-test ~/src/riscv-arch-test \
  --extensions I,M,C \
  --isa rv32imc_zicsr_zifencei \
  --toolchain-prefix riscv64-unknown-elf- \
  --reference-model spike \
  --word-size 4 \
  --target-command './my_core --elf {elf} --signature {signature}'

simcrux ./simcrux.yaml --ci --export junit=arch-test.xml
```

`--target-command` is the one input the importer cannot derive from a checkout,
and the loader requires it in `mode: normal`. Omit it and you still get a file —
with a `missing_target_command` warning in its header comment and a loader error
naming the key — because a config that looks fine and cannot run is worse than
one that says what is missing.

### `simcrux import-riscv-formal <checks-path>` {#import-riscv-formal}

Enumerates the `.sby` job files [riscv-formal][rf]'s `checks/genchecks.py` wrote
into **one SimCrux test per bounded proof**. Point it at the generated `checks/`
directory (or at the core directory containing it).

`make -C checks` runs dozens of independent `sby` jobs, and a single invocation
would report one row that either passed or failed for an hour, with no per-proof
timeout, cancellation or progress.

| Flag | Description |
|---|---|
| `--out <path>` / `-o` | Where to write the generated project file. Defaults to `./simcrux.yaml`. |
| `--mode <normal\|demo>` | `demo` enumerates a corpus of pre-captured SymbiYosys outputs instead of a real check set. |
| `--groups <insn,reg>` | Comma-separated property groups to import (`insn`, `reg`, `pc_fwd`, …). Case-insensitive. Default: everything found. |
| `--isa <string>` | ISA string recorded once under `defaults.riscv.isa`. |
| `--sby-binary <path>` | Path to the SymbiYosys binary, when `sby` is not on `PATH`. It names a program SimCrux runs, so the loader ignores it (and uses `sby` from `PATH`) until you allow project tooling; the importer prints a reminder. |

```bash
python3 checks/genchecks.py            # riscv-formal's own generator
simcrux import-riscv-formal ./checks --isa rv32imc_zicsr --groups insn,reg
simcrux ./simcrux.yaml --ci
```

A `.sby` that declares a `[tasks]` section becomes **one test per task**, with a
`multi_task_sby` warning saying so — one `sby` invocation over several tasks
prints several `DONE (…)` lines, which would collapse into a single result row.

The keys the written file uses, the metrics each row records and what a check
set needs installed are in
[The `riscv.formal:` block](projects-and-simulators.md#riscv-formal).

### Both imports, from the app {#imports-from-the-app}

The same two importers are on the File menu:

- **File → Import RISC-V Architectural Tests…**
- **File → Import riscv-formal Checks…**

Each asks for the source **directory**, then for where to save the generated
`simcrux.yaml`, then opens it as a new tab. Neither the app nor the CLI writes
into the checkout you scanned — that is somebody else's git repository. The app
runs the importers with no options, so a `riscv-arch-test` import saved this way
carries the `missing_target_command` warning until you add
`riscv.target.command` by hand.

### `simcrux import-sby <file.sby|dir>` {#import-sby}

From 1.2. Reads a SymbiYosys job file, or every `.sby` file directly inside a
directory, into **one SimCrux test per task** in its `[tasks]` section (one test
for a file with none) and writes a `simcrux.yaml` you own. Nothing is run. See
[Formal verification](formal.md#import).

| Flag | Description |
|---|---|
| `--task <name>` | Import only this task. Repeatable, or a comma-separated list. A task that only some of a directory's job files declare imports those files and skips the rest; one that none declares is an error that lists the declared tasks. |
| `--out <path>` / `-o` | Where to write the project file. Defaults to `./simcrux.yaml`. |
| `--sby-binary <path>` | The `sby` to run, when it is not on `PATH`. It names a program SimCrux runs, so the loader ignores it until you [allow project tooling](formal.md#tooling); the importer prints a reminder. |

```bash
simcrux import-sby formal/ --task prove --out simcrux.yaml
simcrux simcrux.yaml --ci
```

A good import prints `simcrux: wrote <path> (N tests from M job files: ...)` on
stdout, with any warnings on stderr. A job file that reads the design with
assertions turned off still imports, with an `assertions_disabled` warning in the
file's header. A usage mistake, a path with no job file, or an unknown task prints
the reason on stderr and exits `2`, like every `import-*` subcommand; `-h` or
`--help` anywhere prints the usage and exits `0` before any file is read.

### `simcrux import-eqy <file.eqy>` {#import-eqy}

From 1.2. Reads an EQY file into one test, with the same contract as `import-sby`.

| Flag | Description |
|---|---|
| `--out <path>` / `-o` | Where to write the project file. Defaults to `./simcrux.yaml`. |
| `--eqy-binary <path>` | The `eqy` to run, when it is not on `PATH`. Ignored until you [allow project tooling](formal.md#tooling). |

A file with no `[gold]` or `[gate]` section is refused. One with a `ghdl` line
SimCrux cannot lower to Verilog, or with no strategy, imports with a warning in the
file's header. Exit codes are those of `import-sby`.

### The formal imports, from the app {#import-formal}

**File → Import Formal Project…** does the same from the app and takes an `.sby`
or an `.eqy` file; see [Formal verification](formal.md#import).

## FuseSoC and Edalize {#fusesoc}

The standalone binary exists in large part for this: an Edalize flow node runs
without a window. `--import-fusesoc` turns a `.core` file into a SimCrux project
next to it, so a FuseSoC-managed design goes from core file to regression report
without hand-editing:

```bash
# Convert the core file, then run what it produced
simcrux --import-fusesoc cores/servant/servant.core
simcrux cores/servant/servant.simcrux.yaml --ci --export junit=report.xml
```

LintCrux's half of the same integration consumes the fully resolved EDAM that
FuseSoC generates — see
[the LintCrux documentation](https://docs.lintcrux.app/projects-and-engines).

!!! note "Related"
    For baselines, export formats and a worked CI pipeline, see
    [Baselines, CI & exports](baselines-ci-exports.md). For what each tier
    includes, see [Tiers & licensing](licensing.md).

[arch-test]: https://github.com/riscv-non-isa/riscv-arch-test
[rf]: https://github.com/YosysHQ/riscv-formal
