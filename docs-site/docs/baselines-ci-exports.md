# Baselines, CI & exports

SimCrux runs in your pipeline as well as on your desktop. This page covers
comparing a run against a baseline to catch new failures, the export formats CI
consumes, the `simcrux simcrux.yaml --ci` entry point, and PR annotations that
put results on the pull request itself.

## Baseline comparison <span class="tier tier-pro">Pro</span> {#baseline}

A regression's absolute pass count matters less than *what changed*. The
**Regression Comparison** screen diffs the current run against a saved
**baseline** run. Open it with **Compare to baseline** on the toolbar, or with
the **Baseline:** chip that appears on the toolbar once a baseline is set. On
that screen, **Set baseline** makes the current run the baseline (typically
after a good run) and **Clear baseline** drops it. The baseline is rebuilt from the
project's persistent trend history, so the comparison survives a relaunch — as
long as retention has not pruned that run.

The comparison table lists every test with its **Baseline** and **Current**
status, the **Δ Runtime**, and a **Change** chip — **NEW FAILURE**,
**NEW PASS**, **SLOWER**, **FASTER** (a runtime change of 20 % or more),
**ADDED**, **REMOVED** or **UNCHANGED**. Filter chips narrow the view to
**Regressions** (new failures and slower tests), **Improvements** (new passes
and faster tests) or **Unchanged**, and a summary line tallies new failures, new
passes and runtime regressions. **Export diff…** copies the whole diff to the
clipboard as JSON.

