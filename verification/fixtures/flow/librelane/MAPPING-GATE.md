# G1: ASIC mapping hit rate, measured

**Result: 98 of the worst 100 setup endpoints (98%) map to a user RTL
register through the synthesis netlist JSON sidecar. Outcome: `>=90`.** ASIC
cross-probe ships labelled "nearest register".

The rule was fixed before the measurement and is applied as written: on a real
LibreLane run (sky130A, a design with at least 500 flip-flops, post-CTS,
post-resizer), the share of the worst 100 setup endpoints whose register maps
to a user RTL register through the `<netlist>.json` sidecar. At least 90%:
ASIC cross-probe ships labelled "nearest register". 60 to 90%: it ships with
per-path fidelity and an "unmapped" share in the path table header. Below
60%: ASIC paths ship with endpoint names only and RTL mapping is FPGA-only.
The threshold does not move.

## Design

PicoRV32, `picorv32` core as top (`designs/picorv32/picorv32.v`), upstream
`https://github.com/YosysHQ/picorv32` at commit
`87c89acc18994c8cf9a2311e871818e87d304568`, SHA-256
`0836050971b3c6cdd28ac3b1e5719a67fb645161912bef1e472e63995ceb0622`, ISC
licence (notice kept in the file header). Default parameters, so the 31 by
32-bit register file is built from flip-flops. Configuration
`designs/picorv32/config.yaml`: 25 ns clock, 35% core utilisation, every other
setting LibreLane's default. The design was chosen before any number was read.

The run has **1,597 sequential cells** (`design__instance__count__class:sequential_cell`
in `final/metrics.json`), against the gate's minimum of 500.

## Run

LibreLane 3.0.16 (Classic flow), sky130A, `sky130_fd_sc_hd`, PDK
`8afc8346a57fe1ab7934ba5a6056ea8b43078e71` through ciel. The run completed
with exit status 0. The endpoints come from the post-PnR STA step
(`55-openroad-stapostpnr`), which runs after clock tree synthesis
(`35-openroad-cts`), the post-CTS resizer (`37-openroad-resizertimingpostcts`)
and detailed routing, on the extracted parasitics.

## Command

Inside LibreLane's Nix shell, from the repository root:

```
tool/flow/regen_librelane_fixtures.sh --case g1
```

which runs, in a scratch copy of `designs/picorv32/`,

```
librelane --pdk sky130A --run-tag g1 config.yaml
python3 -I tool/flow/measure_g1_mapping.py runs/g1 --rtl picorv32.v --top picorv32 --json g1.json
```

`3.0.16/g1.json` is that output. `3.0.16/g1.expected.json` holds the outcome
and is checked by `test/static/flow_librelane_fixtures_test.dart`; the weekly
`flow-live.yml` job reruns the design and fails if the outcome moves.

## Method

`measure_g1_mapping.py` reads only LibreLane's records and an independent
Yosys elaboration of the RTL. It shares no code with the product's readers.

1. **Worst 100 endpoints.** `55-openroad-stapostpnr/nom_tt_025C_1v80/max.rpt`
   is OpenSTA's `report_checks -sort_by_slack -path_delay max -group_path_count
   1000`, one path per endpoint. The 100 smallest slacks, one per endpoint.
   The nominal corner is LibreLane's default timing corner.
2. **Join.** The synthesis step writes `picorv32.nl.v` (`write_verilog
   -noattr`) and `picorv32.nl.v.json` (`write_json`) from the same design.
   Rebuilding `write_verilog`'s `_NNN_` names (`$` wires, then `$` cells,
   sorted, numbered after the highest existing `_NNN_`) joined 6,704 of 6,704
   cells to instance names in `picorv32.nl.v`.
3. **Register.** The public sidecar nets on the endpoint flip-flop's Q pin name
   the register (`cpuregs[21][19]`). The endpoint maps when that name, with
   trailing bit and word selects removed, is a register of the RTL alone:
   every flip-flop output and memory of `yosys read_verilog picorv32.v;
   hierarchy -top picorv32; proc; flatten; memory -nomap` (120 names, 1,825
   bits).

## Numbers

| Measure | Value |
|---|---|
| Endpoints counted | 100 |
| Map to an RTL register | **98** |
| Output ports (no register) | 2 (`mem_la_write`, `mem_la_read`) |
| Flip-flop endpoints not in the sidecar | 0 |
| Flip-flop endpoints whose Q nets name no RTL register | 0 |
| Distinct registers among the 98 | 1 (`cpuregs`, the register file) |

The worst 100 are dominated by the register file's write paths. Two context
measurements, taken with the same tool and not part of the gate:

- **The slow corner** (`max_ss_100C_1v60`): 100 of 100 map (97 register-file
  bits, 3 bits of other vectors).
- **Every flip-flop, whatever its slack:** of the 1,597 sequential instances
  in `final/nl`, all 1,597 are in the sidecar and 1,579 (98.9%) map, to 89
  distinct RTL registers. The 18 that do not: 5 whose Q pin carries no public
  net, and 13 whose only public net is an output port name
  (`mem_la_wdata[*]`), which is not an RTL register. Only 553 of the 1,597
  carry a `src` span into `picorv32.v` on the cell itself; the rest, the
  register file included, are found by their Q net's name.

## What the label can and cannot claim

- The register file's flip-flops come from `memory_map`. Neither the cell nor
  its Q net carries a `src` attribute, so for them the sidecar gives the
  register name only; the declaration line comes from the RTL elaboration.
- Endpoints that are output ports have no register; the path table shows the
  port name.
- One design, one PDK, one LibreLane release. The measurement is repeated on
  the newest LibreLane release before 1.2 ships.
