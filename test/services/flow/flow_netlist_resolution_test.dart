// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:crux_flow/crux_flow.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/models/flow_config.dart';
import 'package:simcrux/services/flow/flow_worst_paths.dart';

/// Which netlist a worst path is mapped through: the flow entry's
/// `netlist:`, then `synth.json`, then the run's one Yosys netlist.
///
/// The runs are the FPGA fixtures, whose Yosys step wrote `netlist.json`;
/// every expectation is from the fixtures' own files
/// (`mapping.expected.json`) or from the same run read with `synth.json`.
void main() {
  const fixtures = 'verification/fixtures/flow/nextpnr';
  final expected =
      jsonDecode(File('$fixtures/mapping.expected.json').readAsStringSync())
          as Map<String, Object?>;
  final cases = (expected['cases']! as Map<String, Object?>).keys.toList();
  final endRegister = expected['end_register']! as String;
  final startRegisters = (expected['start_registers']! as List<Object?>)
      .cast<String>();
  late Directory tmp;

  // Resolved: run roots are read with their links resolved (macOS's
  // temporary directory is under the /var link).
  setUp(
    () => tmp = Directory(
      Directory.systemTemp
          .createTempSync('flow_netlist_')
          .resolveSymbolicLinksSync(),
    ),
  );
  tearDown(() => tmp.deleteSync(recursive: true));

  /// A run directory holding fixture [name]'s report and its netlist under
  /// each of [netlistNames].
  String run(
    String name, {
    List<String> netlistNames = const <String>[],
    String dir = 'run',
  }) {
    final root = Directory(p.join(tmp.path, dir))..createSync(recursive: true);
    File('$fixtures/$name/report.json').copySync(
      p.join(root.path, 'report.json'),
    );
    for (final netlistName in netlistNames) {
      final target = File(p.join(root.path, netlistName));
      target.parent.createSync(recursive: true);
      File('$fixtures/$name/netlist.json').copySync(target.path);
    }
    return root.path;
  }

  Future<FlowWorstPaths> read(String root, {String? netlist}) =>
      readFlowWorstPaths(
        FlowRunRef(
          kind: FlowKind.nextpnr,
          root: root,
          tag: p.basename(root),
          readerVersion: 'nextpnr-report',
          verified: true,
        ),
        netlist: netlist,
      );

  void expectUnmapped(FlowWorstPaths paths) {
    expect(paths.mapped, isFalse);
    expect(paths.rows, isNotEmpty);
    expect(
      paths.rows.every((r) => r.fidelity == MappingFidelity.unmapped),
      isTrue,
    );
  }

  group('a run whose netlist is not named synth.json', () {
    for (final name in cases) {
      test('$name: its only netlist.json maps as synth.json does', () async {
        final reference = await read(run(name, netlistNames: ['synth.json']));
        final found = await read(
          run(name, netlistNames: ['netlist.json'], dir: 'other'),
        );

        expect(reference.mapped, isTrue);
        expect(found.mapped, isTrue);
        expect(found.rows, hasLength(reference.rows.length));
        for (final (i, row) in found.rows.indexed) {
          final same = reference.rows[i];
          expect(row.startpoint, same.startpoint, reason: 'start of $i');
          expect(row.endpoint, same.endpoint, reason: 'end of $i');
          expect(row.segments, same.segments, reason: 'segments of $i');
        }

        // From the fixture's own expectations, not from this reader.
        final worst = found.rows.first;
        expect(worst.fidelity, isNot(MappingFidelity.unmapped));
        final carries =
            (expected['cases']! as Map<String, Object?>)[name]!
                as Map<String, Object?>;
        if (carries['cell_names_carry_register'] == true) {
          expect(worst.endpoint.register, startsWith(endRegister));
          expect(
            startRegisters.any(
              (r) => worst.startpoint.register?.startsWith(r) ?? false,
            ),
            isTrue,
            reason: 'the start is one of $startRegisters',
          );
        }
      });
    }

    test("the entry's netlist: names it, among several netlists", () async {
      final root = run(
        'path_ice40_met',
        netlistNames: ['alpha.json', 'beta.json'],
      );
      // Two Yosys netlists and no hint is no choice.
      expectUnmapped(await read(root));
      final named = await read(root, netlist: 'beta.json');
      expect(named.mapped, isTrue);
      expect(named.rows.first.endpoint.register, startsWith(endRegister));
    });

    test('netlist: may name a file in a subdirectory of the run', () async {
      final root = run(
        'path_ecp5_met',
        netlistNames: ['build/top.json', 'other.json'],
      );
      final named = await read(root, netlist: 'build/top.json');
      expect(named.mapped, isTrue);
    });

    test('netlist: wins over synth.json', () async {
      final root = run('path_ice40_met', netlistNames: ['named.json']);
      // synth.json is another design's netlist: it maps this run's path
      // somewhere else, so the hint is what makes the difference.
      File('$fixtures/rescreen_ice40/netlist.json').copySync(
        p.join(root, 'synth.json'),
      );
      final unhinted = await read(root);
      expect(
        unhinted.rows.first.endpoint.register ?? '',
        isNot(startsWith(endRegister)),
      );
      final named = await read(root, netlist: 'named.json');
      expect(named.rows.first.endpoint.register, startsWith(endRegister));
    });

    test('a netlist: the run does not hold falls back to synth.json', () async {
      final root = run('path_ice40_met', netlistNames: ['synth.json']);
      final paths = await read(root, netlist: 'missing.json');
      expect(paths.mapped, isTrue);
      expect(paths.rows.first.endpoint.register, startsWith(endRegister));
    });

    test('synth.json is preferred to another netlist beside it', () async {
      final root = run(
        'path_ice40_met',
        netlistNames: ['synth.json', 'netlist.json'],
      );
      final paths = await read(root);
      expect(paths.mapped, isTrue);
    });

    test(
      'the report and the placed netlist are not netlist candidates',
      () async {
        final root = run('path_ice40_met', netlistNames: ['netlist.json']);
        // `--write post.json` is a Yosys-format netlist too; it is the placed
        // netlist, read for spans, and must not make netlist.json ambiguous.
        File('$fixtures/path_ice40_met/netlist.json').copySync(
          p.join(root, 'post.json'),
        );
        final paths = await read(root);
        expect(paths.mapped, isTrue);
        expect(paths.rows.first.endpoint.register, startsWith(endRegister));
      },
    );

    test('a JSON file that is not a netlist does not count', () async {
      final root = run('path_ice40_met', netlistNames: ['netlist.json']);
      File(p.join(root, 'notes.json')).writeAsStringSync('{"hello": 1}');
      File(p.join(root, 'broken.json')).writeAsStringSync('{ not json');
      final paths = await read(root);
      expect(paths.mapped, isTrue);
    });

    test('a run with no netlist at all lists its paths unmapped', () async {
      final root = run('path_ice40_met');
      File(p.join(root, 'notes.json')).writeAsStringSync('{"hello": 1}');
      expectUnmapped(await read(root));
    });
  });

  group('netlist: stays inside the run directory', () {
    test('refuses an absolute path, a `..` path and a link out', () async {
      // The netlist lives beside the run, not in it.
      final outside = run(
        'path_ice40_met',
        netlistNames: ['netlist.json'],
        dir: 'outside',
      );
      final root = run('path_ice40_met', dir: 'inside');
      final absolute = p.join(outside, 'netlist.json');
      for (final hint in <String>[
        absolute,
        '../outside/netlist.json',
        'sub/../../outside/netlist.json',
        '/$absolute',
      ]) {
        expectUnmapped(await read(root, netlist: hint));
      }

      if (!Platform.isWindows) {
        Link(p.join(root, 'escape.json')).createSync(absolute);
        expectUnmapped(await read(root, netlist: 'escape.json'));
        // The single-netlist fallback does not follow it either.
        expectUnmapped(await read(root));
      }
    });
  });

  group('FlowEntry.netlistPathProblem', () {
    test('accepts a relative path in the run directory', () {
      for (final good in <String>[
        'netlist.json',
        'build/top.json',
        r'build\top.json',
        'a..b.json',
        './netlist.json',
      ]) {
        expect(FlowEntry.netlistPathProblem(good), isNull, reason: good);
      }
    });

    test('refuses everything that is not one', () {
      for (final bad in <String>[
        '',
        '  ',
        '/netlist.json',
        r'\netlist.json',
        r'C:\netlist.json',
        'C:netlist.json',
        '~/netlist.json',
        '..',
        '../netlist.json',
        'a/../../netlist.json',
        r'a\..\..\netlist.json',
        'a\x00b.json',
        'a\nb.json',
      ]) {
        expect(FlowEntry.netlistPathProblem(bad), isNotNull, reason: bad);
      }
    });
  });
}
