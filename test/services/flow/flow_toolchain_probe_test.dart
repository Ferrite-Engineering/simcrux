// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/riscv_host_platform.dart';
import 'package:simcrux/domain/models/flow_config.dart';
import 'package:simcrux/domain/models/flow_tool_settings.dart';
import 'package:simcrux/services/flow/flow_toolchain_probe.dart';

/// Check flow tools, answered with faked tool output (no process starts).
void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('flow_probe_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  FlowToolchainProbe probe({
    required Map<String, ({int exitCode, List<String> lines})?> answers,
    Map<String, String>? environment,
  }) => FlowToolchainProbe(
    platform: RiscvHostPlatform.linux,
    environment: environment ?? <String, String>{'HOME': tmp.path},
    runner: (binary, args) async => answers[p.basename(binary)],
  );

  FlowToolReport row(FlowToolchainReport r, FlowTool tool) =>
      r.tools.singleWhere((t) => t.tool == tool);

  Directory flakeDir() {
    final dir = Directory(p.join(tmp.path, 'librelane-3.0.17'))..createSync();
    File(p.join(dir.path, 'flake.nix')).writeAsStringSync('{}');
    return dir;
  }

  group('the Nix launcher', () {
    test('a LibreLane flake directory is found, not looked up as an '
        'executable', () async {
      final dir = flakeDir();
      final report =
          await probe(
            answers: const {},
          ).probe(
            librelanePath: dir.path,
            settings: const FlowToolSettings(launcher: FlowLauncher.nix),
          );
      final librelane = row(report, FlowTool.librelane);
      expect(librelane.found, isTrue);
      expect(librelane.flakePath, dir.path);
      expect(librelane.problem, isNull);
    });

    test(
      'a directory with no flake.nix is not found, and says which',
      () async {
        final dir = Directory(p.join(tmp.path, 'empty'))..createSync();
        final report = await probe(answers: const {}).probe(
          librelanePath: dir.path,
          settings: const FlowToolSettings(launcher: FlowLauncher.nix),
        );
        final librelane = row(report, FlowTool.librelane);
        expect(librelane.found, isFalse);
        expect(librelane.flakePath, dir.path);
      },
    );

    test('no LibreLane path is not found', () async {
      final report = await probe(answers: const {}).probe(
        settings: const FlowToolSettings(launcher: FlowLauncher.nix),
      );
      expect(row(report, FlowTool.librelane).found, isFalse);
      expect(row(report, FlowTool.librelane).flakePath, isNull);
    });

    test('the path launcher still asks for an executable', () async {
      final dir = flakeDir();
      final report = await probe(
        answers: {
          'librelane': (exitCode: 0, lines: <String>['LibreLane 3.0.17']),
        },
      ).probe(librelanePath: dir.path);
      final librelane = row(report, FlowTool.librelane);
      expect(librelane.found, isTrue);
      expect(librelane.version, 'LibreLane 3.0.17');
      expect(librelane.flakePath, isNull);
    });
  });

  group('the PDK location', () {
    Directory pdk(String root, String name) =>
        Directory(p.join(root, name, 'libs.ref'))..createSync(recursive: true);

    test('with no setting and no PDK_ROOT it is ~/.ciel, as LibreLane '
        'resolves it', () async {
      pdk(p.join(tmp.path, '.ciel'), 'sky130A');
      final report = await probe(answers: const {}).probe();
      expect(report.pdkRoot, p.join(tmp.path, '.ciel'));
      expect(report.pdks, <String>['sky130A']);
    });

    test('PDK_ROOT wins over the default, the setting over both', () async {
      pdk(p.join(tmp.path, '.ciel'), 'sky130A');
      final fromEnv = p.join(tmp.path, 'env-pdks');
      pdk(fromEnv, 'gf180mcuD');
      final env = probe(
        answers: const {},
        environment: {'HOME': tmp.path, 'PDK_ROOT': fromEnv},
      );
      expect((await env.probe()).pdks, <String>['gf180mcuD']);

      final fromSettings = p.join(tmp.path, 'settings-pdks');
      pdk(fromSettings, 'ihp-sg13g2');
      final settings = await env.probe(
        settings: FlowToolSettings(pdkRoot: fromSettings),
      );
      expect(settings.pdkRoot, fromSettings);
      expect(settings.pdks, <String>['ihp-sg13g2']);
    });

    test('an empty default location lists no PDK', () async {
      final report = await probe(answers: const {}).probe();
      expect(report.pdks, isEmpty);
    });
  });

  group('a tool that answers with an error', () {
    test('exit 0 with only an error line is a problem, never found', () async {
      const error = 'mkdir: /nonexistent/.local/share: Permission denied';
      final report = await probe(
        answers: {
          'nextpnr-ice40': (exitCode: 0, lines: <String>[error]),
        },
      ).probe();
      final nextpnr = row(report, FlowTool.nextpnrIce40);
      expect(nextpnr.found, isFalse);
      expect(nextpnr.version, isNull);
      expect(nextpnr.problem, error);
      expect(report.missing, contains(FlowTool.nextpnrIce40));
    });

    test('the version line is picked past an error line', () async {
      final report = await probe(
        answers: {
          'nextpnr-ice40': (
            exitCode: 0,
            lines: <String>[
              'mkdir: /x/.local/share: Permission denied',
              'nextpnr-ice40 -- Version nextpnr-0.9',
            ],
          ),
        },
      ).probe();
      final nextpnr = row(report, FlowTool.nextpnrIce40);
      expect(nextpnr.found, isTrue);
      expect(nextpnr.version, 'nextpnr-ice40 -- Version nextpnr-0.9');
      expect(nextpnr.problem, isNull);
    });

    test('a non-zero exit with output reports what it printed', () async {
      final report = await probe(
        answers: {
          'yosys': (exitCode: 1, lines: <String>['yosys: bad option -V']),
        },
      ).probe();
      final yosys = row(report, FlowTool.yosys);
      expect(yosys.found, isFalse);
      expect(yosys.problem, 'yosys: bad option -V');
    });

    test(
      'a tool that never started is not found, with no problem text',
      () async {
        final report = await probe(answers: const {}).probe();
        final openroad = row(report, FlowTool.openroad);
        expect(openroad.found, isFalse);
        expect(openroad.problem, isNull);
      },
    );
  });

  group('versionLineOf', () {
    test('needs a digit and no error words', () {
      expect(
        FlowToolchainProbe.versionLineOf(<String>['OpenROAD v2.0-123']),
        'OpenROAD v2.0-123',
      );
      expect(FlowToolchainProbe.versionLineOf(<String>['usage: foo']), isNull);
      expect(
        FlowToolchainProbe.versionLineOf(<String>['error 2: cannot open']),
        isNull,
      );
      expect(FlowToolchainProbe.versionLineOf(const <String>[]), isNull);
    });
  });
}
