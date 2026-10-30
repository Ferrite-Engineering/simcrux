# ROHD + EDACrux, from SimCrux 1.2

[ROHD](https://github.com/intel/rohd) is Intel's open-source hardware framework written in Dart. You describe hardware as Dart classes, simulate it in Dart, and test it with `package:test` and, for larger environments, ROHD-VF. This page is for ROHD users. It shows how to run your ROHD tests from SimCrux as a regression, or read results your CI already produced, and what SimCrux shows for ROHD-VF failures.

!!! note "From SimCrux 1.2"

    The `dart_test` simulator is from SimCrux 1.2. It reads the results of any `package:test` suite, so reading them needs nothing from ROHD itself. Features that belong to ROHD's source tracing carry the label **ROHD 0.7 or later (source tracing)**. The other EDACrux apps have the same kind of page: [NetCrux](https://docs.netcrux.app/rohd-and-edacrux), [WaveCrux](https://docs.wavecrux.app/rohd-and-edacrux) and [LintCrux](https://docs.lintcrux.app/rohd-and-edacrux).

## What SimCrux does with ROHD tests

| You have | SimCrux | Where |
|---|---|---|
| A Dart package with ROHD tests | Runs `dart test` as a test in your regression, next to your Verilog, VHDL and cocotb tests. | [Run the tests from SimCrux](#run) |
| A `dart test` JSON report from CI | Reads it without running anything. | [Read results you already have](#import) |
| A ROHD-VF environment | Shows a ROHD-VF failure as **Failed**, splits its log lines, and counts objection warnings. | [ROHD-VF](#rohd-vf) |
| A failing case | **Go to Source** opens your editor at the line where it failed. | [What you see](#see) |

## A ROHD test SimCrux can run {#test}

SimCrux runs any `package:test` suite. A ROHD test looks like this:

```dart
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('adder adds', () async {
    final a = Logic(width: 8), b = Logic(width: 8);
    final adder = Adder(a, b);               // your module
    await adder.build();

    a.put(3);
    b.put(4);
    expect(adder.sum.value.toInt(), 7);
  });
}
```

Save it as `test/adder_test.dart` in your package.

## Run the tests from SimCrux {#run}

Give the test a `dart_test` simulator and list the Dart test files under `sources`. `top` is required for every test and is only a label here.

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

SimCrux runs `dart test --file-reporter json:<run folder>/dart-test.json` in the package, which is the nearest folder at or above the first source that holds a `pubspec.yaml`, and keeps the console output as the run's log. Set `parameters.package_dir` to name the package yourself, and leave `sources` empty to run the package's whole `test/` folder. The row passes when no case failed or errored, and the individual cases are listed in the inspector.

Run it from the command line, for example in CI:

```bash
simcrux simcrux.yaml --ci --export junit=results/report.xml
```

See [Command line & CI](cli.md) and [CI recipes](ci.md).

!!! note "Project code runs"

    As with a cocotb `Makefile`, running a Dart test runs the project's own code. Opening a project never runs it.

## Read results you already have {#import}

List a `dart test` JSON report under `sources` instead, and SimCrux reads it without running anything. This suits a run your CI already made:

```bash
dart test --reporter json > results/rohd.jsonl
```

```yaml
      - name: nightly_rohd
        simulator: dart_test
        top: rohd_adder
        sources: [results/rohd.jsonl]
        parameters:
          package_dir: /work/my_rohd_project   # so locations resolve to your files
```

`dart test --file-reporter json:results/rohd.jsonl` writes the same report next to the normal console output. A file that is not a `dart test` report is reported as such. A report cut off before its final event shows the cases that did finish, marks the run as not finished, and fails the row.

## What you see {#see}

Select the row. The inspector's **Dart tests** section lists every case, failing cases first, with its status, duration and the first line of its error. Each case has a **Go to Source** button that opens your editor (`Settings → Editors`) at the line in your own code where the failure happened, or at the line where the test is declared for a case that passed.

## ROHD-VF {#rohd-vf}

[ROHD-VF](https://github.com/intel/rohd-vf) is the verification framework built on ROHD.

- **Failures.** A ROHD-VF `Test` reports a failure by throwing `Exception: Test failed.` after the simulation, so `dart test` records it as an error. SimCrux recognises it and shows the case as **Failed**, the same as a failed `expect`. An ordinary exception stays **Error**.
- **Log lines.** ROHD-VF logs reach `dart test` as text like `[SEVERE] @ 1250 | top.env.monitor: message`. SimCrux splits them into severity, simulated time, logger and message.
- **Objections.** When ROHD-VF warns that the simulation ended before all objections were dropped, the inspector says so and counts the warnings.
- **Seeds.** ROHD-VF uses the seed you pass to `Test(randomSeed:)` and otherwise a random one that it does not print. SimCrux cannot show a seed that is never logged, so to make a failure reproducible, pass a seed yourself and log it.

[Dart tests and ROHD](rohd.md) has the details and the limits.

## Across runs

In every edition the results dashboard shows a history sparkline of the last ten runs of each test. With <span class="tier tier-pro">Pro</span>, [trends, flaky-test detection and seed sweeps](trends-and-flaky.md) work across many runs, which is useful for ROHD testbenches that use random stimulus.

## Cross-probe with the other apps {#cross-probe}

SimCrux, NetCrux, WaveCrux and LintCrux find each other on the same machine and talk over **CXP**, the cross-probe protocol. SimCrux can send the selected test to a running EDACrux app. See [Cross-probe & the suite](integrations.md#cxp).

### From your own Dart code, coming with EDACrux 1.2

A Dart package, `edacrux_cxp`, is coming with EDACrux 1.2. It is a pure-Dart CXP client with no Flutter dependency, so a running ROHD simulation or test can ask WaveCrux to show a signal and NetCrux to highlight a net. It is not published yet, so there is nothing to add to your `pubspec.yaml` today.

## Related

- [Dart tests and ROHD](rohd.md)
- [Projects & simulators](projects-and-simulators.md)
- [Command line & CI](cli.md)
- [Trends, flaky tests & seeds](trends-and-flaky.md)
