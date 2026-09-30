// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/services/config/config_loader.dart';
import 'package:simcrux/services/import/fusesoc_importer.dart';

void main() {
  late FuseSoCImporter importer;

  setUp(() {
    importer = FuseSoCImporter();
  });

  group('FuseSoCImporter — header validation', () {
    test('rejects a file without the CAPI=2 header', () {
      expect(
        () => importer.parse('name: foo', '/p/foo.core'),
        throwsA(isA<FuseSoCImportException>()),
      );
    });

    test('accepts a CAPI=2 header with leading comments', () {
      const yaml = '''
# A comment
# Another comment
CAPI=2:

name: ::demo:0.1.0

filesets:
  rtl:
    files:
      - rtl/top.v
    file_type: verilogSource

targets:
  sim:
    filesets: [rtl]
    toplevel: top_tb
    default_tool: icarus
''';
      final result = importer.parse(yaml, '/p/demo.core');
      expect(result.simcruxYaml, contains('top: top_tb'));
    });
  });

  group('FuseSoCImporter — single simple target', () {
    test('produces a clean simcrux.yaml with no warnings', () {
      const yaml = '''
CAPI=2:

name: ::demo:0.1.0

filesets:
  rtl:
    files:
      - rtl/top.v
      - rtl/sub.v
    file_type: verilogSource
  tb:
    files:
      - tb/top_tb.v
    file_type: verilogSource
    depend:
      - rtl

targets:
  sim:
    filesets: [tb]
    toplevel: top_tb
    default_tool: icarus
''';
      final result = importer.parse(yaml, '/p/demo.core');
      expect(result.warnings, isEmpty);
      expect(result.suggestedOutputFilename, 'demo.simcrux.yaml');
      // Round-trip through the SimCrux ConfigLoader.
      final config = ConfigLoader().parse(
        result.simcruxYaml,
        '/p/demo/simcrux.yaml',
      );
      expect(config.suites, hasLength(1));
      expect(config.suites.single.name, 'sim');
      expect(config.suites.single.tests.single.top, 'top_tb');
      expect(config.suites.single.tests.single.simulatorId, 'icarus');
      // Fileset depend chain pulls rtl files in dependency-first order.
      expect(
        config.suites.single.tests.single.sources,
        ['rtl/top.v', 'rtl/sub.v', 'tb/top_tb.v'],
      );
    });

    test('derives suggested filename from CAPI2 name vendor:lib:name:ver', () {
      const yaml = '''
CAPI=2:

name: acme:hello:world:1.2.3

targets:
  sim:
    toplevel: top
    default_tool: icarus
''';
      final result = importer.parse(yaml, '/p/anything.core');
      expect(result.suggestedOutputFilename, 'world.simcrux.yaml');
    });

    test('names the output after the core so siblings do not collide', () {
      String nameFor(String coreName, String corePath) => importer.parse('''
CAPI=2:

name: $coreName

targets:
  sim:
    toplevel: tb
    default_tool: icarus
''', corePath).suggestedOutputFilename;

      // SERV ships serv.core, servant.core, servile.core and serving.core
      // in one directory — a fixed `simcrux.yaml` made each import clobber
      // the last.
      expect(
        nameFor('award-winning:serv:serv:1.4.0', '/p/serv.core'),
        'serv.simcrux.yaml',
      );
      expect(
        nameFor('award-winning:serv:servant:1.4.0', '/p/servant.core'),
        'servant.simcrux.yaml',
      );
    });

    test('falls back to .core basename when name is missing', () {
      const yaml = '''
CAPI=2:

targets:
  sim:
    toplevel: top
    default_tool: icarus
''';
      final result = importer.parse(yaml, '/p/my_design.core');
      expect(result.suggestedOutputFilename, 'my_design.simcrux.yaml');
    });
  });

  group('FuseSoCImporter — multi-target', () {
    test('emits one suite per target with toplevel', () {
      const yaml = '''
CAPI=2:

name: ::multi:0.1.0

filesets:
  rtl:
    files:
      - rtl/cpu.v
    file_type: verilogSource

targets:
  sim_alu:
    filesets: [rtl]
    toplevel: alu_tb
    default_tool: icarus
  sim_regfile:
    filesets: [rtl]
    toplevel: regfile_tb
    default_tool: verilator
  default:
    filesets: [rtl]
    # no toplevel — packaging target, should be skipped
''';
      final result = importer.parse(yaml, '/p/multi.core');
      final config = ConfigLoader().parse(
        result.simcruxYaml,
        '/p/multi/simcrux.yaml',
      );
      expect(config.suites, hasLength(2));
      final byName = {for (final s in config.suites) s.name: s};
      expect(byName.keys, containsAll(['sim_alu', 'sim_regfile']));
      expect(byName['sim_alu']!.tests.single.simulatorId, 'icarus');
      expect(byName['sim_regfile']!.tests.single.simulatorId, 'verilator');
    });
  });

  group('FuseSoCImporter — parameters', () {
    test('routes vlogdefine to defines and vlogparam to parameters', () {
      const yaml = '''
CAPI=2:

name: ::p:0.1.0

parameters:
  WIDTH:
    datatype: int
    default: 8
    paramtype: vlogparam
  DEBUG:
    datatype: bool
    default: false
    paramtype: vlogdefine

targets:
  sim:
    toplevel: tb
    default_tool: icarus
    parameters:
      - WIDTH=16
      - DEBUG=1
''';
      final result = importer.parse(yaml, '/p/p.core');
      final config = ConfigLoader().parse(
        result.simcruxYaml,
        '/p/p/simcrux.yaml',
      );
      final test = config.suites.single.tests.single;
      expect(test.parameters['WIDTH'], '16');
      expect(test.defines['DEBUG'], '1');
    });

    test(
      'falls back to vlogdefine for an undeclared parameter (with warning)',
      () {
        const yaml = '''
CAPI=2:

name: ::p:0.1.0

targets:
  sim:
    toplevel: tb
    default_tool: icarus
    parameters:
      - UNDECLARED=42
''';
        final result = importer.parse(yaml, '/p/p.core');
        expect(
          result.warnings.map((w) => w.code),
          contains('unknown_parameter'),
        );
        final config = ConfigLoader().parse(
          result.simcruxYaml,
          '/p/p/simcrux.yaml',
        );
        expect(config.suites.single.tests.single.defines['UNDECLARED'], '42');
      },
    );

    test('flags file-typed parameters as complex and skips them', () {
      const yaml = '''
CAPI=2:

name: ::p:0.1.0

parameters:
  BLOB:
    datatype: file
    default: data.bin

targets:
  sim:
    toplevel: tb
    default_tool: icarus
    parameters:
      - BLOB=mydata.bin
''';
      final result = importer.parse(yaml, '/p/p.core');
      expect(
        result.warnings.map((w) => w.code),
        contains('complex_parameter'),
      );
      expect(
        result.warnings.map((w) => w.code),
        contains('unknown_parameter'),
      );
    });
  });

  group('FuseSoCImporter — unsupported features (warn + continue)', () {
    test('warns on vpi blocks but still imports the target', () {
      const yaml = '''
CAPI=2:

name: ::with_vpi:0.1.0

vpi:
  my_vpi:
    src_files:
      - vpi/foo.c

targets:
  sim:
    toplevel: tb
    default_tool: icarus
''';
      final result = importer.parse(yaml, '/p/x.core');
      expect(result.warnings.map((w) => w.code), contains('unsupported_vpi'));
      final config = ConfigLoader().parse(
        result.simcruxYaml,
        '/p/x/simcrux.yaml',
      );
      expect(config.suites, hasLength(1));
    });

    test('warns on generators block', () {
      const yaml = '''
CAPI=2:

name: ::with_gen:0.1.0

generators:
  my_gen:
    interpreter: python3
    command: gen.py

targets:
  sim:
    toplevel: tb
    default_tool: icarus
''';
      final result = importer.parse(yaml, '/p/x.core');
      expect(
        result.warnings.map((w) => w.code),
        contains('unsupported_generator'),
      );
    });

    test('warns on scripts block', () {
      const yaml = '''
CAPI=2:

name: ::with_scripts:0.1.0

scripts:
  pre_run:
    - echo hi

targets:
  sim:
    toplevel: tb
    default_tool: icarus
''';
      final result = importer.parse(yaml, '/p/x.core');
      expect(
        result.warnings.map((w) => w.code),
        contains('unsupported_scripts'),
      );
    });

    test('warns on unrecognized tool and falls back to icarus', () {
      const yaml = '''
CAPI=2:

name: ::vendor:0.1.0

targets:
  sim:
    toplevel: tb
    default_tool: modelsim
''';
      final result = importer.parse(yaml, '/p/x.core');
      expect(
        result.warnings.map((w) => w.code),
        contains('unsupported_tool'),
      );
      final config = ConfigLoader().parse(
        result.simcruxYaml,
        '/p/x/simcrux.yaml',
      );
      expect(config.suites.single.tests.single.simulatorId, 'icarus');
    });

    test('warns on non-HDL file types but keeps them in sources', () {
      const yaml = '''
CAPI=2:

name: ::xdc:0.1.0

filesets:
  constraints:
    files:
      - cons/main.xdc
    file_type: xdc

targets:
  sim:
    filesets: [constraints]
    toplevel: tb
    default_tool: icarus
''';
      final result = importer.parse(yaml, '/p/x.core');
      expect(
        result.warnings.map((w) => w.code),
        contains('non_hdl_file_type'),
      );
      final config = ConfigLoader(
        simulatorLanguages: const {},
      ).parse(result.simcruxYaml, '/p/x/simcrux.yaml');
      expect(
        config.suites.single.tests.single.sources,
        contains('cons/main.xdc'),
      );
    });

    test('warns on unknown fileset reference', () {
      const yaml = '''
CAPI=2:

name: ::missing:0.1.0

targets:
  sim:
    filesets: [nope]
    toplevel: tb
    default_tool: icarus
''';
      final result = importer.parse(yaml, '/p/x.core');
      expect(
        result.warnings.map((w) => w.code),
        contains('unknown_fileset'),
      );
    });
  });

  group('FuseSoCImporter — only simulation targets become suites', () {
    test('skips targets driven by a synthesis / P&R backend', () {
      const yaml = '''
CAPI=2:

name: ::board:0.1.0

filesets:
  rtl:
    files:
      - rtl/top.v
    file_type: verilogSource

targets:
  sim:
    filesets: [rtl]
    toplevel: tb
    default_tool: icarus

  arty_a7_35t:
    filesets: [rtl]
    toplevel: toplevel_arty
    default_tool: vivado

  alhambra:
    filesets: [rtl]
    toplevel: toplevel_ice
    default_tool: icestorm

  sky130:
    filesets: [rtl]
    toplevel: wrapper
    default_tool: openlane
''';
      final result = importer.parse(yaml, '/p/board.core');
      final config = ConfigLoader().parse(
        result.simcruxYaml,
        '/p/board/simcrux.yaml',
      );

      // Three FPGA/ASIC targets dropped; only the simulation survives.
      expect(config.suites.map((s) => s.name), ['sim']);
      expect(
        result.warnings.where((w) => w.code == 'non_simulation_target').length,
        3,
      );
      // The old behaviour routed these to icarus — make sure that
      // regression can't come back silently.
      expect(
        result.warnings.map((w) => w.code),
        isNot(contains('unsupported_tool')),
      );
    });

    test('reads flow / flow_options.tool for the modern CAPI2 flow API', () {
      const yaml = '''
CAPI=2:

name: ::flows:0.1.0

filesets:
  rtl:
    files:
      - rtl/top.v
    file_type: verilogSource

targets:
  verilator_tb:
    filesets: [rtl]
    toplevel: tb
    flow: sim
    flow_options:
      tool: verilator
''';
      final result = importer.parse(yaml, '/p/flows.core');
      final config = ConfigLoader().parse(
        result.simcruxYaml,
        '/p/flows/simcrux.yaml',
      );
      expect(config.suites.single.tests.single.simulatorId, 'verilator');
      expect(result.warnings, isEmpty);
    });

    test('skips a non-sim flow such as flow: lint', () {
      const yaml = '''
CAPI=2:

name: ::lint:0.1.0

targets:
  sim:
    toplevel: tb
    default_tool: icarus

  lint:
    toplevel: top
    flow: lint
    flow_options:
      tool: verilator
''';
      final result = importer.parse(yaml, '/p/lint.core');
      final config = ConfigLoader().parse(
        result.simcruxYaml,
        '/p/lint/simcrux.yaml',
      );
      expect(config.suites.map((s) => s.name), ['sim']);
      expect(
        result.warnings.map((w) => w.code),
        contains('non_simulation_target'),
      );
    });

    test('still falls back to icarus for a simulator it cannot drive', () {
      const yaml = '''
CAPI=2:

name: ::questa:0.1.0

targets:
  sim:
    toplevel: tb
    default_tool: questa
''';
      final result = importer.parse(yaml, '/p/q.core');
      final config = ConfigLoader().parse(
        result.simcruxYaml,
        '/p/q/simcrux.yaml',
      );
      expect(config.suites.single.tests.single.simulatorId, 'icarus');
      expect(
        result.warnings.map((w) => w.code),
        contains('unsupported_tool'),
      );
    });

    test('throws when every target is a synthesis target', () {
      const yaml = '''
CAPI=2:

name: ::boardsonly:0.1.0

targets:
  arty:
    toplevel: toplevel_arty
    default_tool: vivado

  de0_nano:
    toplevel: toplevel_de0
    default_tool: quartus
''';
      expect(
        () => importer.parse(yaml, '/p/boards.core'),
        throwsA(isA<FuseSoCImportException>()),
      );
    });
  });

  group('FuseSoCImporter — CAPI2 conditional expressions', () {
    // Mirrors the shape of SERV's servant.core, which is what surfaced
    // every one of these cases.
    const yaml = '''
CAPI=2:

name: ::cond:0.1.0

filesets:
  soc:
    files:
      - rtl/core.v
      - "tool_quartus? (rtl/ram_quartus.sv)" : {file_type: systemVerilogSource}
      - "!tool_quartus? (rtl/ram.v)"
      - "tool_icarus? (rtl/icarus_shim.v rtl/icarus_extra.v)"
    file_type: verilogSource
    depend: ["mdu? (mdu_core)"]

  tb:
    files:
      - "!vidbo? (bench/tb.v)"
      - "vidbo? (bench/tb_vidbo.v)"
    file_type: verilogSource

targets:
  sim:
    filesets: [soc, tb]
    toplevel: tb_top
    default_tool: icarus
    parameters: ["mdu? (MDU=1)", WIDTH=32]

parameters:
  MDU:
    datatype: int
    paramtype: vlogparam
  WIDTH:
    datatype: int
    paramtype: vlogparam
''';

    test('drops entries gated on a non-matching tool flag', () {
      final result = importer.parse(yaml, '/p/cond.core');
      final config = ConfigLoader(
        simulatorLanguages: const {},
      ).parse(result.simcruxYaml, '/p/cond/simcrux.yaml');
      final sources = config.suites.single.tests.single.sources;

      // tool is icarus, so the quartus-only file goes and its negation stays.
      expect(sources, isNot(contains('rtl/ram_quartus.sv')));
      expect(sources, contains('rtl/ram.v'));
      // Nothing may reach the simulator still wearing its condition.
      expect(sources.where((s) => s.contains('?')), isEmpty);
    });

    test('expands a matching flag to every token inside the parens', () {
      final result = importer.parse(yaml, '/p/cond.core');
      final config = ConfigLoader(
        simulatorLanguages: const {},
      ).parse(result.simcruxYaml, '/p/cond/simcrux.yaml');
      final sources = config.suites.single.tests.single.sources;
      expect(sources, containsAll(['rtl/icarus_shim.v', 'rtl/icarus_extra.v']));
    });

    test('treats user-defined flags as unset, and warns once per flag', () {
      final result = importer.parse(yaml, '/p/cond.core');
      final config = ConfigLoader(
        simulatorLanguages: const {},
      ).parse(result.simcruxYaml, '/p/cond/simcrux.yaml');
      final test = config.suites.single.tests.single;

      expect(test.sources, contains('bench/tb.v'));
      expect(test.sources, isNot(contains('bench/tb_vidbo.v')));
      // `mdu? (MDU=1)` must not become a parameter literally named
      // `mdu? (MDU`, which is what shipped before.
      expect(test.parameters.keys, isNot(contains(startsWith('mdu'))));
      expect(test.parameters['WIDTH'], '32');

      final flagWarnings = result.warnings
          .where((w) => w.code == 'conditional_flag_unset')
          .toList();
      // One per distinct flag, not one per suppressed entry: `mdu` gates
      // both a fileset dependency and a parameter here, and must still be
      // reported once.
      expect(flagWarnings, hasLength(2));
      expect(
        flagWarnings.where((w) => w.message.contains('`mdu`')),
        hasLength(1),
      );
      expect(
        flagWarnings.where((w) => w.message.contains('`vidbo`')),
        hasLength(1),
      );
    });

    test('resolves a conditional, list-valued toplevel', () {
      // SERV's serv.core writes exactly this.
      const listTop = '''
CAPI=2:

name: ::lt:0.1.0

targets:
  default:
    toplevel: ["is_toplevel? (serv_rf_top)"]
    default_tool: icarus
''';
      final result = importer.parse(listTop, '/p/lt.core');
      final config = ConfigLoader().parse(
        result.simcruxYaml,
        '/p/lt/simcrux.yaml',
      );
      expect(config.suites.single.tests.single.top, 'serv_rf_top');
    });

    test('skips a target whose toplevel resolves to nothing', () {
      const unresolvable = '''
CAPI=2:

name: ::none:0.1.0

targets:
  sim:
    toplevel: tb
    default_tool: icarus

  ghost:
    toplevel: ["someflag? (never_top)"]
    default_tool: icarus
''';
      final result = importer.parse(unresolvable, '/p/none.core');
      final config = ConfigLoader().parse(
        result.simcruxYaml,
        '/p/none/simcrux.yaml',
      );
      expect(config.suites.map((s) => s.name), ['sim']);
      expect(
        result.warnings.map((w) => w.code),
        contains('unresolved_toplevel'),
      );
    });

    test('a scalar toplevel still works (regression guard)', () {
      const scalar = '''
CAPI=2:

name: ::scalar:0.1.0

targets:
  sim:
    toplevel: plain_tb
    default_tool: icarus
''';
      final result = importer.parse(scalar, '/p/s.core');
      final config = ConfigLoader().parse(
        result.simcruxYaml,
        '/p/s/simcrux.yaml',
      );
      expect(config.suites.single.tests.single.top, 'plain_tb');
    });
  });

  group('FuseSoCImporter — error paths', () {
    test('throws when no targets are present', () {
      const yaml = '''
CAPI=2:

name: ::empty:0.1.0
''';
      expect(
        () => importer.parse(yaml, '/p/x.core'),
        throwsA(isA<FuseSoCImportException>()),
      );
    });

    test('throws when targets block is empty (no toplevels)', () {
      const yaml = '''
CAPI=2:

name: ::only-default:0.1.0

targets:
  default:
    filesets: []
''';
      expect(
        () => importer.parse(yaml, '/p/x.core'),
        throwsA(isA<FuseSoCImportException>()),
      );
    });
  });

  group('FuseSoCImporter — emitted YAML hygiene', () {
    test('puts the source path and warnings in the header comments', () {
      const yaml = '''
CAPI=2:

name: ::with_warn:0.1.0

vpi:
  v: { src_files: [v.c] }

targets:
  sim:
    toplevel: tb
    default_tool: icarus
''';
      final result = importer.parse(yaml, '/p/x.core');
      expect(result.simcruxYaml, startsWith('# Generated by SimCrux'));
      expect(result.simcruxYaml, contains('# Source: /p/x.core'));
      expect(result.simcruxYaml, contains('[unsupported_vpi]'));
    });
  });
}
