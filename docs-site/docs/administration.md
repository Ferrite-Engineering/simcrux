# Administration <span class="tier tier-enterprise">Enterprise</span>

Result retention from a signed policy file, the audit events SimCrux records,
distributed execution on your own cluster scheduler, and what each of SimCrux's
policy keys does. This page is for the person deploying SimCrux across a fleet —
the rest of these docs are for the engineer running regressions.

!!! note "The file itself is documented once, for the whole suite"
    One `.crux-policy.json` configures all four EDACrux products. Where it goes
    on each platform, how you sign it, discovery order, precedence and the full
    key table live in
    [the policy file reference](https://edacrux.app/policy-reference); the
    rollout procedure is [Deployment](https://edacrux.app/deployment). This page
    covers only what SimCrux's own keys do.

## SimCrux's policy keys {#keys}

All under `products.simcrux`.

| Key | What it does | State |
|---|---|---|
| `retentionPolicy` | How long local results are kept, by age and by count. [Below.](#retention) | In force |
| `teamDatabaseSubmitter` | Who runs written by the app are attributed to in the shared results database. [Team results database](team-database.md#submitter). | In force |
| `distributedExecutionBackend` | The templated job-submission backend for `--ci` runs. [Below.](#distributed) | In force for `--ci` |
| `defaultSimulator` | The simulator a test runs on when the project file names none. [Below.](#simulators) | In force |
| `simulatorBinaryPolicy` | Which simulators a fleet may use, as a list of simulator ids. [Below.](#simulators) | In force when locked |
| `ciGateThreshold` | The number of failed tests a `--ci` run may have and still pass. [Below.](#ci-ceiling) | In force for `--ci` |
| `formalForbidAssertionOptOut` | Refuses a proof whose task reads the design with assertions turned off. [Below.](#formal-policy) | In force from 1.2 |
| `formalRequiredSolvers` | The engines and solvers a proof may use. [Below.](#formal-policy) | In force from 1.2 |
| `formalMinDepth` | The least bound a bounded proof or cover may be configured with. [Below.](#formal-policy) | In force from 1.2 |
| `flowGateThresholds` | Your organization's thresholds for implementation runs, checked apart from a pipeline's own. [Below.](#flow-thresholds) | In force from 1.2, for `--ci` and `simcrux-pro flow gate` |

`products.simcrux.ciGateThreshold` is separate from LintCrux's key of the same
name: they threshold different quantities, test failures against violations.

## Simulators {#simulators}

Two keys decide which simulator a test runs on.

```json
"products": {
  "simcrux": {
    "defaultSimulator": "verilator",
    "simulatorBinaryPolicy": {
      "value": ["icarus", "verilator"],
      "locked": true
    }
  }
}
```

**`defaultSimulator`** is the simulator for a test that names none anywhere in
the project file: not on the test, not on its suite, and not in
`defaults.simulator`, whether in the file itself or in a file that includes it.
**The project file always wins**, locked or not; the policy value fills a gap
and never replaces a simulator somebody wrote. Without it, a test with no
simulator is a load error naming the test, as it always was.

**`simulatorBinaryPolicy` is which simulators a fleet may use.** Its value is a
list of simulator ids, the same ids a project file's `simulator:` takes
(`icarus`, `verilator`, `ghdl`, `cocotb`, and any a plugin registers). When it
is locked, a project with a test whose simulator is not on the list does not
load, in the app or under `--ci`, and the message names the test, its simulator
and the allowed ids:

```text
Test `unit/alu_vhdl` uses simulator `ghdl`, which your organization's policy
(simulatorBinaryPolicy) does not allow on this machine. Allowed simulators:
icarus, verilator.
```

Things worth knowing before you deploy it:

- **Write it locked.** An unlocked list is not enforced: the project file is
  the engineer's choice and a list that yields to it restricts nothing. SimCrux
  logs a warning when it meets one.
- **It does not pin binaries.** It decides which simulator *ids* may run, not
  which executable runs for an allowed id. That is still the engineer's
  Settings > Engines path (Settings > Simulators before 1.2), or a project file's `simulators:` block when the
  engineer has allowed project-defined tooling. If you need to fix the
  executable itself, [tell us](mailto:support@ferriteengineering.com).
- **A refused test fails the load rather than being skipped.** A skipped test
  would let a `--ci` run report green on fewer tests than the project declares.
- **The fallback is checked too.** A `defaultSimulator` that is not on a locked
  list is refused like any other.
- **An empty locked list allows nothing.** A list SimCrux cannot read (a string
  instead of a list, an entry that is not an id) is refused with a logged error
  and restricts nothing, so check the job log after a rollout.
- **On a build whose licence does not include these keys**, none of them is
  applied, and SimCrux logs that rather than silently doing nothing. The same
  holds for `ciGateThreshold` below.

## Result retention {#retention}

Thresholds you sign into the policy file, so the fleet keeps results for as long
as your organization decided rather than for as long as each engineer's settings
panel happens to say. They govern the same sweep that runs after every
regression finished in the app.

```json
"products": {
  "simcrux": {
    "retentionPolicy": {
      "value": { "maxAgeDays": 365, "maxWaveformRuns": 50 },
      "locked": true
    }
  }
}
```

`maxAgeDays`, `maxDataPoints` and `maxWaveformRuns` are all optional; write the
ones you mean. The bare form without the `value` wrapper works too — the key is
object-valued, and both spellings are accepted.

Precedence, highest first:

```text
1. a LOCKED products.simcrux.retentionPolicy   the organization decided
2. the engineer's Settings → Trend Retention   they chose
3. an UNLOCKED policy value                    the organization suggested
4. SimCrux's built-in default                  30 days, 50,000 points, 10 waveform runs
```

**An unlocked policy sitting *below* the engineer's setting is the level that
surprises people.** It is a default for installations nobody has touched, not a
nudge that overrides a deliberate choice. An administrator who means it locks it
— and when it is locked, the Settings control is disabled rather than accepting
an edit and discarding it.

**The precedence is decided before the sweep, not layered on top of it**, and
that is not an implementation detail. A second, org-policy sweep running after
the engineer's own would enforce a stricter organization policy and silently
fail a looser one: a locked `maxAgeDays: 365` cannot undelete what a 30-day user
setting already removed.

**A threshold on a build whose license does not include it says so in
Settings** rather than silently doing nothing.

!!! note "Retention is local, and the shared database is never pruned"
    Retention prunes the store on *that* machine. **SimCrux never deletes from
    the shared team database**, whatever the policy says.

!!! note "The purge audit event records which policy did the deleting"
    `retention.purged` fires when a sweep deletes under your policy, and it
    carries the **source** of the thresholds it applied — whether they came from
    the organization policy file or from the engineer's own Settings. A
    retention report built on it can therefore distinguish a fleet-wide rule
    from a local one, which is the question an auditor actually asks.

Archiving to S3, GCS or Azure Blob, and restore-on-demand, are **not built**.
The target would be your own bucket in your own account under your own lifecycle
rules, which makes it a conversation rather than a feature we can guess.
[Start it here.](mailto:support@ferriteengineering.com)

## Distributed execution {#distributed}

When the policy file names a backend, `--ci` runs launched through the SimCrux
download's executable submit **every test as a job to your cluster scheduler**
instead of running it locally.

!!! note "Scope, stated first"
    - **`--ci` only.** Runs started in the app always execute on the engineer's
      machine, and so does the standalone open-core `simcrux` binary.
    - **The verdict is the scheduler's** for a simulation test: a job that
      ends in a `succeededStates` state is a pass and one in a `failedStates`
      state is a fail; `pass_fail:` detectors are not applied to distributed
      jobs.
    - **From 1.2, a formal or implementation-flow test is read back, never
      taken from the job's state.** An `sby` or `eqy` test's verdict is the
      `DONE (...)` line in the job's log; a `librelane` or `nextpnr` test's is
      read from the run the job left in its work directory (`{workDir}`),
      which the submit command must make the job's working directory (as the
      examples below do). A test with neither fails, saying so. One task per
      job. A flow test's work directory is pinned with `.simcrux-keep`: run
      directories are never pruned.
    - **A backend that fails to parse, or a license that does not include it,
      falls back to local execution.** The reason is logged, not shown on the
      command line — check the CI log if a nightly run is unexpectedly slow.

**One templated backend, not four integrations.** That is the design decision
the whole feature rests on. SLURM, LSF, Grid Engine and AWS Batch are
*configurations* of one backend parameterized by a submit command, a status
command and a log-path pattern. A site with an in-house or heavily customized
scheduler becomes self-serve instead of a feature request.

| Field | Required | Meaning |
|---|---|---|
| `workRoot` | yes | Root of a filesystem **both** this machine and the compute nodes can see. |
| `testCommand` | yes | The command a node runs for one test. May use `{runId}` and `{testId}`. |
| `submitCommand` | yes | Argument list that submits one job. |
| `statusCommand` | yes | Argument list that prints a job's state. |
| `cancelCommand` | no | Argument list that cancels a job. Without it, cancellation is local only. |
| `logPathPattern` | yes | Where the job writes its log, which SimCrux reads. |
| `jobIdPattern` | yes | Regular expression with one capture group, applied to the submit command's output. |
| `runningStates` / `succeededStates` / `failedStates` | `succeededStates` yes | Status-command outputs meaning still going, passed, and did not pass. An unrecognized state counts as still running, so a job stuck in one hits the run's timeout. |
| `pollIntervalSeconds` | no | How often to run the status command per job. Default 15. |
| `submitTimeoutSeconds` | no | How long one submit may take. Default 60. |
| `name` | no | A label for logs and audit events. |

### What SimCrux leaves under `workRoot` {#dist-retention}

Each run gets `<workRoot>/<runId>/`, and each test a directory under it named
after its id, with every character other than a letter, a digit, `.`, `_`, `+`
or `-` replaced by `_`. A passing test's directory is removed once its log has
been read. A failing test's is kept, and at the end of every run SimCrux prunes
the kept directories across all runs to the 50 most recent, 2 GiB at most — the
same budget `--ci` applies to a local run.

**Pruning only touches what SimCrux made.** A run directory is considered only
when it holds the `.simcrux-run` marker SimCrux writes into it, and never while
it holds `.simcrux-run-in-flight`, which stays for as long as the run does — on
whichever machine started it. A run whose process was killed keeps that marker
and is left alone; delete the marker to let it be pruned. An empty
`.simcrux-keep` file in a run or test directory pins it.

### The substitution vocabulary {#dist-vars}

**Closed, deliberately.** An open vocabulary would make every template a small
programming language, and a typo'd variable would submit a job with an empty
argument rather than being refused. Every unknown placeholder is an error when
the backend is parsed.

| Variable | What it expands to | Available in |
|---|---|---|
| `{runId}` | The regression run's id, stable for the whole run. | submit, status, cancel, test command, log path |
| `{testId}` | The test's id, unique within the run. In the log path it is the id as one file name, the same one `{workDir}` ends in: every character other than a letter, digit, `.`, `_`, `+` or `-` becomes `_`, so a test name cannot move the log out of the directory the pattern names. In the test command it is used verbatim, and the node runs that command through a shell (or, on AWS Batch, inside JSON), so it is held to letters, digits and `.`, `_`, `+`, `/`, `=`, `-`. Every id SimCrux builds (`suite/test`, `+KEY=value`, `+seed=N`) is in that set; a test whose suite, name or parameter value carries anything else (a space, a quote, `$`, `;`) is reported as **not submitted**, with the reason, rather than handed to the shell unquoted. | submit, status, cancel, test command, log path |
| `{command}` | The test command (`testCommand`, expanded). | submit |
| `{workDir}` | The per-test working directory under `workRoot`. | submit, log path |
| `{logPath}` | The log path, from `logPathPattern`. | submit |
| `{jobId}` | The scheduler's own job id. **Only in the status and cancel commands** — it does not exist until the submit has returned. | status, cancel |

**The submit template is a list of arguments rather than a string**, and
`{command}` is why: a scheduler wrapper takes it as one argv element
(`sbatch --wrap=<cmd>`), and joining the template into a shell string first
would make quoting that element your problem. Write a literal brace as `{{` or
`}}`.

### Worked example — SLURM {#dist-slurm}

```json
"distributedExecutionBackend": {
  "name": "slurm",
  "workRoot": "/shared/simcrux",
  "testCommand": "./run-test.sh {runId} {testId}",
  "submitCommand": [
    "sbatch",
    "--job-name={runId}-{testId}",
    "--output={logPath}",
    "--chdir={workDir}",
    "--wrap={command}"
  ],
  "statusCommand": ["squeue", "--job={jobId}", "--noheader", "--format=%T"],
  "cancelCommand": ["scancel", "{jobId}"],
  "logPathPattern": "{workDir}/{testId}.log",
  "jobIdPattern": "(?:Submitted batch job\\s+)?(\\d+)",
  "runningStates":   ["PENDING", "RUNNING", "CONFIGURING", "COMPLETING", "RESIZING"],
  "succeededStates": ["COMPLETED"],
  "failedStates":    ["FAILED", "CANCELLED", "TIMEOUT", "NODE_FAIL",
                      "OUT_OF_MEMORY", "BOOT_FAIL", "DEADLINE", "PREEMPTED"]
}
```

`workRoot` and `testCommand` describe **your site**, not the scheduler — replace
both. `jobIdPattern` tolerates both `sbatch --parsable`'s bare id and the default
"Submitted batch job 12345" form, because a site with a submit wrapper often
loses the flag.

### Worked example — LSF {#dist-lsf}

```json
"distributedExecutionBackend": {
  "name": "lsf",
  "workRoot": "/shared/simcrux",
  "testCommand": "./run-test.sh {runId} {testId}",
  "submitCommand": [
    "bsub",
    "-J", "{runId}-{testId}",
    "-o", "{logPath}",
    "-cwd", "{workDir}",
    "{command}"
  ],
  "statusCommand": ["bjobs", "-noheader", "-o", "stat", "{jobId}"],
  "cancelCommand": ["bkill", "{jobId}"],
  "logPathPattern": "{workDir}/{testId}.log",
  "jobIdPattern": "Job <(\\d+)>",
  "runningStates":   ["PEND", "RUN", "PROV", "WAIT", "PSUSP", "USUSP", "SSUSP"],
  "succeededStates": ["DONE"],
  "failedStates":    ["EXIT", "ZOMBI", "UNKWN"]
}
```

The same fields, different words. That is the whole point of the shape: **Grid
Engine and AWS Batch are the same exercise**, and so is whatever your site
actually runs. A state listed in both `succeededStates` and `failedStates` is a
configuration error and is refused rather than resolved by precedence.

## Audit events SimCrux records {#audit}

Turned on with `suite.audit.path`, suite-wide. The envelope, the format, rotation
and failure behaviour are in [the audit log reference](https://edacrux.app/audit-log).

| Kind | When | Payload |
|---|---|---|
| `regression.started` | A regression started in the app begins. | `runId`, `trigger`, `tests`, `simulator` |
| `simulator.invoked` | **Once per run, not once per test.** | `runId`, `simulator`, `tests` |
| `regression.finished` | A run in the app ends. Recorded once per run. | `runId`, `outcome`, `tests`, `failed`, `simulator` |
| `baseline.set` | An engineer pinned a run as the comparison baseline. | `project_id`, `run_id` |
| `baseline.cleared` | An engineer removed the pinned baseline. | `project_id` |
| `results.pushed` | `simcrux-pro push-results --audit-log <path>` wrote a run to the shared team database — the moment verification data leaves the machine that produced it. | `run_id`, `project_id`, `results`, `failed`, `database`, `submitter` |
| `distributed.job.submitted` | A `--ci` run submitted a test to the distributed backend. | `runId`, `testId`, `backend` |
| `retention.purged` | A retention sweep deleted trend rows or waveform dumps. [Above.](#retention) | `deleted`, `policySource` |
| `formal.policy.applied` | From 1.2: your formal policy refused a proof result. [Below.](#formal-policy) | `testId`, `tool`, `rules` |
| `flow.thresholds.evaluated` | From 1.2: your flow thresholds were checked against a run, whatever the outcome. [Below.](#flow-thresholds) | `subject`, `decision`, `thresholds`, `failed` |

Things about these that are deliberate and worth knowing before you write
queries against them:

- **The regression events come from runs started in the app.** A `--ci` run
  records `distributed.job.submitted` when it uses a backend, and nothing else.
- **The simulator is recorded once per run, never once per test.** A
  thousand-test regression produces one `simulator.invoked` line, not a thousand.
- **Counts are exact, not bucketed.** `tests` and `failed` are the real numbers.
  This is your organization's record of its own machines, not a metric we
  aggregate.
- **Start and finish share a run id**, so a night of runs reconciles. The finish
  event does not depend on usage-statistics consent: an audit trail must not
  inherit that gate.
- **Events carry the target, never the credential or a file path** — an audit
  log is precisely the file somebody attaches to a support ticket.

## The CI failure ceiling {#ci-ceiling}

```json
"products": {
  "simcrux": {
    "ciGateThreshold": 0
  }
}
```

`ciGateThreshold` is the number of failed tests a `--ci` run of the SimCrux
desktop app may have and still pass. `0` means any failure fails the run, which
is also what happens with no key at all.

**A `--fail-threshold` typed on the command line wins**, locked or not. The
policy value replaces the flag's default for every job that does not pass the
flag, and SimCrux prints one line on stderr saying the organization's ceiling
is in force, so a red build the pipeline did not configure explains itself.
The flag counts differently: `--fail-threshold n` fails at `n` failures, so a
ceiling of `2` behaves like `--fail-threshold 3`.

The standalone `simcrux` binary does not read this key.

## Formal policy {#formal-policy}

From 1.2, three keys set your organization's floor for proofs run with the
SymbiYosys (`sby`) driver, in the app and in a `--ci` run.

```json
"products": {
  "simcrux": {
    "formalForbidAssertionOptOut": true,
    "formalRequiredSolvers": ["smtbmc yices", "abc pdr"],
    "formalMinDepth": 20
  }
}
```

- `formalForbidAssertionOptOut`: a task that reads the design with assertions
  turned off (`read -noassert`, or yosys-slang's `--ignore-assertions`) fails.
- `formalRequiredSolvers`: the engine lines a proof may use, as they appear
  in the job file's `[engines]` section. An entry naming only the engine
  (`smtbmc`) allows every solver under it. A run that names no engine fails,
  because the list cannot be checked.
- `formalMinDepth`: the least `depth` a `bmc` or `cover` task may be
  configured with. `prove` and `live` tasks are not held to it.

A result that breaks a rule fails, and its message begins "Refused by the
organization policy" and names the rule. **The verdict is not changed:** a
bounded proof that held still reads as proved over its steps, and the refusal
is a second fact on the row, so an engineer can see both what the solver found
and why the organization does not accept it. Each refusal is recorded as a
`formal.policy.applied` audit event.

The standalone `simcrux` binary does not read these keys.

## Flow thresholds {#flow-thresholds}

From 1.2, `flowGateThresholds` sets thresholds every implementation run is
checked against, written as `simcrux flow gate --fail-on` takes them.

```json
"products": {
  "simcrux": {
    "flowGateThresholds": ["timing__setup__wns<0", "route__drc_errors>0"]
  }
}
```

A run fails a threshold when `metric <op> value` holds. They are checked
**beside** a pipeline's own thresholds, never in place of them, by
`simcrux-pro flow gate` and by a `--ci` run of the desktop app (against every
flow result, with the run read again for its full metric set):

| Exit | Meaning |
|---|---|
| `3` | An organization threshold failed. The pipeline's own result may have been `0` or `1`; `3` says it is the organization's gate. |
| `2` | An organization threshold could not be evaluated: the run, or a metric a threshold names, is missing. A pipeline's own `2` also stands over `3`. |

Each evaluation is recorded as a `flow.thresholds.evaluated` audit event. The
standalone `simcrux` binary does not read this key and never exits `3`.

## CI gating {#ci}

`simcrux-pro push-results` is the CI writer for the shared database, and **its
exit codes are the contract a pipeline branches on**. The distinction that earns
its place is `4` against `5`: one is never worth retrying and the other usually
is.

| Code | Meaning | Retry? |
|---|---|---|
| `0` | Written — *or already present*. Both are success: a retried step must not go red for work that was already done. | — |
| `2` | Not configured or not licensed: no usable connection details in the environment, a licence file that could not be read, or no Enterprise licence. The message on stderr says which. | no |
| `3` | The archive is missing, unreadable, or describes no run. | no |
| `4` | The database is reachable and its schema cannot serve this build — unprovisioned, an incompatible epoch, or another product's. **An administrator has to act.** | **never** |
| `5` | The database could not be reached, or the write failed. Network weather, a restart, a firewall. | **yes** |
| `64` | Bad command line (`EX_USAGE`): an unknown option, a missing or malformed `--project` (it must be the project's `project_id`: 1 to 64 letters, digits, `.`, `_` or `-`), archive or runner id (`--origin` / `SIMCRUX_ORIGIN_ID`), or no command at all. A human fixes the pipeline definition. | no |

A pipeline that cannot tell `4` from `5` either retries a misconfiguration
forever or fails a build over a thirty-second blip. A usage error is `64`, far
from the outcome codes, so a typo in the job can never read as one of them.
Anything else — `130` when the job is cancelled, for instance — is unexpected:
report the code rather than folding it into a catch-all branch.

**Credentials come from the environment, never from a flag.** There is no
`--password`, and adding one would be a defect. Set `SIMCRUX_TEAM_DB_URL`.

## Managed installs and updates {#packaging}

**A managed install does not update itself.** An application installed by MSI,
`.deb` or `.rpm` does not check the release manifest, offer an in-app update, or
nag. That outranks every policy key, including `suite.updateChannel`, because it
describes how the application was installed rather than what you configured. The
[downloads page](https://simcrux.app/download) lists the packages available
today.

!!! tip "See also"
    [Team results database](team-database.md) for the connection, TLS and schema
    handshake · [Policy file reference](https://edacrux.app/policy-reference) ·
    [Audit log](https://edacrux.app/audit-log) ·
    [Deployment](https://edacrux.app/deployment) ·
    [Command line & CI](cli.md)
