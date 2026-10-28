// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Live: the LibreLane `nix` launcher, the way the desktop app starts it.
//
// `simcrux flow run` runs a `launcher: nix` entry (`nix develop <checkout>
// --command librelane ...`) on the committed path_adder design, from a process
// whose PATH is only the system directories a macOS GUI app gets from launchd
// (`/usr/bin:/bin:/usr/sbin:/sbin`), so `nix` is found only through the engine
// directories SimCrux appends to a child's PATH. Two cases:
//
// - the run finishes, LibreLane's own record says `met`, and SimCrux's reader
//   reads it as verified;
// - a run cancelled with SIGTERM while one of LibreLane's tools (OpenROAD,
//   Yosys, ...) is running exits 143, and no process of its tree is left.
//
// Gated on LIBRELANE_NIX_CHECKOUT, a LibreLane checkout holding its flake, and
// on Nix; FLOW_LIVE_REQUIRED=1 turns a missing one into a failure. The PDK is
// LibreLane's own default (ciel, `~/.ciel`). Tagged `oss-cad-live`, which the
// CI Test job excludes and flow-live.yml runs.

@Tags(['oss-cad-live'])
@Timeout(Duration(minutes: 40))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _design = 'verification/fixtures/flow/librelane/designs/path_adder';

/// A macOS GUI process's PATH, as launchd hands it over.
const _guiPath = '/usr/bin:/bin:/usr/sbin:/sbin';

const _tools = <String>{
  'yosys',
  'openroad',
  'magic',
  'klayout',
  'netgen',
  'sta',
};

bool get _required => Platform.environment['FLOW_LIVE_REQUIRED'] == '1';

String? get _checkout {
  final value = Platform.environment['LIBRELANE_NIX_CHECKOUT'];
  return (value == null || value.isEmpty) ? null : value;
}

bool get _hasNix =>
    File('/nix/var/nix/profiles/default/bin/nix').existsSync() ||
    Process.runSync('which', ['nix']).exitCode == 0;

String? _blocker() {
  if (Platform.isWindows) return 'Nix does not run on Windows';
  final checkout = _checkout;
  if (checkout == null) return 'LIBRELANE_NIX_CHECKOUT is unset';
  if (!File(p.join(checkout, 'flake.nix')).existsSync()) {
    return 'LIBRELANE_NIX_CHECKOUT holds no flake.nix';
  }
  if (!_hasNix) return 'nix is not installed';
  return null;
}

/// The `dart` that runs the CLI from source.
String get _dart {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null && root.isNotEmpty) {
    final dart = p.join(root, 'bin', 'dart');
    if (File(dart).existsSync()) return dart;
  }
  final which = Process.runSync('which', ['dart']);
  return (which.stdout as String).trim();
}

/// pid to (parent pid, command) for every process on the machine.
Map<int, (int, String)> _processes() {
  final out = Process.runSync('ps', ['-axo', 'pid=,ppid=,command=']);
  final rows = <int, (int, String)>{};
  for (final line in LineSplitter.split(out.stdout as String)) {
    final m = RegExp(r'^\s*(\d+)\s+(\d+)\s+(.*)$').firstMatch(line);
    if (m == null) continue;
    rows[int.parse(m[1]!)] = (int.parse(m[2]!), m[3]!);
  }
  return rows;
}

/// Every descendant of [root]: pid to command.
Map<int, String> _tree(int root) {
  final rows = _processes();
  final found = <int, String>{};
  var frontier = <int>{root};
  while (frontier.isNotEmpty) {
    final next = <int>{};
    for (final MapEntry(key: pid, value: (ppid, cmd)) in rows.entries) {
      if (frontier.contains(ppid) && !found.containsKey(pid)) {
        found[pid] = cmd;
        next.add(pid);
      }
    }
    frontier = next;
  }
  return found;
}

bool _isTool(String command) =>
    !command.contains('<defunct>') &&
    _tools.contains(p.basename(command.split(' ').first));

void main() {
  final blocker = _blocker();
  if (blocker != null && _required) {
    test('the live toolchain is installed', () => fail(blocker));
  }

  group('LibreLane nix launcher, from a GUI-like PATH', () {
    late Directory project;
    late String projectFile;
    final env = <String, String>{
      'HOME': Platform.environment['HOME'] ?? '',
      'USER': Platform.environment['USER'] ?? '',
      'PATH': _guiPath,
      'TMPDIR': Directory.systemTemp.path,
    };

    setUp(() {
      project = Directory.systemTemp.createTempSync('flow_nix_launcher_');
      final design = Directory(p.join(project.path, 'design'))..createSync();
      for (final name in <String>['config.yaml', 'path_adder.v']) {
        File(p.join(_design, name)).copySync(p.join(design.path, name));
      }
      projectFile = p.join(project.path, 'simcrux.yaml');
      File(projectFile).writeAsStringSync('''
version: "1"
simulators:
  librelane:
    source: custom
    path: $_checkout
flow:
  entries:
    - name: adder
      kind: librelane
      config: design/config.yaml
      pdk: sky130A
      launcher: nix
''');
    });

    tearDown(() {
      if (project.existsSync()) project.deleteSync(recursive: true);
    });

    Future<Process> start() => Process.start(
      _dart,
      <String>[
        'bin/simcrux.dart',
        'flow',
        'run',
        '--allow-project-tooling',
        '--json',
        projectFile,
      ],
      environment: env,
      includeParentEnvironment: false,
    );

    Map<String, Object?> metricsOf(String stdout) {
      final doc = jsonDecode(stdout) as Map<String, Object?>;
      final entry = (doc['entries']! as List<Object?>).single! as Map;
      return (entry['metrics']! as Map).cast<String, Object?>();
    }

    test('a run finishes and its record reads met, verified', () async {
      final process = await start();
      final out = process.stdout.transform(utf8.decoder).join();
      final err = process.stderr.transform(utf8.decoder).join();
      final code = await process.exitCode;
      final stdout = await out;
      expect(code, 0, reason: await err);
      final metrics = metricsOf(stdout);
      expect(metrics['flow.verdict'], 'met');
      expect(metrics['flow.reader_verified'], 'true');
      expect(metrics['flow.process_exit_code'], '0');
    });

    test('SIGTERM while a LibreLane tool runs ends the whole tree', () async {
      final process = await start();
      final out = process.stdout.transform(utf8.decoder).join();
      unawaited(process.stderr.drain<void>());
      final deadline = DateTime.now().add(const Duration(minutes: 15));
      var tree = <int, String>{};
      while (DateTime.now().isBefore(deadline)) {
        tree = _tree(process.pid);
        if (tree.values.any(_isTool)) break;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      expect(
        tree.values.any(_isTool),
        isTrue,
        reason: 'no LibreLane tool started: $tree',
      );
      expect(process.kill(), isTrue);
      final code = await process.exitCode.timeout(const Duration(minutes: 1));
      expect(code, 143);
      final metrics = metricsOf(await out);
      expect(metrics['flow.process_exit_code'], '-15');
      // Give the tree the driver's grace period to go, then look.
      await Future<void>.delayed(const Duration(seconds: 15));
      final alive = _processes();
      final survivors = <int, String>{
        for (final MapEntry(key: pid, value: cmd) in tree.entries)
          if (alive.containsKey(pid) && !alive[pid]!.$2.contains('<defunct>'))
            pid: cmd,
      };
      expect(survivors, isEmpty);
    });
  }, skip: blocker);
}
