# Migrating from VUnit

VUnit and SimCrux solve overlapping problems from opposite directions.
VUnit is a Python library you write a `run.py` against; it discovers
tests by scanning your HDL for `run("...")` calls, and its `run.py` is
imperative code. SimCrux is a declarative `simcrux.yaml` plus a GUI and a
CI runner.

That difference sets the shape of the migration: **the imperative parts
of `run.py` become explicit YAML, and the discovery has to be written
out.**

Read [what every migration has in common](index.md) first.

## Concept map

| VUnit | SimCrux |
| --- | --- |
| `run.py` | `simcrux.yaml` (declarative — there is no scripting hook) |
| `vu.add_library("lib")` | No library concept. Sources are a flat list per test. |
| `lib.add_source_files("rtl/*.vhd")` | `sources:` — **no glob expansion**; list the files, or point at a `.f` filelist |
| `vunit_proc`/`run("test name")` discovery | Not available. Every test is an explicit `tests[]` entry. |
| A testbench entity | `top:` |
| `tb.add_config(name=…, generics=…)` | `parameters:` (see the caveat below) |
| `lib.set_generic(...)` | `parameters:` — id/sweep only today |
| `lib.add_compile_option("ghdl.a_flags", …)` | No equivalent. GHDL always runs with `--std=08 --ieee=synopsys` and takes no extra flags |
| `--num-threads N` | `--max-parallel N` / `-j N` (CI mode) |
| `--xunit-xml out.xml` | `--export junit=out.xml` |
| `vu.set_sim_option("disable_ieee_warnings", …)` | No equivalent |
| VUnit's `check`/`log` pass criteria | `pass_fail:` — `exit_code`, `string_match`, `regex`, `uvm_report`, `composite`, `use` |
| Seeds via `--seed` | `seed:` / `seeds:` — but GHDL only records the seed; it does not reach a VHDL testbench |
| `--gui` | **Debug in WaveCrux** on a test with a captured waveform |
| `vu.main()` exit code | `--ci` + `--fail-threshold` |

## The three things that actually cost you time

### 1. Discovery

VUnit finds your tests. SimCrux does not. If `run.py` today is

```python
vu = VUnit.from_argv()
lib = vu.add_library("lib")
lib.add_source_files("rtl/*.vhd")
lib.add_source_files("tb/*.vhd")
vu.main()
```

…then VUnit is scanning `tb/*.vhd` for `run("…")` calls and materializing
one test per call. In SimCrux each of those becomes a `tests[]` entry
with an explicit `name` and `top`.

For a one-off conversion, generate the YAML with a script that greps your
testbenches for `run("...")` and emits the list, then commit the result
and maintain it by hand. The explicitness is the point — the file is
reviewable and a renamed testbench fails loudly instead of silently
dropping coverage.

### 2. Libraries

SimCrux has no library concept. VHDL compiled into `lib` is, to SimCrux,
just a list of `sources:` analysed by GHDL, in order, into its default
`work` library inside the test's working directory. Where VUnit's library
partitioning was doing real work — `work` vs a vendor library — analyse
the vendor library yourself once and list its directory under
`include_dirs:`, which SimCrux passes to GHDL as `-P<dir>` library search
paths; otherwise keep the ordering explicit in `sources:`.

### 3. Generics

This is the sharp edge. VUnit's `add_config(generics=...)` genuinely
passes generics to the simulator. SimCrux's `parameters:` currently
**forms the test id and drives sweep expansion, but is not emitted onto
any simulator command line.**

So:

```python
for width in [8, 16, 32]:
    tb.add_config(name=f"w{width}", generics=dict(WIDTH=width))
```

becomes

```yaml
- name: alu
  top: tb_alu
  parameters:
    WIDTH: ['8', '16', '32']
```

which produces `alu_suite/alu+WIDTH=8`, `+WIDTH=16`, `+WIDTH=32` — three
distinct, separately-reported tests — but the value does not reach GHDL.
Until that lands, either bake the widths into three separate testbench
entities, or drive them through a mechanism the simulator does see. Note
too that a parameter sweep is a SimCrux Pro feature: an open-core build runs the test once
and shows an advisory saying so ([details](../trends-and-flaky.md#sweeps)).

## Worked example

### Before

```python
from vunit import VUnit

vu = VUnit.from_argv()
lib = vu.add_library("lib")
lib.add_source_files("rtl/pkg.vhd")
lib.add_source_files("rtl/fifo.vhd")
lib.add_source_files("tb/tb_fifo.vhd")
lib.set_compile_option("ghdl.a_flags", ["--std=08"])
vu.main()
```

with `tb_fifo.vhd` containing `run("empty")`, `run("full")` and
`run("wrap")`.

### After

```yaml
version: '1'

defaults:
  simulator: ghdl        # always --std=08, which covers the old a_flags
  timeout: 120s
  pass_fail:
    type: exit_code
  waveform:
    capture: on_failure
    format: ghw

suites:
  fifo:
    description: FIFO unit tests
    sources:
      - rtl/pkg.vhd
      - rtl/fifo.vhd
      - tb/tb_fifo.vhd
    tests:
      - { name: empty, top: tb_fifo_empty }
      - { name: full,  top: tb_fifo_full }
      - { name: wrap,  top: tb_fifo_wrap }
```

```bash
simcrux simcrux.yaml --ci --export junit=report.xml
```

Note the shape change: VUnit runs many `run("…")` cases inside one
entity; SimCrux's unit of scheduling is a `top`. If your testbenches
multiplex cases through a runner string, either split them into separate
entities, or accept one SimCrux test per entity and keep the internal
case list as detail inside the log.

## Mapping VUnit's pass criteria

VUnit decides pass/fail from its own runner protocol. SimCrux classifies
from the log and the exit code. Pick the detector that matches what your
testbench already prints:

| Your testbench… | Detector |
| --- | --- |
| returns a non-zero exit code on failure | `exit_code` (the default) |
| prints a banner | `string_match` with `pass_string` / `fail_string` |
| prints structured errors | `regex` with `pass_pattern` / `fail_pattern` |
| uses UVM reporting | `uvm_report` with severity thresholds |
| needs several of the above | `composite` with `all_of` / `any_of` |
| shares a house policy across projects | `use` referencing a named detector from `Settings → Detectors` |

`regex` runs multi-line by default, so `^` and `$` match line boundaries.
It uses Dart (JavaScript-style) syntax with no `(?i)` prefix — write case
variants as character classes. Catastrophic patterns are abandoned after
one second rather than hanging the run.

## Things you gain

- A results dashboard, an inspector, and per-test log/waveform artifacts
  without a separate viewer.
- Waveform capture policy as configuration (`always` / `on_failure` /
  `on_demand` / `never`). In the desktop app, retained failure directories
  are pruned automatically — the 50 most recent, 2 GiB at most — and a
  `.simcrux-keep` marker file pins a directory you want to survive pruning.
- Named resource locks for license-limited tools.
- Cross-probe into WaveCrux straight from a failing test — see
  [Cross-probe & the suite](../integrations.md#deep-link).
- Mixed-language validation at config-load time: a test whose sources a
  simulator cannot handle fails to load with a clear message instead of
  failing obscurely mid-run.

## Things you lose

- Test discovery.
- Libraries as a first-class concept.
- Generics actually reaching the simulator (today).
- Arbitrary Python in the run flow. `simcrux.yaml` is data, not code —
  if `run.py` computes its test matrix, generate the YAML from the same
  script and commit the output.
