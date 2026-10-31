# Formal verification, from 1.2

From SimCrux 1.2, a formal job runs like any other test. SimCrux runs
[SymbiYosys](https://github.com/YosysHQ/SymbiYosys) (`sby`) for property
checks and [EQY](https://github.com/YosysHQ/eqy) for equivalence checks, reads
what the tool wrote, and puts one row in the results table for each job. The
row says what the tool established in plain words: **Proved**, **Counterexample**,
**Inconclusive** or **Did not run**. A counterexample opens in
[WaveCrux](https://docs.wavecrux.app/automation-and-collaboration#cxp-formal)
at the step that failed.

Everything on this page is open core and free, in every tier, except the
analysis screens in [Pro analysis](#pro). The RISC-V formal track from earlier
releases keeps working and uses the same engine and the same wording.

## Set up the tools {#tools}

SimCrux does not ship the formal tools. The simplest install is the
[OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build), which carries
Yosys, SymbiYosys, EQY, the yosys-slang plugin and the solvers together.

Open **Settings → Engines → Formal tools** (from 1.2; earlier versions call the
category **Simulators**), set the path of `sby` and, for equivalence checks,
`eqy`, then press **Check formal tools**. The check reports each tool it found
and its version: `sby`, `eqy`, `yosys` (with whether that build includes the
Verific frontend), the yosys-slang plugin, `yices-smt2`, `boolector`,
`bitwuzla`, `z3`, `yosys-abc` and `rIC3`. Every run needs `sby` and `yosys`; the
others matter only to the job files that name them. SimCrux looks for every
other tool beside the `sby` you set, which is how an OSS CAD Suite is laid out,
and then on `PATH`.

- **macOS.** An app opened from the Finder does not see your shell's `PATH`.
  Set the path of `sby` here and the other tools are found beside it.
- **Windows.** The OSS CAD Suite has a Windows build, and running the formal
  tools under WSL2 is also common.
- **Versions.** The `sby` output was measured on SymbiYosys 0.68, 0.69 and 0.70.
  A job run by an older `sby` that does not accept `--live` ends as
  **Did not run**, never as a pass.
- **SymbiYosys from source** needs the Python package `click`
  (`pip install click`); without it `sby` stops with a Python traceback.
- **`read_slang`.** A job file whose script reads the design with `read_slang`
  needs a Yosys with the yosys-slang frontend. The OSS CAD Suite has it;
  Homebrew's `yosys` does not, and a separate yosys-slang build is loaded with
  `yosys -m slang.so`. Without it the job stops in SymbiYosys's `base` step with
  `ERROR: No such command: read_slang`, and the row says so.

A job file that needs a tool from somewhere else names it with
[`formal.tools`](#config), which needs project tooling to be allowed.

## Import a job file {#import}

A project is a `simcrux.yaml` you own. SimCrux writes the first one for you from
a SymbiYosys job file or an EQY file, and runs nothing while it does.

- **In the app:** **File → Import Formal Project…**. Choose the job file
  (`.sby` or `.eqy`), check where the project file goes (by default
  `simcrux.yaml` beside the job file), and tick the tasks to import. An `.sby`
  file becomes **one test per task** named in its `[tasks]` section, or one test
  for a file with none. An `.eqy` file becomes one test. **Import** writes the
  file and opens it as a tab.
- **From a terminal:** `simcrux import-sby <file.sby|dir>` and
  `simcrux import-eqy <file.eqy>`. See [Command line](cli.md#import-formal).
- **From a design manifest:** a [`<design>.crux-project`](projects-and-simulators.md#crux-project)
  may name a `.sby` or `.eqy` file under `artifacts: formal:`. Opening the
  manifest does not import it; use **File → Import Formal Project…**.

The written file selects the `sby` or `eqy` simulator and a detector that looks
for the tool's own pass line. If the job file reads the design with assertions
turned off, the import still happens and a warning at the top of the project
file says so.

## What a formal test looks like {#config}

```yaml
version: '1'
suites:
  formal:
    tests:
      - name: prove_bug
        top: handshake
        simulator: sby
        formal:
          sby_file: formal/handshake.sby   # relative to this file
          task: prove_bug                  # the [tasks] name
      - name: alu
        top: alu
        simulator: eqy
        formal:
          eqy_file: equiv/alu.eqy
```

The `formal:` block inherits like `riscv:` does: an included file's
`defaults.formal`, the project's `defaults.formal`, the suite's `formal:`, then
the test's. Any other key is an error that names the line.

| Key | Used by | Meaning |
|---|---|---|
| `sby_file` | `sby` | The SymbiYosys job file. Required. May not start with `-`. |
| `task` | `sby` | The `[tasks]` name. Names the task directory, so it must be one plain name. |
| `eqy_file` | `eqy` | The EQY file. Required. May not start with `-`. |
| `mode` | `sby` | `normal` (default) or `demo`, which replays captured output and runs nothing. |
| `demo_outputs`, `demo_case` | `sby` | The directory and case a `demo` run replays. |
| `sby_binary`, `eqy_binary`, `ghdl_binary` | `sby`, `eqy` | The executable to run. Needs [project tooling](#tooling). |
| `tools.<tool>` | `sby`, `eqy` | A solver or helper path passed as `--<tool> <path>`: `yosys`, `abc`, `smtbmc`, `witness`, `suprove`, `aigbmc`, `avy`, `rIC3`, `btormc`, `itp-bmc`, `pono` for `sby`; a subset for `eqy`. Needs [project tooling](#tooling). |
| `command`, `extra_args` | `sby`, `eqy` | A whole command line, or extra arguments. Need [project tooling](#tooling). |

SimCrux picks the work directory itself, because both tools delete the
directory they are given. For that reason `extra_args` may never pass `-d`,
`--prefix`, `-f`, `-b`, `-t`, `-T`, `--setup` or `--statusreset` to `sby`, nor
the matching options of `eqy`, whether or not project tooling is allowed.

### Keys that choose a program {#tooling}

`formal.command`, `formal.extra_args`, `formal.sby_binary`, `formal.eqy_binary`,
`formal.ghdl_binary` and every `formal.tools.<tool>` decide what a run executes.
Like the other keys listed under
[Projects and simulators](projects-and-simulators.md#schema), they are honored
only when you allow project tooling:

| Keys | Without permission |
|---|---|
| `formal.command`, `formal.extra_args` | The project does not load |
| `formal.sby_binary`, `formal.eqy_binary`, `formal.ghdl_binary`, `formal.tools.<tool>` | Ignored, with one advisory naming them; the conventional name is looked up on `PATH` |

In the app, turn on **Settings → Engines → Let project files choose simulator
binaries and environment**. Headless, pass `--allow-project-tooling`.

## Verdicts {#verdicts}

SimCrux reads the verdict from the tool's own log and status files and **never
from its exit code**. An exit `0` under any result but a pass is withheld from
the scheduler, and no detector can turn a result that is not a pass into one.
The results table has a **Verdict** column, blank for simulation rows, that says
what a result may claim.

| Bucket | What it means | Counts as in a regression |
|---|---|---|
| **Proved** | The property held. For a bounded check it held over the configured number of steps, and the row says so. | Pass |
| **Counterexample** | The tool found a trace that breaks the property. | Fail |
| **Inconclusive** | The tool learned nothing, or its own time or step budget ran out. Shown in a neutral colour, never error red. | Fail |
| **Did not run** | A tooling problem, or no result line at all. | Fail |

The words in the **Verdict** column:

| Result | Shown |
|---|---|
| A `prove` or `live` task passed | Proved |
| A `bmc` task passed with depth N | **Proved over N steps** |
| A task passed, its mode or depth not recorded | Proved over the configured bound |
| A `cover` task reached its target | Reached |
| A `cover` task did not reach it | Counterexample (the property **Not reached**) |
| A task passed and checked no property | Passed, no properties checked |
| The tool gave up or timed out | Inconclusive |
| An error, or no result line | Did not run |
| A result token this version cannot read | Unrecognized verdict |
| An equivalence check passed on every partition | Proved equivalent, all N partitions |
| An equivalence check did not prove every partition | Not proved equivalent, K of N partitions |

A bounded result is never worded as a bare proof: depth N means no violation
exists within N steps, and the depth shown is the bound you configured, never a
step count taken from an induction. A pass that checked nothing is shown as
such rather than as a proof. Sorting by **Verdict** puts counterexamples first
and simulation rows last.

When the task result and the per-property results disagree, the more
conservative one is kept on every surface. A task that passed while a property
did not is a failing row, and the row says that the two disagreed.

A **Counterexample** row carries the trace the tool wrote. **Debug in
WaveCrux** and **Cross-probe to** send it to WaveCrux (see
[Cross-probe](#cross-probe)).

### Properties {#properties}

Each property the tool reports is recorded on the row, keyed on where it is
written in the source (`file:line`), because a frontend that does not keep
labels gives its properties generated names. The record holds the property's
kind, location, status, label (when the frontend kept one), the step it failed
at, its trace, and the signals it reads. It appears in the JSON export
(`--export json=<path>`) as `formal.property.<n>.*` entries under the row's
`metrics`, and in the Pro [properties dashboard](#pro). The free results table
shows the row's verdict, and the inspector's **Formal result** section explains
a row that did not run, depends on state before the trace, or has partitions.

## Unsupported SVA {#sva}

Yosys and the yosys-slang plugin read immediate assertions and clocked boolean
`assert property`. They do not read temporal SVA: implications across cycles,
sequences, repetition and delays. A Yosys build that includes the Verific
frontend, such as Tabby CAD, does.

When a frontend refuses a construct, SimCrux never reports the property as
passed and never hides it. The row is **Did not run, unsupported SVA**, and the
inspector's **Formal result** section starts with the fact: the construct and
where it is, for example that `|=>` at `handshake.sv:42` is a temporal
implication. It then says why, that full support is in progress upstream,
that a Verific build accepts it, and what you can do: rewrite it as a clocked
boolean property with `$past`, or as an immediate assertion in an `always`
block. When Verific is present the diagnostic is suppressed, and the frontend is
recorded as `verific`.

Two related checks use the same row:

- **A dropped property.** If a task passes while the sources declare
  properties of the kind it checks and the elaborated design holds none, the
  row is **Did not run, property dropped**. Nothing was checked, so it is not a
  pass.
- **Assertions turned off by the project.** A job file that reads the design
  with `-noassert` (Yosys) or `--ignore-assertions` (yosys-slang) is recorded as
  "assertions disabled by the project". Your organization can forbid it with
  [`formalForbidAssertionOptOut`](administration.md#formal-policy).

### What each frontend accepts {#sva-table}

The table is generated from a measured probe matrix, not written by hand, and
it carries the date and the engine build it was measured on. Rows read
**Accepted** or **Refused** for each frontend; a different Yosys build can
answer differently.

--8<-- "sva-support-table.md"

## State from before the trace {#pretrace}

SystemVerilog's `$past(x, N)` reads values from up to N steps before the
current one. Near the start of a trace those steps are before the trace began,
and nothing constrains what the solver puts there. A `cover` can therefore be
"reached" at step 2 on a design where the signal it asks about never has that
value after reset, and nothing in the open-source tools says so.

SimCrux finds the `$past` registers that feed each property in the elaborated
design and compares their depth with the step the property fired at. A property
reported at step s samples the design one step earlier, so a chain of depth N
reads from before step 0 exactly when s is at most N. When that holds, the row
and the counterexample carry the marker **Depends on state before the trace
began** and the inspector explains it: the step, the depth of the chain, and the
property. The verdict stands. The marker is free and sits beside it.

The marker says the result may not happen on any real trace. It does not say
the property is wrong. Holding the property until the `$past` history is N real
steps deep removes the exposure; the Pro [analysis](#pro) suggests that guard.

## Properties that can never be enabled {#vacuity}

An assertion whose enable condition is never true passes without being checked.
For example, `assume (rst)` holds on every step and the assertion is written
`disable iff (rst)`. SimCrux evaluates each assertion's enable against the
design's unconditional assumptions while it looks for `$past` chains. When it
finds one, it records the assumption's `file:line` as
`formal.property.<n>.vacuous` (the word `const` for an enable that is constant
false). The verdict stays what `sby` said.

The free results table and the inspector do not show this. The value is in the
JSON export beside the other `formal.property.<n>.*` entries, and the Pro
[properties dashboard](#pro) explains it. The evaluation follows `$not`,
`$logic_not`, one-bit `$and`, `$or`, `$reduce_*` and `$mux`, and counts an
assumption only on the assertion's own clock. Anything else is treated as "may
be enabled", so a missing entry is not a statement that the property is
exercised.

## Equivalence checks with EQY {#eqy}

An `.eqy` file names a gold design and a gate design. EQY cuts them into
partitions at run time and proves each partition, so a partition is a child
of the one test, not a test of its own.

- **The row.** **Proved equivalent, all N partitions** only when every partition
  was proved. Otherwise **Not proved equivalent, K of N partitions**, where K is
  the number that was not, and the inspector says that the designs are not
  proved equivalent as a whole.
- **The partitions.** The inspector's **Formal result** section lists how many
  partitions were proved equivalent, then each one with its own result, the
  ones that need attention first (at most 20 are listed, and the rest are
  counted). A counterexample names its trace file.
- **Where the verdict comes from.** The run's `DONE` line, each partition's own
  status file, and the log's partition lines. Where they differ the more
  conservative one wins, and a partition with no status file did not run
  whatever the log says.
- **A correct netlist can fail at EQY's default settings.** EQY can lose a
  match point when synthesis restructures logic, and then reports a failing
  partition on a netlist that is equivalent. SimCrux shows that row as a
  failure, because it is what the tool reported. The Pro [analysis](#pro)
  diagnoses it and suggests a `[match]` edit.
- **VHDL.** SimCrux lowers a `ghdl` line in the gold or gate section with
  `ghdl --synth --out=verilog` before EQY runs, into a generated directory beside
  the work directory. It never loads the GHDL Yosys plugin. A `ghdl` line it
  cannot lower (an option other than `--std=`, no `-e <unit>`, or more than one
  command) refuses the run before it starts. From SimCrux 1.2 the time allowed
  for that step grows with the size of the VHDL files: ten minutes at least,
  then about four minutes for every 64 MB of source, up to twelve hours. Before
  1.2 it was ten minutes whatever the size.

## Cross-probe {#cross-probe}

Every send and receive below is free in every tier.

- **A counterexample lands on its step.** **Debug in WaveCrux**, the row menu's
  **Cross-probe to** and **Cross-probe Selection** (++cmd+shift+enter++ /
  ++ctrl+shift+enter++) send the trace together with the step the solver
  reported, counting the trace's initial state as step 0. From WaveCrux 1.2 the
  cursor lands there. The step is left out, never guessed, when no property
  states one and for a task that checks more than one clock. WaveCrux opens the
  trace either way. See
  [Receiving a formal trace](https://docs.wavecrux.app/automation-and-collaboration#cxp-formal).
- **One hand-off per failing partition.** For an equivalence check, the
  inspector offers **Debug `<partition>` in WaveCrux** for each partition that
  ended with a counterexample (at most 8). WaveCrux groups the gold and gate
  scopes as a pair, with the miter's comparison signals on top.
- **Show in NetCrux.** A row with a failing property offers it in the
  inspector. NetCrux selects the first signal the property reads and draws its
  fan-in. From NetCrux 1.2. See
  [Formal and implementation-flow results](https://docs.netcrux.app/integrations/cxp#formal-flow).
- **A peer's signal filters the rows.** When NetCrux or WaveCrux sends a signal
  that names its design, and the project has `sby` tests, the results table
  shows only the formal rows with a property that reads that signal. The filter
  bar shows it under **Cross-probe** as "Properties that read `<signal>`".
  Deselect it, or choose **Clear filters**, to bring every row back.

## In a pipeline {#ci}

A formal job runs under `simcrux --ci` like any test, with the exit codes on
[Command line & CI](cli.md#exit-codes). Every result but **Proved** (and a
`cover` that was **Reached**) is a failed test, so `--fail-threshold` counts
**Counterexample**, **Inconclusive** and **Did not run** alike. Read the verdict
column or the exports to tell them apart; a pipeline that should go red on an
inconclusive proof needs no extra flag. The exports (JSON, JUnit, CSV, HTML)
carry the formal rows. Headless runs need the tools on `PATH` or set with the
project tooling keys.

## Pro analysis {#pro}

<span class="tier tier-pro">Pro</span> The paid screens read the same data the
free row records and add nothing to the verdict:

- **View → Formal Properties…**: rollups by task, kind (assert, assume, cover)
  and bucket, with depth and wall time.
- **Proof history**: each property's result across runs. A regression is a
  verdict that stopped being Proved, or a proof time at least twice the previous
  run's and at least a second slower.
- **Vacuity and pre-trace analysis**: which properties never had their enable
  true, which `$past` read reached before step 0, and a suggested constraint.
- **Equivalence partition explorer**: the partitions and their match points, and
  for a failing partition a diagnosis (a match point restructured by synthesis,
  a genuine mismatch, or undetermined) with the `[match]` edit to try, as text to
  copy and never written to your file.

In an open core build the menu item stays enabled, badged, and answers that it
requires SimCrux Pro. An <span class="tier tier-enterprise">Enterprise</span>
policy file can set a floor for proofs; see
[Formal policy](administration.md#formal-policy).
