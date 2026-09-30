// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:crux_io/crux_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/kill_signal.dart';
import 'package:simcrux/services/job_scheduler/local_job_scheduler.dart';
import 'package:simcrux/services/job_scheduler/process_reaper.dart';

/// Which binary SimCrux's engine spawns start.
///
/// On Windows, `CreateProcess` searches the directory the app was launched
/// from before `PATH`, and SimCrux is launched from inside the repository
/// whose tests it runs, so a bare `iverilog` would run an `iverilog.exe`
/// committed there. Both production spawn layers resolve the name through
/// `crux_io` first. These drive their Windows branch through an injected
/// [SpawnHost] and a recording starter, so they run on any machine and spawn
/// nothing.
void main() {
  const oss = r'C:\oss-cad-suite\bin';
  const iverilog = r'C:\oss-cad-suite\bin\iverilog.EXE';
  const taskkill = r'C:\Windows\System32\taskkill.EXE';

  SpawnHost windows(Set<String> files, {String path = oss}) => SpawnHost(
    windows: true,
    environment: <String, String>{'PATH': path, 'PATHEXT': '.COM;.EXE'},
    exists: files.contains,
  );

  group('defaultProcessLauncher', () {
    test('a bare engine name is started by its absolute path', () async {
      final starter = _RecordingStarter();
      await defaultProcessLauncher(
        'iverilog',
        const ['-o', 'a.out'],
        workingDirectory: r'C:\work',
        host: windows({iverilog}),
        start: starter.start,
      );
      expect(starter.calls.single.executable, iverilog);
      expect(starter.calls.single.args, ['-o', 'a.out']);
      expect(starter.calls.single.workingDirectory, r'C:\work');
    });

    test("an engine found only on the child's own PATH resolves", () async {
      // The drivers append the platform's engine directories to the child's
      // PATH; a binary found only there must still resolve, and the child
      // must still get that environment.
      final starter = _RecordingStarter();
      final child = <String, String>{'PATH': r'C:\Windows;' + oss};
      await defaultProcessLauncher(
        'iverilog',
        const [],
        environment: child,
        host: windows({iverilog}, path: r'C:\Windows'),
        start: starter.start,
      );
      expect(starter.calls.single.executable, iverilog);
      expect(starter.calls.single.environment, child);
    });

    test('an engine that is not installed starts nothing and throws what a '
        'missing binary throws', () async {
      final starter = _RecordingStarter();
      await expectLater(
        defaultProcessLauncher(
          'iverilog',
          const [],
          host: windows(const {}),
          start: starter.start,
        ),
        throwsA(
          isA<ProcessException>().having(
            (e) => e.executable,
            'executable',
            'iverilog',
          ),
        ),
      );
      expect(
        starter.calls,
        isEmpty,
        reason: 'the bare name must never reach CreateProcess',
      );
    });

    test('off Windows the name is started as written', () async {
      final starter = _RecordingStarter();
      await defaultProcessLauncher(
        'iverilog',
        const [],
        host: const SpawnHost(windows: false),
        start: starter.start,
      );
      expect(starter.calls.single.executable, 'iverilog');
    });
  });

  group('WindowsJobObjectReaper', () {
    test('spawns a bare engine name by its absolute path', () async {
      final starter = _RecordingStarter();
      final reaper = WindowsJobObjectReaper(
        host: windows({iverilog}),
        start: starter.start,
      );
      await reaper.spawnGrouped('iverilog', const ['-V']);
      expect(starter.calls.single.executable, iverilog);
    });

    test('an engine that is not installed starts nothing', () async {
      final starter = _RecordingStarter();
      final reaper = WindowsJobObjectReaper(
        host: windows(const {}),
        start: starter.start,
      );
      await expectLater(
        reaper.spawnGrouped('iverilog', const []),
        throwsA(isA<ProcessException>()),
      );
      expect(starter.calls, isEmpty);
    });

    test('taskkill is run by its absolute path', () async {
      final starter = _RecordingStarter();
      final killed = <(String, List<String>)>[];
      final reaper = WindowsJobObjectReaper(
        host: windows({iverilog, taskkill}, path: '$oss;C:\\Windows\\System32'),
        start: starter.start,
        runSync: (exe, args) {
          killed.add((exe, args));
          return ProcessResult(0, 0, '', '');
        },
      );
      final handle = await reaper.spawnGrouped('iverilog', const []);
      reaper.signalOne(handle, KillSignal.sigkill);
      expect(killed.single.$1, taskkill);
      expect(killed.single.$2, ['/F', '/T', '/PID', '${_FakeProcess.fakePid}']);
      expect(starter.processes.single.killed, isEmpty);
    });

    test('with no taskkill on PATH it falls back to the direct kill, never '
        'the bare name', () async {
      final starter = _RecordingStarter();
      final killed = <String>[];
      final reaper = WindowsJobObjectReaper(
        host: windows({iverilog}),
        start: starter.start,
        runSync: (exe, args) {
          killed.add(exe);
          return ProcessResult(0, 0, '', '');
        },
      );
      final handle = await reaper.spawnGrouped('iverilog', const []);
      reaper.signalOne(handle, KillSignal.sigterm);
      expect(killed, isEmpty);
      expect(starter.processes.single.killed, [ProcessSignal.sigterm]);
    });
  });
}

typedef _StartCall = ({
  String executable,
  List<String> args,
  Map<String, String>? environment,
  String? workingDirectory,
});

class _RecordingStarter {
  final List<_StartCall> calls = <_StartCall>[];
  final List<_FakeProcess> processes = <_FakeProcess>[];

  Future<Process> start(
    String executable,
    List<String> args, {
    Map<String, String>? environment,
    String? workingDirectory,
  }) async {
    calls.add((
      executable: executable,
      args: List<String>.unmodifiable(args),
      environment: environment,
      workingDirectory: workingDirectory,
    ));
    final process = _FakeProcess();
    processes.add(process);
    return process;
  }
}

class _FakeProcess implements Process {
  static const int fakePid = 4242;

  final List<ProcessSignal> killed = <ProcessSignal>[];

  @override
  int get pid => fakePid;

  @override
  Future<int> get exitCode => Completer<int>().future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed.add(signal);
    return true;
  }

  @override
  Stream<List<int>> get stdout => const Stream<List<int>>.empty();

  @override
  Stream<List<int>> get stderr => const Stream<List<int>>.empty();

  @override
  IOSink get stdin => throw UnimplementedError();
}
