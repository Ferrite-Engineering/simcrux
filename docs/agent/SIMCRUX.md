# SimCrux for coding agents

SimCrux runs simulation and formal regressions from a `simcrux.yaml` (Icarus,
Verilator, GHDL, cocotb, SymbiYosys and EQY tasks, the RISC-V suites) and
answers from the command line or over the Model Context Protocol. This file is
for an agent, and for the person who configures one: when to call SimCrux, how
to read what it returns, and how to cite it so a person can check the answer.

## Starting the server

```
simcrux mcp --root <project directory>
```

The server speaks MCP over stdin and stdout. Every path a tool receives must be
inside `--root` (the working directory when omitted). Before `run` starts, the
`simcrux.yaml` is read the way the run reads it, and every file it reads on the
way (included project files, `.f` filelists) and every file and directory it
names (sources, include directories, `.sby` and `.eqy` files, the RISC-V
corpora, flow configurations and constraints, where the results go) must be
inside the root too. A path outside it, a symbolic link that leads outside it,
or a network path is refused, and nothing is run. A source file's own
`` `include `` is read by the simulator, which the check does not see.

The server makes no network call of its own. Only `run` writes: exactly what
`simcrux --ci` writes for the same config, the `results.ndjson` and
`results.summary.json` where the config puts them, and the work folders of
failing tests in SimCrux's own scratch. A log is read only inside the root or
that scratch. The simulators are the ones on `PATH`.

The server offers no way to run what a project file names
(`--allow-project-tooling`), to write an export, to change how many failing
tests' folders are kept, or to move the gate (`--fail-threshold`,
`--fail-on-vacuous`): a person does those from the command line. A project
that needs project tooling fails to load, and the document names the flag.

SimCrux Pro's command line serves the same four tools with the same inputs,
and a fifth, `compare`. It starts the same way, `mcp --root <project
directory>`, and also takes `--license-file <path>`.

Under a Pro licence its `trend` also gives the test's flakiness class, and
`compare` compares a run with a baseline run. It reads the licence again on
every `trend` and `compare` call: the `--license-file` given, then the
`SIMCRUX_LICENSE_FILE` variable, then the organisation's policy file. Below
Pro, `trend` answers the history and says it left the class out, and
`compare` answers `licence_error` and compares nothing.

Each tool is also a command, with the same inputs as flags and the same output
with `--json`:

```
simcrux run simcrux.yaml --json
simcrux results results.ndjson --status fail --json
simcrux test results.ndjson alu/sub_fail --json
simcrux trend alu/sub_fail runs/*.ndjson --json
```

A tool's text is byte for byte what the command writes, so a script and an
agent read the same document. `simcrux --ci <config> --json` is a different,
older document (`{"totals": ...}`) and does not change.

## When to call it

- **Before you say that the tests pass.** Run the regression, and report the
  outcome and the totals the document gives.
- **After you change RTL or a testbench.** Run again; compare with an earlier
  run's `results.ndjson` through `results`, or follow one test through `trend`.
- **When a test fails.** `test` gives its failure message, the log line it came
  from, the end of its log, the seed and the parameters it ran with.
- **When a run was made elsewhere** (a CI job, a colleague). Read its
  `results.ndjson` with `results`; nothing is run again.
- **Before you say a change broke nothing** (SimCrux Pro). `compare` the new
  run's `results.ndjson` with a baseline run's: it names every test that
  passed in the baseline and does not pass now.

## The tools

| Tool | Returns | Limits |
|---|---|---|
| `run` | Runs the config and returns the run, its totals and each test: status, failure message, log, waveform, failures first | `limit`: default 100, at most 1000; `filter`: only tests whose id contains it; `max_parallel` |
| `results` | The same for a run already written, read from its `results.ndjson` | `limit` as `run`; `status`: only tests with these statuses |
| `test` | One test of a run: its row, `seed`, `parameters`, `kill_signal`, `first_failure` and the end of its log | `lines`: default 100, at most 1000, and at most 64 KiB |
| `trend` | One test's history across `results.ndjson` files, newest first: status and runtime in each; from SimCrux Pro under a Pro licence, its flakiness class | `runs`: at most 200 |
| `compare` | SimCrux Pro only. A run against a baseline run: tests newly failing, newly passing, slower or faster by 20% or more, added and removed, each cited | `baseline` and `results`: two `results.ndjson` files |

`run` is long. A client that sends a progress token gets
`notifications/progress` (tests finished of tests submitted), and cancelling the
call stops the run and kills its simulators; a cancelled call is not answered.
A SymbiYosys or EQY project imported with `simcrux import-sby` or
`simcrux import-eqy` runs as tests, one per task, so its results come through
`run`, `results` and `test`.

## Reading a document

Every answer is one JSON object with eight members, always present, in this
order:

| Member | Meaning |
|---|---|
| `schema_version` | `1` |
| `tool` | `{"name": "simcrux", "version": ...}` |
| `command` | `run`, `results`, `test`, `trend` or (SimCrux Pro) `compare` |
| `outcome` | `completed` or `failed_gate` when there is an answer; otherwise `usage_error`, `input_error`, `engine_error` or `licence_error` |
| `engines` | Empty: each test row names its `simulator` |
| `design` | `null` |
| `body` | The answer, or `null` when there is none |
| `diagnostics` | Errors that say why there is no answer or why the gate failed, and warnings that qualify an answer |

**The `outcome` is the authority.** The tool result's `isError` is true
exactly when there is no answer.

| Outcome | Exit code | Means |
|---|---|---|
| `completed` | 0 | Every test passed (a `vacuous` one too, and its row says `vacuous`) |
| `failed_gate` | 1 | A test is `fail`, `timeout` or `unknown`. **An `unknown` test is a failed test**: SimCrux could not tell whether it passed. For `compare`: a test that passed in the baseline does not pass in the run |
| `usage_error` | 64 | A bad input or a path outside the root; nothing ran |
| `input_error` | 65 | A config that does not load, a filter that selected no test, a file that is not a `results.ndjson`, a test the run does not have |
| `engine_error` | 3 | **No test produced a result** (each is `unknown`, `cancelled`, `skipped` or never ran its simulator), the run was cancelled, or a submitted test never reported |
| `licence_error` | 77 | A licence file the server or the command was given cannot be read (`licence.unreadable`), or, from SimCrux Pro, `compare` below a Pro licence (`licence.tier_required`); nothing was compared |

**An `engine_error` is never a pass,** and neither is a `failed_gate`. Say what
the document says: name the failing tests, and for an `engine_error` say that
the run did not produce results and why.

**Warnings qualify an answer.** `engine.missing`: some tests never ran their
simulator (it is not installed or not on `PATH`); their rows fail and say
nothing about the design. `results.incomplete`: the file has no summary line,
so its run did not finish and tests may be missing. `licence.withheld` on
`trend`: the flakiness class needs SimCrux Pro and was left out; the history
stands. From SimCrux Pro, `licence.source` notes beside it say why the licence
found did not admit it (expired, another product's). `log.missing`: SimCrux removed the log (it keeps failing tests' work
folders only, the oldest removed first).

**Logs do not last.** A failing test's log lives in SimCrux's scratch folder,
and every SimCrux run on the machine, from the command line or the server,
keeps only the newest 50 failing tests' folders across all runs (the
`--keep-failures` default). A later run can therefore remove the log an earlier
document cites: cite a log soon after the run, or copy it into the project.

**Tests.** `totals` and `run.total` count every test of the run; `tests` lists
up to `limit` of them, failures first (`fail`, `timeout`, `unknown`,
`cancelled`, then `vacuous`, `skipped`, `cover`, `pass`, each by id). When
`truncated` is true, read the rest with `results` on `results_path`, filtering
by `status`. `did_execute` is false for a test whose simulator never ran.

**History.** `trend` leaves out runs in which the test's simulator never ran,
and a warning counts them. Its `flakiness` is `null` here; SimCrux Pro gives
the class under a Pro licence: `class` (`stable`, `intermittent`, `flaky`,
`highlyFlaky` or `consistentlyFailing`), the `score`, the pass-to-fail `flips`
and the `window` of runs it was read from. It is a rule over the history (one
flip with the newest run failing is `consistentlyFailing`, a regression, not
flakiness), never a judgement; a history with no pass and no fail has none,
and a `trend.no_class` note says so.

**Comparisons** (SimCrux Pro). `compare` counts every test by `kind`, and
lists each one that changed with its status and runtime in both runs and a
`location` in the run (in the baseline for a removed test). `has_regression`
is true, and the outcome `failed_gate`, when a test that passed in the
baseline (`pass`, `vacuous` or `cover`) does not pass in the run; an
`unknown` test there is a failure here too. A file with no test is
`input_error`, since there is nothing to compare.

The schemas of every body are in this repository under `spec/mcp/schemas/`,
with a golden document for every outcome each tool can produce under
`spec/mcp/goldens/`.

## Citing

**Cite a test by its log as `file:line`,** from its `location`: `file` is its
log and `line` the log line its failure message came from, when the message
appears in the log. Every agent host, terminal and editor makes `file:line`
clickable. Give the test as `suite/test` and its status. A test's `waveform`
is a place, the file at time 0, which a person opens in WaveCrux with
`wavecrux://open?file=<file>&t=0`, the file percent-encoded. Report what the
document says: every status comes from the simulator and SimCrux's pass/fail
detectors, and SimCrux adds no verdict of its own.

## Never

- Never edit a test, a testbench, a threshold or a `simcrux.yaml` to make a
  run pass. A failing test is a person's to waive.
- Never report a `failed_gate` or an `engine_error` as a pass, an `unknown`
  test as anything but failed, or a page of tests as all of them.
- Never treat a flakiness class as leave to ignore a failing test. A
  `flaky` test that failed still failed.
