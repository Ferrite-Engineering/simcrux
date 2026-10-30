# Dart tests and ROHD

SimCrux runs and reads the tests of a Dart project, which is how a
[ROHD](https://github.com/intel/rohd) testbench or a ROHD-VF environment becomes
a regression run next to your Verilog, VHDL and cocotb tests. It works with any
`package:test` suite; the ROHD-VF details below apply when ROHD-VF is in use.

This is from SimCrux 1.2. For the whole path from ROHD to SimCrux, see
[ROHD + EDACrux](rohd-and-edacrux.md).

This feature is labelled **ROHD 0.7 or later (source tracing)** because the
source locations that Go to Source opens come from Dart's own stack traces and
test declarations, and the companion features for generated SystemVerilog and
waveforms read ROHD's source-trace files, which first ship with ROHD 0.7.
Reading `dart test` results needs nothing from ROHD itself.

## Run the tests from SimCrux {#run}

Give the test a `dart_test` simulator and list the Dart test files under
`sources:`. `top:` is required for every test and is only a label here.

```yaml
version: '1'
suites:
  rohd:
    tests:
      - name: adder_testbench
        simulator: dart_test
        top: rohd_adder
        sources:
          - test/adder_test.dart
        timeout: 5m
```

SimCrux runs `dart test --file-reporter json:<run folder>/dart-test.json` in the
package, which is the nearest folder at or above the first source that holds a
`pubspec.yaml`. The console output of `dart test` is kept as the run's log.
Set `parameters.package_dir` to an absolute path to name the package yourself,
and leave `sources:` empty to run the package's whole `test/` folder.

The row passes when no case failed or errored. One SimCrux test is one run of
`dart test`, the way one cocotb test is one `make`; the individual cases are
listed in the inspector.

!!! note "Project code runs"
    As with a cocotb `Makefile`, running a Dart test runs the project's own code.
    Opening a project never runs it.

## Read results you already have {#import}

List a `dart test` JSON report under `sources:` instead, and SimCrux reads it
without running anything. This suits a run CI already made, or a report written
with `dart test --reporter json > results.jsonl`.

```yaml
      - name: nightly_rohd
        simulator: dart_test
        top: rohd_adder
        sources: [results/rohd.jsonl]
        parameters:
          package_dir: /work/my_rohd_project   # so locations resolve to your files
```

A file that is not a `dart test` report is reported as such, and the row's
status is Unknown. A report cut off before its final event shows the cases that
did finish, marks the run as not finished, and fails the row.

## What you see {#see}

Select the row. The inspector's **Dart tests** section lists every case, failing
cases first, with its status, duration and the first line of its error. For a
failing case it also shows the first ROHD-VF SEVERE log lines. Each case has a
**Go to Source** button that opens your editor (Settings > Editors) at:

- the line in your own code where the failure happened, taken from the first
  stack frame that is not the test runner, `package:matcher` or ROHD itself; or
- the line where the test is declared, for a case that passed or has no frame in
  your code.

## ROHD-VF specifics {#rohd-vf}

**Failures.** A ROHD-VF `Test` reports a failure by throwing
`Exception: Test failed.` after the simulation, so `dart test` records it as an
error rather than a failure. SimCrux recognises the `Test._checkAll` frame in
that stack and shows the case as **Failed**, the same as a failed `expect`. An
ordinary exception stays **Error**.

**Log lines.** ROHD-VF logs reach `dart test` as text of the form
`[SEVERE] @ 1250 | top.env.monitor: message`. SimCrux splits them into severity,
simulated time, logger and message. The log you open from the inspector keeps
the original lines.

**Objections.** When ROHD-VF warns that the simulation ended before all
objections were dropped, the inspector says so and counts the warnings. The
warning carries no component name or count of its own, so SimCrux can only
report that it appeared.

**Seeds.** ROHD-VF uses the seed you pass to `Test(randomSeed:)` and otherwise a
random one that it does not print. SimCrux cannot show a seed ROHD-VF never
logs, so to make a failure reproducible pass a seed yourself and log it.

## Limits {#limits}

- Only `dart test` is run; Flutter widget tests need `flutter test` and are not
  supported by this driver.
- The inspector lists the first 2000 cases of a run, and keeps the error, stack
  and log lines of the first 100 cases that did not pass.
- Tracker files that ROHD-VF writes are not attached to the row.
