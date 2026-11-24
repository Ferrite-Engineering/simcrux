# SimCrux for coding agents

SimCrux runs simulation and formal regressions from a `simcrux.yaml` (Icarus,
Verilator, GHDL, cocotb, SymbiYosys and EQY tasks, the RISC-V suites) and
answers over the Model Context Protocol (MCP), so a coding agent can run the
regression and read the results instead of guessing whether tests pass. Every
answer is also a command, with the same output.

## What the server offers

The server is started with `simcrux mcp --root <project directory>`. It speaks
MCP over standard input and output, runs on your machine and makes no network
call of its own. Every path a tool receives must be inside `--root` (the
working directory when omitted). Before `run` starts, the `simcrux.yaml` is read
the way the run reads it, and every file it reads or names (included project
files, filelists, sources, include directories, `.sby` and `.eqy` files, flow
configurations, where the results go) must be inside the root too. A path
outside it, a symbolic link that leads outside it, or a network path is refused
and nothing is run.

Only `run` writes: exactly what `simcrux --ci` writes for the same config, the
`results.ndjson` and `results.summary.json` where the config puts them, and the
work folders of failing tests in SimCrux's own scratch. The simulators are the
ones on `PATH`. The server offers no way to run what a project file names
(`--allow-project-tooling`), to write an export, or to move the gate: a person
does those from the command line.

| Tool | What it returns |
|---|---|
| `run` | Runs the config and returns the run, its totals and each test: status, failure message, log, waveform, failures first |
| `results` | The same for a run already written, read from its `results.ndjson`; nothing is run again |
| `test` | One test of a run: its row, seed, parameters, first failure and the end of its log |
| `trend` | One test's history across `results.ndjson` files, newest first |

SimCrux Pro serves the same four tools and a fifth. Its command is `simcrux-pro`
in the desktop bundles (`simcrux_pro` when built from source), started the same
way and also taking `--license-file <path>`:

| Tool | What it returns |
|---|---|
| `compare` | A run against a baseline run: tests newly failing, newly passing, slower or faster by 20% or more, added and removed |

Under a Pro licence `trend` also gives the test's flakiness class. The licence
is read on every `trend` and `compare` call: the `--license-file` given, then
the `SIMCRUX_LICENSE_FILE` variable, then the organisation's policy file. Below
Pro, `trend` answers the history and says it left the class out, and `compare`
answers with a licence error and compares nothing.

Each tool is also a command, with the same inputs as flags and the same output
with `--json`:

```
simcrux run simcrux.yaml --json
simcrux results results.ndjson --status fail --json
simcrux test results.ndjson alu/sub_fail --json
simcrux trend alu/sub_fail runs/*.ndjson --json
```

A tool's text is byte for byte what the command writes, so a script and an
agent read the same document.

## Register it with your agent

The `simcrux` command must be on the `PATH` of the program that starts the
server. The instructions below were checked against each host's own
documentation on 2026-11-24; hosts change, so check theirs if a step differs.
To use Pro, replace `simcrux` with `simcrux-pro`.

=== "Claude Code"

    Add the server for the current project:

    ```
    claude mcp add --transport stdio simcrux -- simcrux mcp --root /path/to/project
    ```

    Everything after `--` is the command that starts the server. By default the
    entry is private to you and the project. To share it with your team, add
    `--scope project`, which writes `.mcp.json` in the project root:

    ```json
    {
      "mcpServers": {
        "simcrux": {
          "command": "simcrux",
          "args": ["mcp", "--root", "${CLAUDE_PROJECT_DIR:-.}"]
        }
      }
    }
    ```

    Claude Code asks each person to approve a project server the first time.
    Run `claude mcp list`, or `/mcp` inside Claude Code, to see that it
    connected.

=== "VS Code"

    With the EDACrux SimCrux extension installed, there is nothing to
    configure. The extension registers the server with the editor for each
    workspace folder you open, with that folder as `--root`, and the editor asks
    you before it first runs. It needs a folder open in a trusted workspace.
    It finds `simcrux-pro` or `simcrux` through the `edacrux.sim.executable`
    setting, then your `PATH`. Turn registration off with the
    `edacrux.sim.mcp.enabled` setting.

    Without the extension, add the server to `.vscode/mcp.json` in the
    workspace (VS Code's own file uses `servers`, not `mcpServers`):

    ```json
    {
      "servers": {
        "simcrux": {
          "type": "stdio",
          "command": "simcrux",
          "args": ["mcp", "--root", "${workspaceFolder}"]
        }
      }
    }
    ```

    Or run **MCP: Add Server** from the Command Palette and choose a command
    (stdio) server.

=== "Cursor"

    Create `.cursor/mcp.json` in the project (or `mcp.json` in `.cursor` in your
    home folder for every project):

    ```json
    {
      "mcpServers": {
        "simcrux": {
          "type": "stdio",
          "command": "simcrux",
          "args": ["mcp", "--root", "${workspaceFolder}"]
        }
      }
    }
    ```

    Then open **Customize** in the sidebar and confirm the server is enabled.
    If it does not connect, open the Output panel and choose "MCP Logs".

An editor that does not offer the registration API gets the same snippet from
the **Copy SimCrux MCP Server Configuration** command in the Command Palette.

## When an agent should call it

- Before it says that the tests pass: run the regression, and report the
  outcome and the totals the document gives.
- After it changes RTL or a testbench: run again, compare with an earlier run's
  `results.ndjson` through `results`, or follow one test through `trend`.
- When a test fails: `test` gives its failure message, the log line it came
  from, the end of its log, the seed and the parameters it ran with.
- When a run was made elsewhere, such as a CI job: read its `results.ndjson`
  with `results`.
- Before it says a change broke nothing (SimCrux Pro): `compare` the new run
  with a baseline run, which names every test that passed in the baseline and
  does not pass now.

## Read the outcome first

Every answer is one JSON document. Its `outcome` is the authority. An `unknown`
test is a failed test, because SimCrux could not tell whether it passed. A
`failed_gate` and an `engine_error` are never a pass: the agent names the
failing tests, and for an `engine_error` says that the run did not produce
results and why. Warnings qualify an answer, for example when a simulator was
not installed and some tests never ran. A flakiness class is a rule over the
history and never a reason to ignore a failure: a flaky test that failed still failed.

Two things an agent should never do: edit a test, a testbench, a threshold or a
`simcrux.yaml` to make a run pass (a failing test is a person's to waive), and
report a page of tests as all of them.

## Cite with the link

Tell the agent to cite a test by its log as `file:line`, from its `location`,
which every agent host, terminal and editor makes clickable, and to give the
test as `suite/test` with its status. A test's waveform is a place, the file at
time 0, which a person opens in WaveCrux with a `wavecrux://open` link. The
forms are described on the [agent link convention](https://edacrux.app/agent-links)
page.

Every status comes from the simulator and SimCrux's pass and fail detectors.
SimCrux adds no verdict of its own.
