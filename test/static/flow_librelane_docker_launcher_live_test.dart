// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Live: the LibreLane `docker` launcher, the way the desktop app starts it.
//
// `simcrux flow run` runs a `launcher: docker` entry (`docker run --rm --name
// simcrux-TAG ... IMAGE librelane ...`) on the committed path_adder design,
// from a process whose PATH is only the system directories a GUI app gets
// (`/usr/bin:/bin:/usr/sbin:/sbin`). Two cases:
//
// - the run finishes, LibreLane's own record says `met`, SimCrux's reader
//   reads it as verified, `--rm` left no container behind, and every file of
//   the run directory belongs to the user who started it (a container that
//   ran as root would leave a run directory the user cannot delete);
// - a run cancelled with SIGTERM while one of LibreLane's tools (OpenROAD,
//   Yosys, ...) runs in the container exits 143, and soon after neither the
//   container nor any of its tools is left. Killing the `docker run` client
//   alone does not stop a container, so this is the case that proves the
//   driver's `docker stop`.
//
// The PDK is the host's LibreLane default (`~/.ciel`, or `PDK_ROOT`), which
// the launcher mounts into the container.
//
// Gated on LIBRELANE_DOCKER_IMAGE (for example
// `ghcr.io/librelane/librelane:3.0.16`) and on a working `docker`;
// FLOW_LIVE_REQUIRED=1 turns a missing one into a failure. Tagged
// `oss-cad-live`, which the CI Test job excludes and flow-live.yml runs.

@Tags(['oss-cad-live'])
@Timeout(Duration(minutes: 40))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _design = 'verification/fixtures/flow/librelane/designs/path_adder';

/// A GUI process's PATH, as the desktop session hands it over.
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

String? get _image {
  final value = Platform.environment['LIBRELANE_DOCKER_IMAGE'];
  return (value == null || value.isEmpty) ? null : value;
}

