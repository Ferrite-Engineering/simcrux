# Migrating from Makefiles

A simulation Makefile usually encodes five things: the source list, the
build flags, the list of tests, how to tell a pass from a fail, and how
to run several at once. SimCrux takes over all five, declaratively.

Read [what every migration has in common](index.md) first — especially
the "no discovery" and "what SimCrux does not have" sections.

## Concept map

| Makefile idiom | SimCrux |
| --- | --- |
| `SRCS = rtl/a.v rtl/b.v` | `sources:` (suite-level for shared files, test-level for the rest) |
| `INCDIRS = -Irtl/include` | `include_dirs:` |
| `DEFINES = -DSYNTH=1` | `defines: { SYNTH: '1' }` |
| `TOP = tb_alu` | `top:` (required, per test) |
| `iverilog` / `verilator` / `ghdl` hardcoded in a rule | `simulator:` at `defaults:`, suite or test level |
| One phony target per test | One entry in `suites.<name>.tests[]` |
| `grep "TEST PASSED" $(LOG)` | `pass_fail: { type: string_match, pass_string: TEST PASSED }` |
| `$? != 0` | `pass_fail: { type: exit_code }` (the default) |
| `make -j8` | `--max-parallel 8` (CI mode) |
| `timeout 300 ...` | `timeout: 300s` |
| `.NOTPARALLEL` on a license-limited tool | `resources: [ <lock-name> ]` |
| `include common.mk` | `includes:` |
| A `-f` filelist you already generate | keep it — put the `.f` in `sources:` |
| `RANDOM_SEED=$(SEED)` | `seed:` / `seeds:` |
| `make wave` | `waveform: { capture: always }` |

## Worked example

### Before

```make
IVERILOG ?= iverilog
VVP      ?= vvp
INC      := -Irtl/include
DEFS     := -DSYNTHESIS=1
COMMON   := rtl/pkg.sv rtl/alu.sv

TESTS := alu_basic alu_carry

.PHONY: all $(TESTS)
all: $(TESTS)

alu_basic:
	$(IVERILOG) -g2012 $(INC) $(DEFS) -o build/$@.vvp -s tb_alu_basic \
	    $(COMMON) tb/tb_alu_basic.sv
	$(VVP) build/$@.vvp | tee build/$@.log
	grep -q "TEST PASSED" build/$@.log

alu_carry:
	$(IVERILOG) -g2012 $(INC) $(DEFS) -o build/$@.vvp -s tb_alu_carry \
	    $(COMMON) tb/tb_alu_carry.sv
	$(VVP) build/$@.vvp | tee build/$@.log
	grep -q "TEST PASSED" build/$@.log
```

### After

```yaml
version: '1'

defaults:
  simulator: icarus
  timeout: 300s
  pass_fail:
    type: string_match
    pass_string: TEST PASSED
    fail_string: TEST FAILED
  waveform:
    capture: on_failure
    format: fst

suites:
  alu:
    description: ALU unit tests
    sources:
      - rtl/pkg.sv
      - rtl/alu.sv
    include_dirs:
      - rtl/include
    defines:
      SYNTHESIS: '1'
    tests:
      - name: basic
        top: tb_alu_basic
        sources: [tb/tb_alu_basic.sv]
      - name: carry
        top: tb_alu_carry
        sources: [tb/tb_alu_carry.sv]
```

```bash
simcrux simcrux.yaml --ci -j 8
```

Test ids are `alu/basic` and `alu/carry`.

Note what disappeared: the `-o`/`-s`/`vvp` plumbing, the `tee`, the
`grep`, and the per-test duplication. SimCrux builds the Icarus command
line (`iverilog -g2012 -o sim.vvp -s <top> -I… -D… <sources>`, then
`vvp sim.vvp`), captures the log, and classifies it. The generation is
fixed at `-g2012`.

## Translating the tricky bits

### "My rule appends a raw flag for one test"

There is no raw-argument list, per test or per simulator. Your options:

- Move the flag into `defines:` or `include_dirs:` if it is really one of
  those.
- If the tool reads the setting from an environment variable, set it for
  the whole simulator through `simulators.<id>.env`.
  (`simulators.<id>.options` does not help here: only the cocotb driver
  reads it.)
- If it genuinely must be a raw flag, that test is a candidate for
  staying in a Makefile for now.

### "My rule loops over seeds"

```make
for s in 1 2 3 4 5; do $(VVP) build/$@.vvp +seed=$$s; done
```

becomes

```yaml
- name: random
  top: tb_alu_random
  seeds: ["1..5"]        # or [1, 2, 3, 4, 5]
```

which expands into five tests with ids `alu/random+seed=1` … `+seed=5`.
The effective seed is injected per simulator — `+seed=N` for Icarus,
`+verilator+seed+N` for Verilator, `RANDOM_SEED` in the environment for
cocotb. GHDL is report-only: the seed is recorded but not injected.

Sweeps are a SimCrux Pro feature: the 0.8.x public beta expands them in every
build, and from 1.0 an open-core build runs a `seeds:` list once and shows an
[advisory](../trends-and-flaky.md#sweeps) that says so.
`seed: N` — one pinned seed — works everywhere, in every tier.

### "My rule sweeps a parameter"

```yaml
- name: widths
  top: tb_alu
  parameters:
    WIDTH: ['8', '16', '32']
```

expands to three tests with ids `alu/widths+WIDTH=8` etc.

**Caveat:** parameters currently form the test id and drive the sweep,
but are **not** emitted onto the simulator command line. If elaboration
needs the value, use `defines:` for Verilog/SystemVerilog. Like `seeds:`,
a parameter sweep is expanded in every 0.8.x beta build and needs SimCrux Pro
from 1.0.

One test entry may expand to at most 10,000 tests, so a careless
three-axis sweep fails to load rather than melting your machine.

### "I use `.NOTPARALLEL` because of a floating license"

```yaml
resources:
  - questa_license
```

Any two tests naming the same resource never run concurrently. Suite-level
and test-level `resources:` are merged.

### "My recipe has a timeout wrapper"

`timeout: 90s` (or `90`, or `1m`). SimCrux sends SIGTERM, waits 5
seconds, then SIGKILL, and reaps the whole process tree — including
cocotb's grandchildren, which is the failure mode a `timeout(1)` wrapper
usually gets wrong.

### "My CI greps the log for UVM errors"

```yaml
pass_fail:
  type: uvm_report
  fatal_threshold: 1
  error_threshold: 1
  warning_threshold: 0   # 0 disables the warning check
```

SimCrux parses the UVM report summary rather than pattern-matching the
whole log.

### "Different rules need different pass criteria"

`pass_fail:` is inheritable at all three levels, and `composite` combines
detectors:

```yaml
pass_fail:
  type: composite
  all_of:
    - { type: exit_code }
    - { type: string_match, pass_string: 'PASS' }
```

## Suggested order of work

1. Convert **one** suite. Get `simcrux simcrux.yaml --ci` green.
2. Move the shared flags up into `defaults:` and the suite level, and
   delete the duplication.
3. Move house-wide settings into a shared file and pull it in with
   `includes:`.
4. Point CI at `--ci --export junit=report.xml --fail-threshold 1` and
   retire the Makefile targets you have replaced.
5. Keep the Makefile for anything SimCrux cannot express yet — the two
   can coexist indefinitely.