On the command line, `--fail-on-regression` with `--baseline <results.ndjson>`
makes a `--ci` run exit `1` when a test that passed in the baseline now fails
(set `SIMCRUX_REGRESSION_EXIT_CODE` to use a different code). Slower tests do
not fail the gate. A baseline file that is missing, unreadable or holds no
results is an error, not a pass: the run prints
`error: regression gate: …` on stderr naming the path and exits `2`, so a
mistyped path cannot quietly switch the gate off. The gate is a Pro feature and
follows the run's [license tier](cli.md#license-in-ci). Through the 0.8.x public
beta every run of the download's executable evaluates it; from 1.0 a run that
resolves as Open Core refuses it the same way a bad baseline is refused, with an
`error: regression gate:` line naming the tier and exit `2`, rather than
passing a gate it did not evaluate. Either way this needs the SimCrux
download's own executable; in an open-core build the flag has no effect. See
[Command line & CI](cli.md#arguments).

## Exports {#exports}

SimCrux exports a completed run in the formats your downstream tooling expects.
Two doors, one exporter: **Tools → Export Results…** in the app (also in the
command palette), and `--export <format>=<path>` on the command line. Both write
the same document for the same run, and both export the *whole run* rather than
whatever the table is currently filtered to. Exporting is open core.

| Format | `--export` id | For |
|---|---|---|
| JUnit XML | `junit` | Every CI system's test-report format. Failed and timed-out tests are `<failure>` elements; `unknown` and cancelled tests are `<error>` elements. |
| JSON | `json` | Programmatic consumption; the full structured result set. |
| CSV | `csv` | Spreadsheets and ad-hoc analysis. |
| HTML | `html` | A single self-contained page with sortable columns, status filters and search — archive it or attach it to a build. |

In the app, **Export Results…** asks for the format, then a location, suggesting
`<run id>.<extension>` as the file name.

For the full read-only web dashboard instead of a single HTML file, see
[Publishing the results dashboard](ci-integration.md).

!!! note "What travels with an export"
    JSON, HTML and the web dashboard record the config path as it was given and
    each failing test's failure message. Check both before publishing a report
    for a private design somewhere public.

## CI integration {#ci}

Run a regression headless with `simcrux simcrux.yaml --ci`. The process exit
code reflects the outcome — `0` when failures stay below `--fail-threshold`
(default `1`, so any failure fails the build), `1` when they reach it, `2` when
SimCrux could not run at all. CI mode writes nothing but the
[streaming results](#streaming-results) unless you ask for `--export` targets.

For runner images without a display server, SimCrux also builds as a
**standalone headless binary** — a plain executable with no window and no GUI
runtime, built from the open-source tree with `tool/build_cli.sh`. It supports
`--ci` with every export target, the FuseSoC and RISC-V importers, and
`export-dashboard`. An invocation that would open a window in the desktop app
exits `2` with the usage text instead, and the standalone binary never transmits
telemetry.

```bash
# Minimal CI invocation
simcrux simcrux.yaml --ci --export junit=report.xml

# Cap concurrency and gate only on regressions against a baseline (Pro)
simcrux simcrux.yaml --ci --max-parallel 16 \
  --baseline baseline/results.ndjson --fail-on-regression

# Also fail when a result is classified vacuous
simcrux simcrux.yaml --ci --fail-on-vacuous
```

A CI run has no license stored by the app: give it one with
`--license-file <path>` or `SIMCRUX_LICENSE_FILE`, or deploy one in your policy
file, so Pro sweeps expand at your tier — see
[License tier in CI](cli.md#license-in-ci). `type: use` detectors from the app's
library are not available to `--ci`; a project that uses one fails to load.

`--export` creates an export's directory when it does not exist. The summary
line is printed before any export is written, so an export that fails — reported
on stderr, with exit `2` — never costs the run its verdict or the other
exports.

Project load advisories, such as a sweep your tier did not expand, are printed
on stderr as `warning: <file>:<line>:<col>: <message>` before the run starts.

### CLI flags {#cli-flags}

The full flag surface — `--filter`, `--max-parallel`, `--json`, `--export`,
`--fail-threshold`, `--fail-on-vacuous`, `--baseline`, `--fail-on-regression`,
`--import-fusesoc` and the rest — with exit codes and subcommands is on
[Command line & CI](cli.md#arguments). Ready-made GitHub Actions, GitLab and
Jenkins jobs are on [CI recipes](ci.md).

### Streaming results {#streaming-results}

`simcrux --ci` streams one JSON line per finished test to `results.ndjson` and
writes `results.summary.json` at the end, both next to `simcrux.yaml` by
default. The `output:` block moves them:

```yaml
output:
  results_path: build/results.ndjson
  summary_path: build/results.summary.json
```

Relative paths resolve against the directory holding `simcrux.yaml`, like every
other path in it. A `--ci` run creates these files and truncates them if they
exist, so both must stay inside that directory: a path that climbs out with
`../`, an absolute path elsewhere, or one that leads out through a symbolic link
stops the project from loading, with the file, line and column. To write them
somewhere else on purpose (a shared artifacts directory, say), pass
`--allow-project-tooling`. `output.streaming: true` is accepted but has no
effect in the desktop app, which does not write these files. `results.ndjson` is what
`--baseline`, `simcrux export-dashboard` and the
[web dashboard](web-mode.md) read.

## PR annotations <span class="tier tier-pro">Pro</span> {#annotations}

Put results where the review happens. SimCrux posts a run's results as GitHub
pull-request annotations and comments, GitLab merge-request notes, or a JSON
payload to your own webhook receiver, so reviewers see new failures on the pull
request without opening the build log.

Configure the target in **Settings → PR Annotations** (also
**Tools → Configure PR Annotations…**): **Platform** (GitHub, GitLab or
Webhook), **Repository** (`owner/repository`), **Pull request number**,
**Access token** (stored in your system keychain) or **Receiver URL**, then
**Save**. **Test connection** posts a test notice; **Forget target** clears it.
Post the active run with **Tools → Dispatch PR Annotations**, or turn on
**Post automatically when a run finishes** (off by default; cancelled runs are
never posted).

!!! note
    PR annotations are posted from the desktop app. `simcrux --ci` does not post
    them.

## A CI pipeline, end to end {#pipeline}

1. **Install SimCrux and the simulators on the runner.** The CI image needs the
   simulators your tests use on `PATH`, plus the `simcrux` binary.
2. **Run in CI mode.** Run
   `simcrux simcrux.yaml --ci --export junit=results/report.xml --export html=results/index.html`.
   SimCrux runs the regression, writes `results.ndjson` and the two exports, and
   sets the exit code.
3. **Publish the reports.** Hand `results/report.xml` to your CI's test-report
   step and archive `results/index.html` as a build artifact — or build a full
   [web dashboard](ci-integration.md) from `results.ndjson`.
4. **Gate on regressions** <span class="tier tier-pro">Pro</span>. Keep a
   known-good `results.ndjson` and add `--baseline <file> --fail-on-regression`.

!!! note "Next"
    To share results across a whole team rather than per build, see the
    [Team results database](team-database.md).