bool get _dockerAnswers {
  try {
    return Process.runSync('docker', ['version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

String? _blocker() {
  if (Platform.isWindows) return 'the Docker launcher is not run on Windows';
  if (_image == null) return 'LIBRELANE_DOCKER_IMAGE is unset';
  if (!_dockerAnswers) return 'docker is not installed or not running';
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

/// Every process on the machine: pid to command.
Map<int, String> _processes() {
  final out = Process.runSync('ps', ['-axo', 'pid=,command=']);
  final rows = <int, String>{};
  for (final line in LineSplitter.split(out.stdout as String)) {
    final m = RegExp(r'^\s*(\d+)\s+(.*)$').firstMatch(line);
    if (m == null) continue;
    rows[int.parse(m[1]!)] = m[2]!;
  }
  return rows;
}

bool _isTool(String command) =>
    !command.contains('<defunct>') &&
    _tools.contains(p.basename(command.split(' ').first));

/// The processes on this machine that are LibreLane tools. A container's
/// processes are host processes, children of the container runtime and not
/// of the `docker` client, so the whole table is searched; nothing else on a
/// CI runner runs OpenROAD.
Map<int, String> _toolsRunning() => <int, String>{
  for (final MapEntry(key: pid, value: cmd) in _processes().entries)
    if (_isTool(cmd)) pid: cmd,
};

/// The names of SimCrux's containers, running or not.
List<String> _containers() {
  final out = Process.runSync('docker', [
    'ps',
    '--all',
    '--filter',
    'name=^simcrux-',
    '--format',
    '{{.Names}}',
  ]);
  return LineSplitter.split(
    out.stdout as String,
  ).where((l) => l.trim().isNotEmpty).toList();
}

/// A measurement line; flow-live.yml copies `docker launcher:` lines into the
/// job summary.
void _report(String line) {
  // The test runner's own output is where a live test's measurements go.
  // ignore: avoid_print
  print(line);
}

String _id(String flag) =>
    (Process.runSync('id', [flag]).stdout as String).trim();

void main() {
  final blocker = _blocker();
  if (blocker != null && _required) {
    test('the live toolchain is installed', () => fail(blocker));
  }

  group('LibreLane docker launcher, from a GUI-like PATH', () {
    late Directory project;
    late String projectFile;
    final env = <String, String>{
      'HOME': Platform.environment['HOME'] ?? '',
      'USER': Platform.environment['USER'] ?? '',
      'PATH': _guiPath,
      'TMPDIR': Directory.systemTemp.path,
      'PDK_ROOT': ?Platform.environment['PDK_ROOT'],
    };

    setUp(() {
      project = Directory.systemTemp.createTempSync('flow_docker_launcher_');
      final design = Directory(p.join(project.path, 'design'))..createSync();
      for (final name in <String>['config.yaml', 'path_adder.v']) {
        File(p.join(_design, name)).copySync(p.join(design.path, name));
      }
      projectFile = p.join(project.path, 'simcrux.yaml');
      File(projectFile).writeAsStringSync('''
version: "1"
flow:
  entries:
    - name: adder
      kind: librelane
      config: design/config.yaml
      pdk: sky130A
      launcher: docker
      docker_image: $_image
''');
    });

    tearDown(() {
      try {
        if (project.existsSync()) project.deleteSync(recursive: true);
      } on FileSystemException {
        // A run directory a container wrote as root cannot be removed here;
        // the ownership expectation below is what reports that.
      }
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

    test(
      'a run finishes, reads met, verified, and leaves nothing behind',
      () async {
        final clock = Stopwatch()..start();
        final process = await start();
        final out = process.stdout.transform(utf8.decoder).join();
        final err = process.stderr.transform(utf8.decoder).join();
        final code = await process.exitCode;
        final output = await out;
        _report(
          'docker launcher: run finished in ${clock.elapsed.inSeconds} s',
        );
        expect(code, 0, reason: await err);
        final metrics = metricsOf(output);
        expect(metrics['flow.verdict'], 'met');
        expect(metrics['flow.reader_verified'], 'true');
        expect(metrics['flow.process_exit_code'], '0');
        expect(_containers(), isEmpty, reason: '--rm left a container');
        final runDir = metrics['flow.run_dir']! as String;
        final foreign = Process.runSync('find', [
          runDir,
          '(',
          '!',
          '-user',
          _id('-u'),
          '-o',
          '!',
          '-group',
          _id('-g'),
          ')',
          '-print',
        ]);
        expect(
          (foreign.stdout as String).trim(),
          isEmpty,
          reason: 'files of the run belong to another user',
        );
      },
    );

    test(
      'SIGTERM while a LibreLane tool runs stops the container too',
      () async {
        final process = await start();
        final out = process.stdout.transform(utf8.decoder).join();
        unawaited(process.stderr.drain<void>());
        final deadline = DateTime.now().add(const Duration(minutes: 15));
        var tools = <int, String>{};
        while (DateTime.now().isBefore(deadline)) {
          tools = _toolsRunning();
          if (tools.isNotEmpty) break;
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        expect(tools, isNotEmpty, reason: 'no LibreLane tool started');
        final running = _containers();
        expect(running, hasLength(1));
        final clock = Stopwatch()..start();
        expect(process.kill(), isTrue);
        final code = await process.exitCode.timeout(const Duration(minutes: 1));
        final exited = clock.elapsed;
        expect(code, 143);
        final metrics = metricsOf(await out);
        expect(metrics['flow.verdict'], isNot('met'));
        expect(metrics['flow.process_exit_code'], isNot('0'));
        // `docker stop --time 10` gives LibreLane ten seconds, then kills the
        // container; `--rm` removes it. A minute covers both.
        final gone = DateTime.now().add(const Duration(minutes: 1));
        while (DateTime.now().isBefore(gone) &&
            (_containers().isNotEmpty || _toolsRunning().isNotEmpty)) {
          await Future<void>.delayed(const Duration(seconds: 1));
        }
        _report(
          'docker launcher: the CLI exited in ${exited.inMilliseconds} ms; '
          'the container and its tools were gone '
          '${clock.elapsed.inSeconds} s after SIGTERM '
          '(process exit ${metrics['flow.process_exit_code']}, '
          'stopped at ${metrics['flow.stopped_step'] ?? '?'})',
        );
        expect(_containers(), isEmpty, reason: 'the container survived');
        expect(_toolsRunning(), isEmpty, reason: 'a tool survived');
      },
    );
  }, skip: blocker);
}
