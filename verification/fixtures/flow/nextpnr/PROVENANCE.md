# nextpnr fixtures: provenance

Captured place-and-route runs for iCE40, ECP5, Gowin and GateMate, plus the
RTL that produced them. Consumers: the nextpnr report and log readers, the
timing verdict, and the RTL mapping of a critical path.

## Tools and date

Captured on 2026-10-21 with OSS CAD Suite tag `2026-10-21`, darwin-arm64
(release digest `sha256:0a4265dc...b7b273`):

| Tool | Version |
|---|---|
| Yosys | 0.70+186 (git 3718f7f13) |
| nextpnr-ice40, nextpnr-ecp5, nextpnr-himbaechel | 0.11.1-77-g6b438a1c |

`versions.txt` holds the exact lines the tools printed. The weekly workflow
(`.github/workflows/flow-live.yml`) installs the Linux x64 build of the same
tag, pinned by tag and SHA-256, and re-checks every expectation against it.

Drift check, same regenerator, same RTL, two earlier suites (2026-09-21 with
Yosys 0.69+77 and nextpnr 0.11.1-30, 2026-08-21 with Yosys 0.68+118 and
nextpnr 0.11.1-8): all eleven exit statuses and all eleven PASS or FAIL
verdicts were identical. Frequencies and placement moved on every build (for
example `rescreen_ice40` ends at 41.86, 43.48 and 44.03 MHz), so no
expectation pins a number.

## Command

```
tool/flow/regen_nextpnr_fixtures.sh --suite <oss-cad-suite dir>
```

Per case, in a scratch directory with the RTL copied in (so `src` attributes
read `path_adder.v:16.14-16.27`, never an absolute path):

```
yosys -q -p "read_verilog <rtl>; <synth_*> -top <top> -json netlist.json"
<nextpnr> <device flags> --json netlist.json --freq <MHz> \
    --report report.json --detailed-timing-report --log pnr.log
```

| Family | Synthesis | Place and route |
|---|---|---|
| iCE40 | `synth_ice40` (`-dsp` for `rescreen_ice40_dsp`) | `nextpnr-ice40 --up5k --package sg48` |
| ECP5 | `synth_ecp5` | `nextpnr-ecp5 --25k --package CABGA256` |
| Gowin | `synth_gowin` | `nextpnr-himbaechel --device GW1NR-LV9QN88PC6/I5 --vopt family=GW1N-9 --vopt cst=path_adder_gowin.cst` |
| GateMate | `synth_gatemate -luttree` | `nextpnr-himbaechel --device CCGM1A1 --vopt allow-unconstrained` |

The exit status is captured in `exit_code.txt`. The regenerator rewrites the
scratch directory, the home directory and the suite's install-relative Yosys
share path (`<work>`, `<home>`, `<yosys-share>`) in every capture, and fails
if any machine path survives. The measured `report.json` of the earlier
re-screen carried one scratch path; these do not.

## Cases

| Case | RTL | Constraint | Verdict |
|---|---|---|---|
| `rescreen_ice40` | `rtl/top.v` | 100 MHz | violated, exit 1 |
| `rescreen_ice40_dsp` | `rtl/top.v` | 100 MHz | violated, exit 1 |
| `rescreen_ecp5` | `rtl/top.v` | 100 MHz | met, exit 0 |
| `path_<family>_met` | `rtl/path_adder.v` | 12 MHz | met, exit 0 |
| `path_<family>_violated` | `rtl/path_adder.v` | 1000 MHz | violated, exit 1 |

`<family>` is `ice40`, `ecp5`, `gowin` or `gatemate`. A `_violated` case shares
its `_met` sibling's synthesized netlist, so it keeps no `netlist.json` of its
own. `rtl/top.v` is the re-screen's datapath (an 8 by 8 multiplier path feeding
a 16-bit add/sub accumulator), unchanged. The first-pass iCE40 report from that
re-screen has the same structural signature as `rescreen_ice40/report.json`.

## Where each expectation comes from

Nothing under a `*.expected.*` name is produced by a regenerator or by the
product's readers.

- `verdict.expected.json`: the verdict is the PASS or FAIL printed on nextpnr's
  own last `Max frequency` line (`max_frequency.txt` is the `grep` of it), and
  the exit status is nextpnr's. The constraint is the `--freq` the case was run
  with. The files were written by hand after reading that line.
- `mapping.expected.json`: written from `rtl/path_adder.v`. The only deep
  combinational path between registers is `sum_q <= src_a + src_b` (line 16),
  so the worst path starts at `src_a` or `src_b` and ends at `sum_q`, and its
  routing steps name line 16 among their `sources`. Register declaration lines
  are 10, 11 and 12.
- `fusesoc/verdict.expected.json`: the PASS or FAIL on the log line of the
  FuseSoC run, against the `--freq 16` its core file passes to nextpnr.

The tests that check them extract independently of the product's readers
(`test/static/flow_nextpnr_facts.dart`).

## Gowin and GateMate through nextpnr-himbaechel: does `report.json` match?

Measured on `path_gowin_met` and `path_gatemate_met` against the iCE40 and
ECP5 cases.

**Answer: yes, same schema.** All four reports have the same four top-level
sections (`critical_paths`, `detailed_net_timings`, `fmax`, `utilization`) and
the same value shapes: `fmax` entries are `{achieved, constraint}`,
`utilization` entries are `{available, used}`, a critical path is
`{from, to, path}`, a path step has either the keys
`delay, from, to, type` or, for `routing`, `delay, from, net, sources, to,
type`, and a net timing has `driver, endpoints, event, net, port, sources`.
`tool/flow/report_schema.jq` prints the signature and the four are equal.
`test/static/flow_nextpnr_fixtures_test.dart` keeps it that way.

What differs is vocabulary and naming, not shape:

- The set of step types is not fixed. iCE40 and ECP5 emit `clk-to-q`, `logic`,
  `routing`, `setup` and `source`. Gowin emits no `source` step. GateMate adds
  `clk-skew`. A reader must accept a step type it has not seen.
- GateMate cell names are opaque (`$auto$ff.cc:337:slice$139`), so the
  register behind a path endpoint comes from the net name and the `sources`
  span of the adjacent routing step, not from the cell name. iCE40, ECP5 and
  Gowin cell names carry the RTL register name (`src_a_SB_DFF_Q_23_DFFLC`,
  `src_b_TRELLIS_FF_Q_1`, `src_a_DFF_Q_21`).
- The number of reported critical paths varies with the clock domains the
  design produces (three, three, one and two here).
- The clock name comes from each family's I/O buffer
  (`clk$SB_IO_IN_$glb_clk`, `$glbnet$clk$TRELLIS_IO_IN`, `clk_IBUF_I_O`,
  `$iopadmap$clk`).

Consequence for the tentative rule on a second reader: the difference is not
a shape difference, so one report reader serves all four families. Gowin and
GateMate ship with it in 1.2, and RTL mapping for GateMate is labelled by the
`sources` span rather than by cell name.

Gowin needs every top-level port pinned; `rtl/path_adder_gowin.cst` pins the
three ports of the designed adder with pin numbers that place and route on
this device. GateMate takes `--vopt allow-unconstrained`, and the log's
auto-placement warnings are part of the capture.
