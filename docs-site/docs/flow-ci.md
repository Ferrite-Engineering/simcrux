# CI gate for implementation runs, from 1.2

From SimCrux 1.2, the standalone `simcrux` binary has a `flow` family of
subcommands that runs a project's flow entries, reads runs, gates them against
thresholds and exports them, with no window and no display server. This page has
the commands, the exit-code table and ready-made recipes. It is part of
[Implementation flow](flow.md).

<!-- vocabulary-guard: disclaimer begin -->
Results are findings, not signoff.
<!-- vocabulary-guard: disclaimer end -->

Every `simcrux flow` subcommand is open core and free. None of them transmits
telemetry, and `-h` or `--help` anywhere on the line prints the usage and exits
`0` before any file or tool is touched. `simcrux flow --version` prints
`simcrux <version>`.

## The commands {#commands}

```
simcrux flow run    [--entry <name>]... [--allow-project-tooling] [--json] [<project>]
simcrux flow ingest <run-dir|report.json>... [--json]
simcrux flow gate   <run-dir|report.json>
                    [--fail-on-wns <ns>] [--fail-on-hold-wns <ns>] [--fail-on-fmax-below <MHz>]
                    [--fail-on '<metric><op><value>']... [--baseline <file>]
                    [--sarif <out>] [--junit <out>] [--json]
simcrux flow export <run-dir|report.json> --format json|junit|sarif|html --out <file>
```

