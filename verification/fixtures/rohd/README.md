# ROHD fixtures (ROHD 0.7 or later, source tracing)

`dart-test.json` is real `dart test --file-reporter json` output over four
tests: a plain ROHD adder test that passes and one that fails an `expect`, and a
ROHD-VF test that passes and one that fails (a ROHD-VF failure arrives as
`result: error` with `Exception: Test failed.`). The failing ROHD-VF run logs
SEVERE lines and ends with the objection warning.

## Provenance

| Input | Pinned to |
|---|---|
| `intel/rohd` (BSD-3-Clause) | `2d84f73abfb1ba95c64d218e9b13a12e8416249c`, `main` on 2026-10-27, which is ROHD 0.6.11 plus source tracing (the work released as 0.7) |
| `intel/rohd-vf` (BSD-3-Clause) | `dd830d3b83438dfa5a06b0f0d8841eca16e97046` |
| Dart SDK | 3.13.5 |

The design (`generator/design.dart.txt`) and the test (`generator/probe_test.dart.txt`)
are ours. Only the output of running them against ROHD is kept here, and ROHD
is licensed BSD-3-Clause. Absolute paths on the machine that generated the
files are rewritten to `/work/rohd_fixture` and `/pub-cache`.

## Regenerate

```bash
verification/fixtures/rohd/generator/generate.sh <empty work dir> verification/fixtures/rohd dart-test.json
```

It needs network access the first time, for the two git dependencies. The
generator is shared with the same fixtures in the other crux products, which
also take `top.sv`, `Top.flc.json` and `top.vcd`; this repo only needs the
test report.

The `.txt` suffix on the generator's Dart sources keeps the analyzer and the
formatter from treating them as part of this package.
