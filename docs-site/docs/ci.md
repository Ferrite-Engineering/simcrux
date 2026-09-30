# CI recipes

SimCrux's `--ci` mode wires straight into every common CI provider. This page
has ready-made jobs; the flags themselves are on [Command line & CI](cli.md),
and exports and baselines on [Baselines, CI & exports](baselines-ci-exports.md).

## Getting `simcrux` onto the runner

A CI node needs the headless `simcrux` binary and the simulators your
tests use. Build the binary from a SimCrux checkout — it is a single
executable with no Flutter engine or display-server dependency:

```bash
git clone --recurse-submodules https://github.com/Ferrite-Engineering/simcrux.git
cd simcrux
flutter pub get
tool/build_cli.sh                     # → build/cli/bundle/bin/simcrux
```

Cache it or publish it as an internal artifact, and put it on the
runner's `PATH`. The recipes below assume that has been done.

## GitHub Actions

```yaml
- name: Run regression
  run: |
    simcrux simcrux.yaml --ci \
      --export junit=results/report.xml \
      --export html=results/dashboard.html

- name: Publish JUnit report
  if: always()
  uses: dorny/test-reporter@v1
  with:
    name: simcrux
    path: results/report.xml
    reporter: java-junit

- name: Upload dashboard
  if: always()
  uses: actions/upload-artifact@v4
  with:
    name: simcrux-dashboard
    path: results/dashboard.html
```

`--export` creates the output directory when it does not exist. If a report
still cannot be written (a read-only path, say), the run prints its summary,
writes the other exports, reports the failure on stderr and exits `2`.

## GitLab CI

```yaml
test:
  script:
    - simcrux simcrux.yaml --ci --export junit=results/report.xml
  artifacts:
    when: always
    reports:
      junit: results/report.xml
```

## Jenkins

```groovy
sh 'simcrux simcrux.yaml --ci --export junit=results/report.xml'
junit 'results/report.xml'
```

In the JUnit report, failed and timed-out tests are `<failure>` elements;
`unknown` and cancelled tests are `<error>` elements, so a run SimCrux could
not classify never reads as green.

!!! note "Self-hosted runners"
    `--ci` keeps the working directory of each failing test, including its
    waveform dump, under the system temp directory, and prunes those
    directories to the 50 most recent (2 GiB at most) at the end of every run.
    An empty `.simcrux-keep` file in a directory pins it.

## Fail thresholds

Set `--fail-threshold N` to tolerate up to `N - 1` failures before
marking the build red. Failed, timed-out and `unknown` tests all count.
Useful when you have a small known set of quarantined tests:

```bash
simcrux simcrux.yaml --ci --fail-threshold 4
# fails the build only if 4 or more tests fail
```

## Dashboard publishing

The `--export html=…` target produces a single self-contained HTML
file with sortable headers, status-chip filtering, and substring
search. It works offline, has zero external dependencies, and can
be published as a CI artifact directly. The same file is suitable
for static hosting (GitHub Pages, S3, etc.) when you want a
shareable URL per run. It shows the config path as it was passed on the
command line and each failing test's failure message — check both before
publishing somewhere public.

For the full read-only web dashboard instead of a single file, see
[Publishing the results dashboard](ci-integration.md).

## JSON output

The `--json` flag prints a compact totals summary on stdout in
addition to triggering `--ci` mode:

```bash
simcrux simcrux.yaml --json | jq '.totals'
```

Keys are status names (`pass`, `fail`, `timeout`, `unknown`, …) and only
statuses that occurred appear. That one JSON document is all stdout carries,
whatever else is on the command line: export confirmations
(`wrote junit → report.xml`), warnings and errors go to stderr. So the pipe
above still parses with `--export`, `--fail-on-regression` or any other flag
added.
