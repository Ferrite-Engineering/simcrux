// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/services/config/config_loader.dart';
import 'package:simcrux/services/import/fusesoc_importer.dart';

void main() {
  group('FuseSoC fixture roundtrips', () {
    test(
      'simple.core imports cleanly and parses through ConfigLoader',
      () async {
        final fixture = p.normalize(
          p.absolute('test/fixtures/fusesoc/simple.core'),
        );
        final result = await FuseSoCImporter().importFile(fixture);
        expect(
          result.warnings,
          isEmpty,
          reason:
              'Simple fixture should have no warnings — '
              'got: ${result.warnings}',
        );
        // Named after the core (`name: ::simple:0.1.0`), not a fixed
        // `simcrux.yaml`, so sibling `.core` files in one directory each
        // get their own output instead of overwriting one another.
        expect(result.suggestedOutputFilename, 'simple.simcrux.yaml');

        // The synthesized YAML must round-trip through ConfigLoader.
        // Use an empty simulator-language catalog so the parser doesn't
        // try to validate the fixture's source files against the real
        // open-core simulator catalog (the test files don't exist on
        // disk — we're testing the YAML structure only).
        final config =
            ConfigLoader(
              simulatorLanguages: const {},
            ).parse(
              result.simcruxYaml,
              p.join(p.dirname(fixture), 'simcrux.yaml'),
            );
        expect(config.suites, hasLength(1));
        expect(config.suites.single.name, 'sim');
        expect(config.suites.single.tests, hasLength(1));
        expect(config.suites.single.tests.single.simulatorId, 'icarus');
        expect(config.suites.single.tests.single.top, 'counter_tb');
      },
    );

    test(
      'multi_target.core produces three suites with distinct simulators',
      () async {
        final fixture = p.normalize(
          p.absolute('test/fixtures/fusesoc/multi_target.core'),
        );
        final result = await FuseSoCImporter().importFile(fixture);
        expect(
          result.warnings,
          isEmpty,
          reason:
              'Multi-target fixture should be clean — '
              'got: ${result.warnings}',
        );

        final config =
            ConfigLoader(
              simulatorLanguages: const {},
            ).parse(
              result.simcruxYaml,
              p.join(p.dirname(fixture), 'multi_target/simcrux.yaml'),
            );
        final byName = {for (final s in config.suites) s.name: s};
        expect(
          byName.keys,
          containsAll(['sim_alu', 'sim_regfile', 'sim_uart']),
        );
        expect(
          byName,
          hasLength(3),
          reason: 'default target (no toplevel) should be skipped',
        );
        expect(byName['sim_alu']!.tests.single.simulatorId, 'icarus');
        expect(byName['sim_regfile']!.tests.single.simulatorId, 'verilator');
        expect(byName['sim_uart']!.tests.single.simulatorId, 'ghdl');
        // Parameters routed correctly.
        expect(byName['sim_alu']!.tests.single.parameters['WIDTH'], '16');
        expect(byName['sim_alu']!.tests.single.defines['DEBUG'], '1');
        expect(byName['sim_regfile']!.tests.single.parameters['WIDTH'], '32');
      },
    );

    test(
      'unsupported.core warns extensively but still produces a config',
      () async {
        final fixture = p.normalize(
          p.absolute('test/fixtures/fusesoc/unsupported.core'),
        );
        final result = await FuseSoCImporter().importFile(fixture);
        final codes = result.warnings.map((w) => w.code).toSet();
        expect(codes, contains('unsupported_vpi'));
        expect(codes, contains('unsupported_generator'));
        expect(codes, contains('unsupported_scripts'));
        expect(codes, contains('complex_parameter'));
        expect(codes, contains('unknown_parameter'));
        expect(codes, contains('unsupported_tool'));
        expect(codes, contains('non_hdl_file_type'));
        expect(codes, contains('include_file_demotion'));

        // Despite the warnings, the YAML must still parse and reach a
        // valid SimCrux config — that's the "warn + continue" contract.
        final config =
            ConfigLoader(
              simulatorLanguages: const {},
            ).parse(
              result.simcruxYaml,
              p.join(p.dirname(fixture), 'unsupported/simcrux.yaml'),
            );
        expect(config.suites.where((s) => s.name == 'sim'), hasLength(1));
      },
    );

    test(
      'write-to-disk path produces a file next to the source .core',
      () async {
        final tmp = Directory.systemTemp.createTempSync('fusesoc-write');
        try {
          // Copy the simple fixture next to a temp dir so we can write
          // the simcrux.yaml next to it.
          final src = File(
            p.absolute('test/fixtures/fusesoc/simple.core'),
          );
          final dst = File(p.join(tmp.path, 'simple.core'));
          await dst.writeAsString(src.readAsStringSync());

          final result = await FuseSoCImporter().importFile(dst.path);
          final outPath = p.join(tmp.path, result.suggestedOutputFilename);
          await File(outPath).writeAsString(result.simcruxYaml);

          expect(File(outPath).existsSync(), isTrue);
          final content = File(outPath).readAsStringSync();
          expect(content, contains("version: '1'"));
          expect(content, contains('sim:'));
        } finally {
          tmp.deleteSync(recursive: true);
        }
      },
    );
  });
}
