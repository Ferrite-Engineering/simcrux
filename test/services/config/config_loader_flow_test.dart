// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_flow/crux_flow.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/models/config_loader_error.dart';
import 'package:simcrux/domain/models/flow_config.dart';
import 'package:simcrux/domain/models/flow_tool_settings.dart';
import 'package:simcrux/services/config/config_loader.dart';
import 'package:simcrux/services/flow/flow_run_importer.dart';

/// The `flow:` block: parsing, strict validation, the synthesised `flow`
/// suite, a project that has only flow entries, and includes.
void main() {
  // Absolute on the host: on Windows the loader resolves the project path
  // against the current drive (`D:\proj`), so a drive-less key never
  // matched and every load here failed there.
  final root = p.absolute(p.join(p.separator, 'proj'));
  final projectFile = p.join(root, 'simcrux.yaml');

  ConfigLoader loader({
    Map<String, String> files = const <String, String>{},
    bool allowTooling = false,
  }) => ConfigLoader(
    allowProjectDefinedTooling: allowTooling,
    readFile: (path) async {
      final normal = p.normalize(path);
      final content = files[normal];
      if (content == null) throw StateError('no file $normal');
      return content;
    },
  );

  const flowOnly = '''
version: "1"
flow:
  entries:
    - name: counter_sky130
      kind: librelane
      config: librelane/config.yaml
      pdk: sky130A
      tag_prefix: nightly
      gls:
        tests: [tag:smoke]
        netlist: nl
        strict_x: false
      equiv:
        partition_timeout_s: 600
        accept_blackbox: ["*__dlclkp_*"]
    - name: blinky_ecp5
      kind: nextpnr
      family: ecp5
      device: 25k
      package: CABGA256
      constraints: board/blinky.lpf
      top: top
      sources: [rtl/top.v]
      freq_mhz: 100
      detailed_timing: true
  ingest:
    - runs/
    - build/fpga/report.json
''';

  group('a project with flow entries and no suites', () {
    test('loads, with the entries as the synthesised flow suite', () async {
      final config = await loader(files: {projectFile: flowOnly}).load(
        projectFile,
      );
      expect(config.suites, hasLength(1));
      final suite = config.suites.single;
      expect(suite.name, FlowRunImporter.kFlowSuiteName);
      expect(suite.tests.map((t) => t.id), [
        'flow/counter_sky130',
        'flow/blinky_ecp5',
      ]);
    });

    test('one entry is one TestSpec carrying the entry', () async {
      final config = await loader(files: {projectFile: flowOnly}).load(
        projectFile,
      );
      final specs = config.suites.single.tests;
      final librelane = specs.first;
      expect(librelane.simulatorId, 'librelane');
      expect(librelane.flow?.kind, FlowKind.librelane);
      expect(librelane.flow?.config, p.join(root, 'librelane', 'config.yaml'));
      expect(librelane.flow?.projectRoot, root);
      expect(librelane.flow?.tagPrefix, 'nightly');
      expect(librelane.flow?.pdk, 'sky130A');
      expect(librelane.resources.map((r) => r.name), ['flow']);
      expect(librelane.timeout, const Duration(hours: 4));

      final nextpnr = specs.last;
      expect(nextpnr.simulatorId, 'nextpnr');
      expect(nextpnr.top, 'top');
      expect(nextpnr.resources, isEmpty, reason: 'nextpnr takes no lock');
      expect(nextpnr.timeout, const Duration(hours: 4));
      final entry = nextpnr.flow!;
      expect(entry.family, NextpnrFamily.ecp5);
      expect(entry.device, '25k');
      expect(entry.package, 'CABGA256');
      expect(entry.constraints, p.join(root, 'board', 'blinky.lpf'));
      expect(entry.sources, [p.join(root, 'rtl', 'top.v')]);
      expect(entry.freqMhz, 100);
      expect(entry.detailedTiming, isTrue);
    });

    test('the gls: and equiv: sub-blocks are accepted and kept', () async {
      final config = await loader(files: {projectFile: flowOnly}).load(
        projectFile,
      );
      final entry = config.flow!.entries.first;
      expect(entry.gls, const FlowGlsConfig(tests: ['tag:smoke']));
      expect(
        entry.equiv,
        const FlowEquivConfig(
          partitionTimeoutS: 600,
          acceptBlackbox: ['*__dlclkp_*'],
        ),
      );
    });

    test('ingest paths resolve against the project directory', () async {
      final config = await loader(files: {projectFile: flowOnly}).load(
        projectFile,
      );
      expect(config.flow!.ingest, [
        p.join(root, 'runs'),
        p.join(root, 'build', 'fpga', 'report.json'),
      ]);
    });

    test('loads at Open Core with the beta period over', () async {
      final config = await ConfigLoader(
        readFile: (path) async => flowOnly,
      ).load(projectFile);
      expect(config.suites.single.tests, hasLength(2));
    });
  });

  test('a project with neither suites nor flow entries still refuses', () {
    expect(
      loader(files: {projectFile: 'version: "1"\n'}).load(projectFile),
      throwsA(isA<ConfigLoaderException>()),
    );
  });

  test('suites and flow entries load side by side', () async {
    final config = await loader(
      files: {
        projectFile:
            '''
version: "1"
defaults:
  simulator: icarus
suites:
  unit:
    tests:
      - name: t
        top: tb
$flowOnly'''
                .replaceFirst('version: "1"\nflow:', 'flow:'),
      },
    ).load(projectFile);
    expect(config.suites.map((s) => s.name), ['unit', 'flow']);
  });

  test('a suite named flow is refused when flow entries exist', () {
    expect(
      loader(
        files: {
          projectFile:
              '''
version: "1"
defaults:
  simulator: icarus
suites:
  flow:
    tests:
      - name: t
        top: tb
$flowOnly'''
                  .replaceFirst('version: "1"\nflow:', 'flow:'),
        },
      ).load(projectFile),
      throwsA(
        isA<ConfigLoaderException>().having(
          (e) => e.errors.map((x) => x.message).join(),
          'message',
          contains('Rename the suite'),
        ),
      ),
    );
  });

  test('an included file adds entries resolved against itself', () async {
    final config = await loader(
      files: {
        projectFile: 'version: "1"\nincludes: [sub/more.yaml]\n$flowOnly'
            .replaceFirst('version: "1"\nflow:', 'flow:'),
        p.join(root, 'sub', 'more.yaml'): '''
version: "1"
flow:
  entries:
    - name: extra
      kind: nextpnr
      family: ice40
      device: up5k
      package: sg48
      top: top
      sources: [top.v]
''',
      },
    ).load(projectFile);
    final extra = config.flow!.entries.firstWhere((e) => e.name == 'extra');
    expect(extra.sources, [p.join(root, 'sub', 'top.v')]);
    expect(extra.projectRoot, root);
    expect(config.suites.single.tests.map((t) => t.name), contains('extra'));
  });

  test('an entry name declared in two files is refused', () {
    expect(
      loader(
        files: {
          projectFile: 'version: "1"\nincludes: [b.yaml]\n$flowOnly'
              .replaceFirst('version: "1"\nflow:', 'flow:'),
          p.join(root, 'b.yaml'): '''
version: "1"
flow:
  entries:
    - name: blinky_ecp5
      kind: nextpnr
      family: ice40
      device: up5k
      package: sg48
      top: top
      sources: [top.v]
''',
        },
      ).load(projectFile),
      throwsA(isA<ConfigLoaderException>()),
    );
  });

  group('strict validation', () {
    List<String> errorsOf(String entryYaml, {bool allowTooling = false}) {
      try {
        loader(allowTooling: allowTooling).parse('''
version: "1"
flow:
  entries:
$entryYaml
''', projectFile);
        return const <String>[];
      } on ConfigLoaderException catch (e) {
        return e.errors.map((x) => x.message).toList();
      }
    }

    const nextpnr = '''
    - name: n
      kind: nextpnr
      family: ice40
      device: up5k
      package: sg48
      top: top
      sources: [top.v]''';

    test('a valid nextpnr entry has no errors', () {
      expect(errorsOf(nextpnr), isEmpty);
    });

    test('netlist: names a file inside the run directory', () {
      expect(errorsOf('$nextpnr\n      netlist: netlist.json'), isEmpty);
      expect(errorsOf('$nextpnr\n      netlist: build/top.json'), isEmpty);
      final config = loader().parse('''
version: "1"
flow:
  entries:
$nextpnr
      netlist: build/top.json
''', projectFile);
      // As written: it is relative to each run directory, so the loader does
      // not resolve it against the project.
      expect(config.flow!.entries.single.netlist, 'build/top.json');
    });

    test('netlist: refuses an absolute path and a way out of the run', () {
      for (final bad in [
        '/etc/netlist.json',
        r'\share\netlist.json',
        r'C:\runs\netlist.json',
        'C:netlist.json',
        '~/netlist.json',
        '../netlist.json',
        'build/../../netlist.json',
        r'build\..\..\netlist.json',
        '..',
        '',
      ]) {
        expect(
          errorsOf("$nextpnr\n      netlist: '$bad'"),
          anyElement(contains('`flow.entries[0].netlist`')),
          reason: bad,
        );
      }
    });

    test('netlist: does not apply to a LibreLane entry', () {
      expect(
        errorsOf('''
    - name: l
      kind: librelane
      config: c.yaml
      netlist: netlist.json'''),
        anyElement(contains('does not apply to a librelane entry')),
      );
    });

    test('netlist: is read on a FuseSoC entry too', () {
      final config = loader(allowTooling: true).parse('''
version: "1"
flow:
  entries:
    - name: f
      kind: nextpnr
      fusesoc: {core: "a:b:c", target: icebreaker}
      netlist: default-sim/top.json
''', projectFile);
      expect(config.flow!.entries.single.netlist, 'default-sim/top.json');
    });

    test('an unknown key is an error', () {
      expect(
        errorsOf('$nextpnr\n      sourcez: [x.v]'),
        anyElement(contains('not a flow entry key')),
      );
    });

    test('a LibreLane key on a nextpnr entry is an error', () {
      expect(
        errorsOf('$nextpnr\n      pdk: sky130A'),
        anyElement(contains('does not apply to a nextpnr entry')),
      );
    });

    test('gls: on a nextpnr entry is an error (LibreLane only)', () {
      expect(
        errorsOf('$nextpnr\n      gls: {tests: [a]}'),
        anyElement(contains('does not apply to a nextpnr entry')),
      );
    });

    test('kind is required and closed', () {
      expect(
        errorsOf('    - name: x'),
        anyElement(contains('`flow.entries[0].kind` is required')),
      );
      expect(
        errorsOf('    - name: x\n      kind: vivado'),
        anyElement(contains('must be librelane or nextpnr')),
      );
    });

    test('a name must be one safe segment', () {
      for (final bad in ['../up', 'a/b', '.', 'a b', 'C:x']) {
        expect(
          errorsOf(nextpnr.replaceFirst('name: n', 'name: "$bad"')),
          anyElement(contains('letters, digits')),
          reason: bad,
        );
      }
    });

    test('a tag prefix must be one safe segment', () {
      expect(
        errorsOf('''
    - name: l
      kind: librelane
      config: c.yaml
      tag_prefix: "../x"'''),
        anyElement(contains('tag_prefix')),
      );
    });

    test('nextpnr needs family, device, top and sources; package for '
        'ice40/ecp5', () {
      final errors = errorsOf('    - name: n\n      kind: nextpnr');
      expect(errors, anyElement(contains('needs `family`')));
      expect(errors, anyElement(contains('needs `device`')));
      expect(errors, anyElement(contains('needs `top`')));
      expect(errors, anyElement(contains('needs `sources`')));
      expect(
        errorsOf(nextpnr.replaceFirst('      package: sg48\n', '')),
        anyElement(contains('needs `package`')),
      );
    });

    test('a device or package that reads as an option is refused', () {
      expect(
        errorsOf(nextpnr.replaceFirst('device: up5k', 'device: "-x"')),
        anyElement(contains('does not start with `-`')),
      );
    });

    test('freq_mhz must be a positive number', () {
      expect(
        errorsOf('$nextpnr\n      freq_mhz: -3'),
        anyElement(contains('freq_mhz')),
      );
    });

    test('a LibreLane entry needs config', () {
      expect(
        errorsOf('    - name: l\n      kind: librelane'),
        anyElement(contains('needs `config`')),
      );
    });

    test('gls.netlist is nl or pnl; equiv.partition_timeout_s positive', () {
      const base = '    - name: l\n      kind: librelane\n      config: c.yaml';
      expect(
        errorsOf('$base\n      gls: {netlist: final}'),
        anyElement(contains('nl or pnl')),
      );
      expect(
        errorsOf('$base\n      equiv: {partition_timeout_s: 0}'),
        anyElement(contains('partition_timeout_s')),
      );
      expect(
        errorsOf('$base\n      gls: {testz: [a]}'),
        anyElement(contains('not a known key')),
      );
    });

    test('a nextpnr synthesis key beside fusesoc is an error', () {
      expect(
        errorsOf('''
    - name: f
      kind: nextpnr
      fusesoc: {core: "a:b:c", target: icebreaker}
      family: ice40''', allowTooling: true),
        anyElement(contains('does not apply with `fusesoc`')),
      );
    });

    test('a LibreLane configuration outside the project is refused at '
        'load', () {
      expect(
        loader(
          files: {
            projectFile: '''
version: "1"
flow:
  entries:
    - name: l
      kind: librelane
      config: ../elsewhere/config.yaml
''',
          },
        ).load(projectFile),
        throwsA(
          isA<ConfigLoaderException>().having(
            (e) => e.errors.single.message,
            'message',
            contains('inside the project directory'),
          ),
        ),
      );
    });
  });

  test('a project option may not pose as a Settings value', () {
    final config = loader().parse('''
version: "1"
simulators:
  nextpnr:
    options:
      ${kFlowSettingsOptionPrefix}launcher: docker
      ${kFlowSettingsOptionPrefix}docker_image: evil/image
      keep: yes
flow:
  entries: []
''', projectFile);
    final options = config.simulatorBinaries['nextpnr']!.options;
    expect(
      options.keys.where((k) => k.startsWith(kFlowSettingsOptionPrefix)),
      isEmpty,
    );
    expect(options['keep'], 'yes');
    expect(
      config.loadWarnings.map((w) => w.message),
      anyElement(contains('carry Settings values')),
    );
    expect(
      config.loadWarnings.every(
        (w) => w.severity == ConfigLoaderErrorSeverity.warning,
      ),
      isTrue,
    );
  });
}
