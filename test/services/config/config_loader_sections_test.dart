// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/waveform_format.dart';
import 'package:simcrux/domain/models/config_loader_error.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/services/config/config_loader.dart';

/// Dedicated coverage for the remaining structured-section parsers in
/// `config_loader_sections.dart` (`output:`, `simulators:`,
/// `waveform:`, `resources:`) — specifically their error branches,
/// which `config_loader_test.dart` barely touches. Every parser here
/// returns a fatal [ConfigLoaderError] (default severity), so every
/// case in this file goes through [_captureException] the same way
/// `config_loader_test.dart` does.
void main() {
  late ConfigLoader loader;

  setUp(() {
    loader = ConfigLoader();
  });

  group('output: section', () {
    test('happy path — streaming + both paths', () {
      const yaml = '''
version: "1"
defaults:
  simulator: icarus
output:
  streaming: true
  results_path: build/results.jsonl
  summary_path: build/summary.json
suites:
  s:
    tests:
      - name: t
        top: tb
''';
      final config = loader.parse(yaml, '/p.yaml');
      expect(config.output.streaming, isTrue);
      expect(config.output.streamingResultsPath, 'build/results.jsonl');
      expect(config.output.streamingSummaryPath, 'build/summary.json');
    });

    test('defaults to non-streaming when the section is absent', () {
      const yaml = '''
version: "1"
defaults:
  simulator: icarus
suites:
  s:
    tests:
      - name: t
        top: tb
''';
      final config = loader.parse(yaml, '/p.yaml');
      expect(config.output.streaming, isFalse);
      expect(config.output.streamingResultsPath, isNull);
      expect(config.output.streamingSummaryPath, isNull);
    });

    test('a non-map `output:` value is a fatal error', () {
      const yaml = '''
version: "1"
defaults:
  simulator: icarus
output: not_a_map
suites:
  s:
    tests:
      - name: t
        top: tb
''';
      final ex = _captureException(() => loader.parse(yaml, '/p.yaml'));
      expect(
        ex.errors.map((e) => e.message),
        anyElement(contains('`output` must be a map.')),
      );
    });

    test('a non-boolean `output.streaming` is a fatal error', () {
      const yaml = '''
version: "1"
defaults:
  simulator: icarus
output:
  streaming: "yes"
suites:
  s:
    tests:
      - name: t
        top: tb
''';
      final ex = _captureException(() => loader.parse(yaml, '/p.yaml'));
      expect(
        ex.errors.map((e) => e.message),
        anyElement(contains('`output.streaming` must be a boolean.')),
      );
    });
  });

  group('simulators: section', () {
    test('a non-map `simulators:` value is a fatal error', () {
      const yaml = '''
version: "1"
defaults:
  simulator: icarus
simulators: not_a_map
suites:
  s:
    tests:
      - name: t
        top: tb
''';
      final ex = _captureException(() => loader.parse(yaml, '/p.yaml'));
      expect(
        ex.errors.map((e) => e.message),
        anyElement(
          contains('`simulators` must be a map of simulator id to config.'),
        ),
      );
    });

    test('a simulator entry whose value is not a map is a fatal error', () {
      const yaml = '''
version: "1"
defaults:
  simulator: icarus
simulators:
  icarus: not_a_map
suites:
  s:
    tests:
      - name: t
        top: tb
''';
      final ex = _captureException(() => loader.parse(yaml, '/p.yaml'));
      expect(
        ex.errors.map((e) => e.message),
        anyElement(contains('Simulator `icarus` config must be a map.')),
      );
    });

    test('an unknown `source:` value is a fatal error', () {
      const yaml = '''
version: "1"
defaults:
  simulator: icarus
simulators:
  icarus:
    source: quantum
suites:
  s:
    tests:
      - name: t
        top: tb
''';
      final ex = _captureException(() => loader.parse(yaml, '/p.yaml'));
      expect(
        ex.errors.map((e) => e.message),
        anyElement(
          contains(
            'Simulator `icarus` has unknown source "quantum" '
            '(expected bundled / system / custom)',
          ),
        ),
      );
    });

    test('source: custom without a path is a fatal error', () {
      const yaml = '''
version: "1"
defaults:
  simulator: icarus
simulators:
  icarus:
    source: custom
suites:
  s:
    tests:
      - name: t
        top: tb
''';
      final ex = _captureException(() => loader.parse(yaml, '/p.yaml'));
      expect(
        ex.errors.map((e) => e.message),
        anyElement(
          contains(
            'Simulator `icarus` source=custom requires a `path` field.',
          ),
        ),
      );
    });

    test('source: custom WITH a path parses cleanly', () {
      const yaml = '''
version: "1"
defaults:
  simulator: icarus
simulators:
  icarus:
    source: custom
    path: /opt/icarus/bin/iverilog
suites:
  s:
    tests:
      - name: t
        top: tb
''';
      // `path:` is project-defined tooling, refused by the default
      // loader — this case is about the PARSER, so it uses a loader the
      // user has trusted. The gate itself is
      // `config_loader_project_tooling_test.dart`.
      final config = ConfigLoader(
        allowProjectDefinedTooling: true,
      ).parse(yaml, '/p.yaml');
      final bin = config.simulatorBinaries['icarus'];
      expect(bin?.source, SimulatorBinarySource.custom);
      expect(bin?.customPath, '/opt/icarus/bin/iverilog');
    });
  });

  group('waveform: section', () {
    test('a non-map `waveform:` value is a fatal error', () {
      const yaml = '''
version: "1"
defaults:
  simulator: icarus
  waveform: not_a_map
suites:
  s:
    tests:
      - name: t
        top: tb
''';
      final ex = _captureException(() => loader.parse(yaml, '/p.yaml'));
      expect(
        ex.errors.map((e) => e.message),
        anyElement(contains('`defaults.waveform` must be a map.')),
      );
    });

    test('an unknown `format:` value is a fatal error', () {
      const yaml = '''
version: "1"
defaults:
  simulator: icarus
  waveform:
    format: bmp
suites:
  s:
    tests:
      - name: t
        top: tb
''';
      final ex = _captureException(() => loader.parse(yaml, '/p.yaml'));
      expect(
        ex.errors.map((e) => e.message),
        anyElement(
          contains(
            'Field `defaults.waveform.format`: unknown value "bmp" '
            '(expected vcd / fst / ghw)',
          ),
        ),
      );
    });

    test('a valid `format:` value parses to the matching enum', () {
      const yaml = '''
version: "1"
defaults:
  simulator: icarus
  waveform:
    format: ghw
suites:
  s:
    tests:
      - name: t
        top: tb
''';
      final config = loader.parse(yaml, '/p.yaml');
      expect(config.defaultWaveform?.format, WaveformFormat.ghw);
    });
  });

  group('resources: section', () {
    test('a non-list `resources:` value is a fatal error', () {
      const yaml = '''
version: "1"
defaults:
  simulator: icarus
suites:
  s:
    tests:
      - name: t
        top: tb
        resources: not_a_list
''';
      final ex = _captureException(() => loader.parse(yaml, '/p.yaml'));
      expect(
        ex.errors.map((e) => e.message),
        anyElement(
          contains('`resources` must be a list of resource names.'),
        ),
      );
    });

    test('a non-string entry in `resources:` is a fatal error', () {
      const yaml = '''
version: "1"
defaults:
  simulator: icarus
suites:
  s:
    tests:
      - name: t
        top: tb
        resources: [123]
''';
      final ex = _captureException(() => loader.parse(yaml, '/p.yaml'));
      expect(
        ex.errors.map((e) => e.message),
        anyElement(
          contains(
            'Entries in `resources` must be non-empty strings '
            '(named resource locks).',
          ),
        ),
      );
    });

    test('an empty-string entry in `resources:` is a fatal error', () {
      const yaml = '''
version: "1"
defaults:
  simulator: icarus
suites:
  s:
    tests:
      - name: t
        top: tb
        resources: ['']
''';
      final ex = _captureException(() => loader.parse(yaml, '/p.yaml'));
      expect(
        ex.errors.map((e) => e.message),
        anyElement(
          contains(
            'Entries in `resources` must be non-empty strings '
            '(named resource locks).',
          ),
        ),
      );
    });

    test('a suite-level `resources:` list is honored (non-null return)', () {
      const yaml = '''
version: "1"
defaults:
  simulator: icarus
suites:
  hil:
    resources: ['fpga_board_0']
    tests:
      - name: t
        top: tb
''';
      final config = loader.parse(yaml, '/p.yaml');
      final names = config.suites.single.tests.single.resources.map(
        (r) => r.name,
      );
      expect(names, contains('fpga_board_0'));
    });
  });
}

ConfigLoaderException _captureException(void Function() body) {
  try {
    body();
    fail('Expected ConfigLoaderException');
  } on ConfigLoaderException catch (e) {
    return e;
  }
}
