# Team results database <span class="tier tier-enterprise">Enterprise</span>

A shared PostgreSQL results history that *you* own, fed by the CI pipeline you
already run. Reading it back in every engineer's dashboard is planned for 1.1.
Nothing is hosted by us,
no account or cloud service sits in the path, and verification data never leaves
your network. This page is the database itself. Retention, the audit events and
distributed execution are on [Administration](administration.md).

!!! note "What it takes to run one"
    The team database is an Enterprise feature and needs an Enterprise
    license. See [Tiers & licensing](licensing.md).

## Local first, shared as well {#hybrid}

SimCrux keeps a local SQLite history of every run, and that stays on regardless
of tier — it is the write path that cannot fail, so an engineer on a plane or
behind a server that is down keeps working exactly as before. Enterprise adds a
second destination: a **PostgreSQL database you own and host**. When one is
configured, each run finished in the desktop app is also written to it.

Runs are pooled under the project's **`project_id`**, declared at the top of
`simcrux.yaml` (see [Project identity](#project-identity)). The app writes its
runs under that id and reads the pooled history under it, so two engineers whose
checkouts sit at different paths, and the CI job that pushes with
`push-results --project <id>`, share one history. A project that declares no
`project_id` keeps its history local: nothing is pushed for it, and **Settings →
Team Database** says so.

The database holds results and history only. `simcrux.yaml`, sessions and
workspace metadata are not synced — those stay in git.

## Project identity {#project-identity}

```yaml
version: "1"
project_id: soc-top
```

`project_id` is 1 to 64 letters, digits, `.`, `_` or `-`, and it is the value
every machine agrees on: it travels with the project and is reviewed like the
rest of the file, which is why it is not a setting. Before 1.1 the app derived
a scope from the local checkout path, so no two machines ever shared a run;
rows written under those path-derived ids stay where they are and are not
migrated. A run your pipeline pushed with `--project <name>` is already under
the id the file should now declare: use that name. `push-results` refuses an
id that does not match the same rule, so CI and the file cannot disagree by a
stray character.

## Connecting {#connecting}

You provision the server. It is whatever PostgreSQL you already operate, on
premises or in your own cloud. Configure it in **Settings → Team Database**:
**Host**, **Port**, **Database**, **Role** and **Password**, then **Save** and
**Test connection**.

### TLS, named for what it does {#tls}

**Connection security** offers two settings in the app; the CI writer accepts a
third through `SIMCRUX_TEAM_DB_TLS`.

| Setting | `SIMCRUX_TEAM_DB_TLS` | What it means |
|---|---|---|
| **Encrypt and verify the certificate** | `verify-full` | **The default, and the only value that resists an active attacker.** Encrypted, with the server's certificate verified against the platform's trust store. |
| **Encrypt without verifying the certificate** | `encrypted-only` | Encrypted, certificate *not* verified. For an internal CA not yet in the platform trust store. It is a real weakening — anyone able to reroute the connection can read and change every query — so it is an explicit choice, and **never a silent fallback** when verification fails. |
| *(not offered in Settings)* | `disabled` | **Loopback only**, and refused for any other host. It exists for a throwaway container on `127.0.0.1`. |

!!! note "A support answer worth having ready"
    Certificate verification uses the operating system's trust store — Keychain
    on macOS, the certificate store on Windows, the system bundle on Linux.
    **The same server and the same build can verify on one machine and fail on
    another** when your internal CA is installed in some of your images and not
    others. That is a fleet-imaging question rather than a SimCrux bug, and it
    is the first thing to check when one engineer cannot connect and everybody
    else can.

### Where the credential lives {#credentials}

- **In the app** — your platform keychain: Keychain on macOS, Credential Manager
  on Windows, a secret service such as gnome-keyring on Linux. **Never a project
  file**, because a credential in `simcrux.yaml` is a credential in your git
  history, on every fork, forever. A Linux machine with no keyring cannot store
  the password, and Settings says so.
- **In CI** — `SIMCRUX_TEAM_DB_URL`
  (`postgres://user:password@host:port/database`), which carries the role and its
  password together. `SIMCRUX_TEAM_DB_TLS` overrides the TLS mode.

**There is no `--password` flag, and adding one would be a defect.** A password
passed as a flag lands in the CI log, in the job's rendered command line, and in
every screenshot of a failed build.

### Creating the tables {#provisioning}

**Connecting creates nothing.** Creating the tables — or bringing an older schema
up to date — is a separate, explicit **Initialize database** action, so typing a
hostname into a settings panel can never write DDL into a database somebody else
owns.

## The schema handshake {#schema}

*N* engineers and a CI fleet, each on whatever build they last installed, all
connect to one database. Heterogeneous clients are the design here rather than
the accident, so a rule that stopped everyone working until the whole team
updated would defeat the feature.

```text
database epoch  != client epoch     refuse, both directions
database version <  client needs    refuse, and name the upgrade action
database version >= client needs    WORK — this is the ordinary case
no schema at all                    refuse, and name the initialize action
```

**A database ahead of the client is not an error.** Migrations are
additive-only, so a newer schema is this schema plus columns and tables an older
build never names — every statement it issues still resolves. The *epoch* is the
escape hatch that keeps that honest: if additive-only ever has to break, the
epoch bumps and every client refuses in both directions rather than issuing
statements against a shape it does not understand.

## Pushing from CI {#ci}

CI has no desktop app; it has a results archive and a pipeline step. That step
is `simcrux-pro push-results`, which writes the `results.ndjson` a `--ci` run
produced.

```bash
export SIMCRUX_TEAM_DB_URL='postgresql://simcrux:…@db.example.internal/simcrux'
export SIMCRUX_ORIGIN_ID='ci-runner-07'     # a stable id per runner or pipeline
export SIMCRUX_SUBMITTER='ci-nightly'

simcrux-pro push-results --project soc-top results.ndjson
```

| Option | Meaning |
|---|---|
| `--project <id>` | **Required.** The project the run belongs to: the `project_id` declared in its `simcrux.yaml`, so the GUI reads the runs CI pushed. 1 to 64 letters, digits, `.`, `_` or `-`; anything else is a usage error (exit 64). |
| `--origin <id>` | A stable id for this runner. Defaults to `SIMCRUX_ORIGIN_ID`; one of the two is required, so two agents starting a run in the same millisecond cannot collide. |
| `--submitter <name>` | Attribution for the run. Defaults to `SIMCRUX_SUBMITTER`. |
| `--audit-log <path>` | Append a `results.pushed` event to this JSONL file. |

**It is idempotent.** A retried step does not double-write and does not fail
either — a re-run that reported failure because the work was already done is a
pipeline that goes red for succeeding.

Its exit codes distinguish "the schema needs an administrator" from "the
database was merely unreachable", because one is never worth retrying and the
other usually is. [The full table is on Administration.](administration.md#ci)

It runs on a build agent with no display: nothing in it depends on Flutter.

### Formal and implementation-flow results {#formal-flow}

From 1.2, a pushed run carries its formal and implementation-flow results
too, with no new option: the same archive, projected into six more tables.

| Table | One row per |
|---|---|
| `formal_runs` | formal result: tool, verdict as the tool stated it, mode, configured and reached depth, engine, solver, property counts |
| `formal_properties` | property identity within a test, first seen in which run |
| `formal_property_results` | property of that result, with its status and steps |
| `flow_runs` | implementation-flow result: kind, verdict, which reader read it and **whether that reader is verified for the run's tool version** |
| `flow_steps`, `flow_metrics` | step of that run, and metric it recorded, when the run directory is on the machine that pushes |

Every row references the result it belongs to (foreign keys enforced). A
flow run whose reader is not verified keeps that on every row, and the
organization rollup below never counts its metrics as verified.

The tables arrive as schema versions 2 and 3, by **Initialize database** on a
database an older build created; a 1.1 client keeps working against it, since
it never names the new tables.

### Organization rollup {#org-rollup}

From 1.2, the Team Database settings card shows the formal verdicts and the
latest implementation-flow metrics of every project in the shared database,
read when you open it. Nothing is hosted: the desktop app reads the
PostgreSQL you already run. An implementation-flow metric read by a reader
that is not verified for its run is marked "not verified" and kept out of the
verified totals.

### Who a run is attributed to {#submitter}

`simcrux-pro push-results` attributes a run to `--submitter`, or
`SIMCRUX_SUBMITTER` when the flag is absent. Runs written by the desktop app
resolve attribution with the suite's ordinary precedence:

```text
1. a LOCKED products.simcrux.teamDatabaseSubmitter   the organization decided
2. SIMCRUX_SUBMITTER                                 this job named itself
3. an unlocked policy value                          the organization suggested
4. the OS user                                       who is at the keyboard
```

**The OS user sits below an unlocked policy default.** A CI runner's OS user is
`runner`, `jenkins` or `root` on every job in the fleet, so the machine-derived
default is exactly wrong in the one place the shared database is most read.

Attribution may resolve to nothing. **An unattributed run is honest; a
fabricated attribution is a name in a dashboard next to a failure that person
never saw.** It is a string, not an identity — there is no user-management
subsystem, no SSO, and nothing authorises against it.

## Retention never touches this database {#retention-note}

A retention policy prunes the store on *your* machine. **SimCrux never deletes
from the shared one.** Pruning a history the whole team shares is an
administrative decision, made against the database by somebody who knows what
else depends on it. See [Administration](administration.md#retention).

## The rest of Enterprise {#rest}

| Capability | State | What it is |
|---|---|---|
| Shared team results database | Shipping | This page. |
| Result retention from the policy file | Shipping | Thresholds you sign, with the ordinary precedence. [Administration](administration.md#retention). |
| Org-wide policy & audit log | Shipping | License, telemetry decision, update constraints and the audit path in a signed file you keep in Git. [Policy file reference](https://edacrux.app/policy-reference). |
| Distributed execution | Shipping for `--ci` | One templated backend, so SLURM, LSF, Grid Engine and AWS Batch are configurations rather than integrations. `--ci` runs only; runs started in the app stay local. [Administration](administration.md#distributed). |
| Org-wide dashboards & trend rollup | Not built; from 1.2 the formal and flow rollup ships | Regression health rolled up across projects and teams. From 1.2, formal verdicts and implementation-flow metrics across projects, in the Team Database settings card. [Above.](#org-rollup) |
| Self-hosted results dashboard | Not built — [contact us](mailto:support@ferriteengineering.com?subject=EDACrux%20Enterprise%20%E2%80%94%20Self-hosted%20results%20dashboard) | An always-on web view over your team database, deployed by you against the PostgreSQL you already run. We would build it against a real environment rather than blind. |
| Vendor simulators | Not built | No vendor-simulator driver plugin is available. |

Licensing, offline activation and seats are covered at
[edacrux.app/licensing](https://edacrux.app/licensing).

!!! tip "See also"
    [Administration](administration.md) for retention, audit kinds, distributed
    execution and the CI exit codes ·
    [Policy file reference](https://edacrux.app/policy-reference) ·
    [Audit log](https://edacrux.app/audit-log) ·
    [Cross-probe & the suite](integrations.md)