- **`flow run`** runs the project's `flow:` entries (`simcrux.yaml` in the
  current directory by default), all of them or the ones named with `--entry`.
  Each entry prints `flow/<name>: <verdict>` and its run directory. An entry
  name that does not exist is a usage error. The keys that choose a program
  need `--allow-project-tooling`, as for [any project](flow.md#flow-block).
  `Ctrl+C` or a termination signal cancels the run, kills its whole process
  tree, and exits `130` or `143`.
- **`flow ingest`** lists the runs under the paths you give and writes nothing.
  See [Ingesting runs](flow-ingest.md#cli).
- **`flow gate`** reads one run and decides whether it passes.
- **`flow export`** writes one run as JSON, JUnit XML, SARIF or a self-contained
  HTML page, and exits `0`.

Results go to stdout and diagnostics to stderr. `--json` prints one document on
stdout with the exit code and its label.

## Thresholds {#thresholds}

`flow gate` with no threshold passes when the run's verdict is **Met** and
fails when it is **Violated**. With thresholds, or a baseline, they decide
**instead of** the verdict: a nextpnr run that missed its clock target still
passes `--fail-on-fmax-below 50` when it reached 60 MHz.

| Option | Fails the run when |
|---|---|
| `--fail-on-wns <ns>` | The worst setup slack (`timing__setup__wns`, the minimum across corners) is below the limit. `--fail-on-wns 0` fails any negative slack. |
| `--fail-on-hold-wns <ns>` | The worst hold slack (`timing__hold__wns`) is below the limit |
| `--fail-on-fmax-below <MHz>` | The achieved clock (`fmax__achieved__mhz`) is below the limit |
| `--fail-on '<metric><op><value>'` | The comparison holds. `op` is one of `<`, `<=`, `==`, `>=`, `>`, for example `--fail-on 'route__drc_errors>0'`. Repeatable. Quote it, so the shell does not read `>` as a redirect. |
| `--baseline <file>` | A metric that matters has got worse than in the baseline. The file is a flat metrics document, or a `flow export --format json` document, whose `metrics` object is used. |

For a nextpnr run the slack is a period slack, `1000/constraint - 1000/achieved`
nanoseconds per clock, and `--json` names the derivation. A threshold whose
metric the run does not have makes the run **could not be evaluated** (exit `2`),
and that outranks a threshold that failed. A run that stopped, did not run or is
unrecognised cannot be gated at all.

`--sarif <out>` and `--junit <out>` write the findings as the gate runs. The SARIF
file can be opened in [LintCrux](https://docs.lintcrux.app/opening-flow-sarif).

## Exit codes {#exit-codes}

| Code | Name | Meaning |
|---|---|---|
| `0` | met | Every threshold is met, or there are none and the flow verdict is Met |
| `1` | violated | A threshold or the flow verdict is violated. Findings are printed. |
| `2` | could not evaluate | The flow stopped before it produced the metric, the report is missing, or a threshold's metric is absent. For `flow run` or `flow ingest` over several runs, any run that could not be read wins over a violated one. |
| `3` | organization threshold violated | An organization's signed policy threshold failed, apart from your own. Only `simcrux-pro flow gate` and the desktop app's `--ci` return it; `simcrux flow` never does. |
| `64` | usage | An unknown flag, a missing value or path, an unknown entry or subcommand |
| `65` | data error | A report or metrics file exists but cannot be converted |
| `77` | license required | `simcrux-pro flow compare` or `flow baseline write` was refused for want of a Pro license, or a named license file could not be read. `simcrux flow` never returns it. |
| `130`, `143` | interrupted | Cancelled with `Ctrl+C` or a termination signal. The run's process trees were killed. |

The codes are disjoint on purpose: a pipeline can tell "the design has
findings" (`1`) from "the flow could not be evaluated" (`2`) from "the command
line was wrong" (`64`). When one invocation has both a violation and something it
could not evaluate, it exits `2`.

The usage code for `simcrux flow` is `64`, where the older `simcrux --ci`, the
importers and `export-dashboard` keep their `2` (see
[Command line & CI](cli.md#exit-codes)). Both are stable.

### Organization thresholds, `3` {#org}

<span class="tier tier-enterprise">Enterprise</span> A signed policy file can
set [`flowGateThresholds`](administration.md#flow-thresholds), checked beside
yours and never in place of them. `simcrux-pro flow gate` and a `--ci` run of the
desktop app evaluate them and exit `3` when one fails. The order, highest first,
is `2`, then `3`, then `1`: a gate that could not evaluate is never turned into
`3`, and an organization violation outranks your own, so a pipeline can tell the
organization's rule from your threshold. `0` is returned only when both are met.

The same `flow gate` line can therefore exit `1` in `simcrux` and `3` in
`simcrux-pro` when the only failing threshold is the organization's. The open
`simcrux` binary reads no organization policy, so a pipeline that must enforce
one calls `simcrux-pro flow gate` or the desktop app's `--ci`.

### The desktop app's `--ci` {#ci}

`simcrux project.yaml --ci` runs flow entries as tests, with the exit codes on
[Command line & CI](cli.md#exit-codes): a **Violated**, **Stopped** or
**Did not run** entry is a failed test that counts toward `--fail-threshold`.
Exit `3` is added only when an organization's flow threshold fails, over a run
whose own code was `0` or `1`.

## Recipes {#recipes}

Match `0`, `1`, `2` and `3` explicitly and treat anything else as unexpected, so
a new code can never pass as a green job.

A shell step, for any CI system:

```bash
set +e
simcrux flow gate runs/blinky_ecp5/simcrux-20261021T120000Z --fail-on-wns 0
code=$?
case "$code" in
  0) echo "gate: met" ;;
  1) echo "gate: findings, a threshold or the flow verdict is violated"; exit 1 ;;
  2) echo "gate: could not evaluate the run"; exit 1 ;;
  3) echo "gate: an organization threshold failed"; exit 1 ;;
  *) echo "gate: unexpected, code $code"; exit 1 ;;
esac
```

A GitHub Actions job that runs the entry, gates it, and keeps the evidence:

```yaml
jobs:
  fpga:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v4
      - name: Run the flow entry
        shell: bash
        run: |
          set +e
          simcrux flow run --entry blinky_ecp5 simcrux.yaml
          code=$?
          case "$code" in
            0) echo "run: met" ;;
            1) echo "run: findings, an entry is violated; the gate below decides" ;;
            2) echo "run: could not evaluate"; exit 1 ;;
            3) echo "run: an organization threshold failed"; exit 1 ;;
            *) echo "run: unexpected, code $code"; exit 1 ;;
          esac
      - name: Gate the run and write the SARIF
        shell: bash
        run: |
          set +e
          run=$(ls -d runs/blinky_ecp5/*/ | tail -n 1)
          simcrux flow gate "$run" --fail-on-wns 0 --sarif flow.sarif --junit flow.xml
          code=$?
          case "$code" in
            0) echo "gate: met" ;;
            1) echo "gate: findings"; exit 1 ;;
            2) echo "gate: could not evaluate"; exit 1 ;;
            3) echo "gate: an organization threshold failed"; exit 1 ;;
            *) echo "gate: unexpected, code $code"; exit 1 ;;
          esac
      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: flow-findings
          path: |
            flow.sarif
            flow.xml
            runs/
```

The runner needs Yosys and nextpnr on `PATH`, for example from an
[OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build) unpacked in an
earlier step, and the `simcrux` binary from
[Command line & CI](cli.md#two-front-doors).
