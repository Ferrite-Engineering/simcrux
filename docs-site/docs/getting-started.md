# Installation & first regression

SimCrux is a desktop application that orchestrates the simulators you already
have installed. There is no account to create, and the free
Open Core runner asks for no key; Pro and Enterprise features are what a
key unlocks ([Tiers & licensing](licensing.md)). This page covers getting the
app on each platform, pointing it at your simulator binaries, and running your
first regression end to end.

## Platforms {#platforms}

SimCrux is desktop-first. It runs natively on Linux, macOS and Windows —
wherever your simulators run.

| Platform | Versions | How you get it |
|---|---|---|
| Linux | x86_64 | AppImage or `.tar.gz` from the [downloads page](https://simcrux.app/download). |
| macOS | 12.0 (Monterey) or later, universal (Intel and Apple silicon) | Signed and notarized `.dmg` from the [downloads page](https://simcrux.app/download). |
| Windows | 10 / 11, x86_64 | Installer or portable `.zip` from the [downloads page](https://simcrux.app/download). |
| Web (read-only) | Any modern browser | The [web dashboard](web-mode.md) opens exported results. You cannot launch runs from it. |

SimCrux is localized in English, Simplified Chinese, Japanese and Korean. The
**Language** picker is in **Settings → Appearance**.

### Building from source {#from-source}

To build the open-core app yourself (Flutter stable; CI pins 3.47.3):

```bash
git clone https://github.com/Ferrite-Engineering/simcrux.git
cd simcrux
git submodule update --init --recursive   # crux-shared
flutter pub get
flutter run -d macos    # or -d linux, -d windows
```

The headless `simcrux` command-line binary used in CI is built separately with
`tool/build_cli.sh` — see [Command line & CI](cli.md).

## Supported simulators {#simulators}

**SimCrux does not bundle simulators** — it drives the ones on your machine. It
resolves `iverilog`, `vvp`, `verilator`, `ghdl` and `make` by name against your
`PATH`. On macOS it also searches `/opt/homebrew/bin` and `/usr/local/bin`, so a
Homebrew install is found even when the app is launched from Finder or the
Dock. A test selects its simulator with the `simulator:` key.

| Simulator | `simulator:` | What SimCrux runs | Notes |
|---|---|---|---|
| Icarus Verilog | `icarus` | `iverilog` + `vvp` | With a custom path, both are taken from that directory. |
| Verilator | `verilator` | `verilator` (and the C++ toolchain it builds with) | Warnings never fail the build; add flags with `options.args` — see [Verilator flags](projects-and-simulators.md#verilator). |
| GHDL | `ghdl` | `ghdl` | Any backend your GHDL build uses (mcode, LLVM or GCC). |
| Cocotb | `cocotb` | `make` in the test's working directory, with your cocotb testbench `Makefile` | Tested against cocotb 1.9 through 2.1. Cocotb 2.1 requires Python 3.9 or newer and no longer ships 32-bit builds. Cocotb wraps Icarus, Verilator or GHDL underneath. |

To pin a specific install on your machine, use **Settings → Simulators**: it
lists every simulator id with a **Binary path** field (leave it empty to use
`PATH`). It applies to runs started from the app. Give a directory for Icarus,
which runs both `iverilog` and `vvp` from it.

A project file can name a binary too, in its `simulators:` block:

```yaml
simulators:
  icarus:
    source: custom
    path: /opt/eda/iverilog/bin
```

That is a project file choosing which program SimCrux runs, so it is off until
you allow it. Until you turn on **Settings → Simulators → Let project files
choose simulator binaries and environment** (or pass `--allow-project-tooling`
to `simcrux --ci`), SimCrux ignores `path:` and `env:` with a load advisory and
uses your **Binary path** instead. Once allowed, a project entry with
`source: custom` and a `path:` wins over **Binary path**; an entry that only
sets `options:` still takes it. `simcrux --ci` never reads Settings, only the
project file and the flag. See
[the project-tooling note](projects-and-simulators.md#schema) for the full list
of gated keys.

For cocotb, `cocotb-config` and the Python environment it belongs to must be
visible to `make`. Launch SimCrux from a shell where that environment is
active. `simulators.cocotb.env` can set the variables instead, but it is gated
like `path:`: it is ignored until you allow project files to choose the
environment.

SimCrux does not drive vendor simulators (Vivado `xsim`, ModelSim/Questa, VCS,
Xcelium). <span class="tier tier-pro">Pro</span>
[custom driver plugins](projects-and-simulators.md#plugins) are the mechanism
for adding a simulator SimCrux does not ship; no vendor plugin is available.

## First launch {#first-launch}

With nothing open, SimCrux shows a start screen with your **Recent configs**
and three buttons: **Open Config…**, **Open Session…** and
**Open Workspace…**. The menu bar, command palette and Settings are all
reachable before any project is loaded, so you can set simulator paths first.
On the next launch SimCrux reopens the tabs you had open.

## Run your first regression {#first-regression}

A regression starts from a `simcrux.yaml` in your project. Here is a minimal
one with a single Icarus test:

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
    format: fst

suites:
  smoke:
    description: Trivial smoke suite.
    tests:
      - name: pass_basic
        top: tb_pass
        sources:
          - tb_pass.v
```

And the matching testbench:

```verilog
// tb_pass.v
module tb_pass;
  initial begin
    $display("TEST PASSED");
    $finish;
  end
endmodule
```

1. **Open the project.** On the start screen click **Open Config…** (or
   **File → Open Config…**, ++cmd+o++ / ++ctrl+o++) and pick the `simcrux.yaml`
   file. SimCrux opens it in a new tab and lists every suite and test in the
   **Tests** panel on the left. A file that fails to load shows the error, with
   file and line, in the tab instead. On macOS you can also drop the file on
   the SimCrux Dock icon, or open it from Finder with **Open With → SimCrux**
   (**File → Open With** or right-click). SimCrux opens it exactly as passing
   it on the command line would, and the same goes for `.yml`,
   `<design>.crux-project`, `.simcrux-session` and `.simcrux-workspace` files.

   Double-clicking a `.yaml`, a `.yml` or a `<design>.crux-project` opens
   whatever you have set for it: `.yaml` is not SimCrux's extension to own,
   and a design manifest belongs to the whole suite, so no EDACrux product
   claims it and macOS asks you which to use. To make double-click open SimCrux instead, select a
   `simcrux.yaml` (or a `.crux-project`) in Finder, press ++cmd+i++, and pick
   SimCrux under **Open with**, then **Change All…**. SimCrux's own `.simcrux-session` and
   `.simcrux-workspace` files open on a double-click without any of that.
2. **Run the regression.** Press ++f5++, or click the run button on the
   toolbar (**Tools → Run Regression**). Opening a config never starts a run on
   its own unless you turn on **Settings → General → Run the regression when a
   config is opened**.
3. **Watch results arrive.** Each test appears in the results table as it
   finishes. The status bar at the bottom of the window tracks the totals:
   **Total**, **Passed**, **Failed** and **Running**, plus **Skipped**,
   **Timed out** and **Error** when any occur.
4. **Open a result.** Click a row to show the test in the **Details** panel on
   the right. Click **Open full log** for the searchable Log Viewer, or — for a
   test that captured a waveform — **Debug in WaveCrux**.

Alternatively, run headlessly from the command line:

```bash
simcrux path/to/simcrux.yaml --ci \
  --export junit=report.xml \
  --export html=dashboard.html
echo "exit code: $?"   # 0 = all passed, non-zero otherwise
```

!!! tip "Already have a Makefile flow?"
    [Projects & simulators](projects-and-simulators.md) shows how filelists
    (`.f`), `defaults:` and `includes:` keep large configs short, and the
    [migration guides](migrating/index.md) map Makefile, VUnit and FuseSoC flows
    onto a `simcrux.yaml`.

## Staying up to date {#staying-up-to-date}

SimCrux checks a release manifest on launch, once a day while it is running,
and when you switch back to the app. When a newer version is out, a strip
appears above the app content — **View Changes** opens the changelog,
**Update Now** opens the download page in your browser, and **✕** dismisses it
for this session. There is no in-app download and no self-update: SimCrux tells
you, you decide.

Turn the automatic check off in **Settings → General → Automatically check for
updates**. You can always check by hand from **Help → Check for Updates** (on
macOS, in the SimCrux application menu), the command palette, or the About box;
the manual check runs even when the automatic one is off. The request is a
plain fetch of a static manifest and carries only the app name, its version and
your operating system. Details are on
[Updates, usage statistics & issue reporting](integrations/updates-and-feedback.md).

## Reporting issues {#reporting-issues}

The fastest path to a fix is the built-in issue
reporter: **Help → Submit Issue…**, the command palette
(++cmd+shift+p++ / ++ctrl+shift+p++), or the **Submit Issue…** button in the
About box. SimCrux assembles a diagnostic context for you — app version and
build, platform and OS, locale, counts describing the open project and run, and
a recent diagnostic log — with a live preview of exactly what will be included.
File paths, test names and log contents are deliberately left out. See
[Reporting issues](integrations/updates-and-feedback.md#reporting-issues).

!!! note "Next steps"
    With a regression run, take the tour of [the interface](interface.md), learn
    the full [project & simulator](projects-and-simulators.md) configuration, and
    read how [pass/fail detection](pass-fail-detection.md) works.
