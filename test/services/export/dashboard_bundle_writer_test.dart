// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/services/export/dashboard_bundle_writer.dart';
import 'package:simcrux/services/result_store/ndjson_recovery.dart';

/// The writer normalizes the output dir to an absolute path; `/out` resolves
/// to `D:\out` on Windows. Normalize expectations the same way so they hold
/// on every OS.
String _abs(String path) => p.normalize(p.absolute(path));

void main() {
  group('DashboardBundleWriter', () {
    test('NDJSON → consolidated simcrux-results.json', () async {
      const ndjson = '''
{"type":"meta","version":1,"run_id":"r1","started_at":"2026-01-01T00:00:00.000Z","config_path":"/p.yaml"}
{"type":"result","id":"a/b","name":"b","suite":"a","simulator":"icarus","status":"pass","runtime_ms":10,"started_at":"2026-01-01T00:00:00.000Z","finished_at":"2026-01-01T00:00:00.010Z","exit_code":0,"metrics":{"cycles":"42"}}
{"type":"summary","total":1,"totals":{"pass":1},"finished_at":"2026-01-01T00:00:00.020Z"}
''';
      final files = <String, String>{};
      final ensured = <String>{};
      final stdoutLines = <String>[];
      final writer = DashboardBundleWriter(
        readText: (path) async => path == '/in/results.ndjson'
            ? ndjson
            : throw FileSystemException('not found', path),
        writeText: (path, contents) async => files[path] = contents,
        copyFile: (_, _) async => fail('no bundle expected'),
        listDirectory: (_) => const Stream<FileSystemEntity>.empty(),
        ensureDirectory: (d) async => ensured.add(d),
        stdoutWriter: stdoutLines.add,
      );
      final result = await writer.run(const [
        '/out',
        '--results',
        '/in/results.ndjson',
      ]);
      expect(result.outputDir, _abs('/out'));
      expect(files.keys.single.endsWith('simcrux-results.json'), isTrue);
      final consolidated = files.values.single;
      expect(consolidated, contains('"version": 1'));
      expect(consolidated, contains('"id": "r1"'));
      expect(consolidated, contains('"id": "a/b"'));
      expect(consolidated, contains('"status": "pass"'));
      expect(consolidated, contains('"metrics"'));
      expect(consolidated, contains('"cycles": "42"'));
      expect(ensured, contains(_abs('/out')));
      expect(stdoutLines.single, contains('simcrux-results.json'));
    });

    test('passes through an already-consolidated JSON file verbatim', () async {
      const consolidated =
          '{"version":1,"run":{"id":"r"},"tests":[{"id":"a","status":"pass"}]}';
      final files = <String, String>{};
      final recovery = _RecordingRecovery();
      final writer = DashboardBundleWriter(
        readText: (_) async => consolidated,
        writeText: (path, contents) async => files[path] = contents,
        copyFile: (_, _) async {},
        listDirectory: (_) => const Stream<FileSystemEntity>.empty(),
        ensureDirectory: (_) async {},
        stdoutWriter: (_) {},
        recovery: recovery,
      );
      await writer.run(const ['/out', '--results', '/in/x.json']);
      expect(files.values.single, consolidated);
      // A consolidated file is not a streaming NDJSON log — recovery must
      // NOT run against it (it would treat the single JSON object as a
      // truncated record and corrupt it).
      expect(recovery.calls, isEmpty);
    });

    test('runs NDJSON recovery on the source before decoding', () async {
      const ndjson =
          '{"type":"meta","run_id":"r"}\n'
          '{"type":"summary","total":0,"totals":{}}';
      final recovery = _RecordingRecovery();
      final writer = DashboardBundleWriter(
        readText: (_) async => ndjson,
        writeText: (_, _) async {},
        copyFile: (_, _) async {},
        listDirectory: (_) => const Stream<FileSystemEntity>.empty(),
        ensureDirectory: (_) async {},
        stdoutWriter: (_) {},
        recovery: recovery,
      );
      await writer.run(const ['/out', '--results', '/in/results.ndjson']);
      // The NDJSON branch repairs the source in place before decoding —
      // reverting the wiring (back to NoopNdjsonRecovery only) makes this
      // empty.
      expect(recovery.calls, ['/in/results.ndjson']);
    });

    test(
      'end-to-end: repairs a crash-truncated results.ndjson on disk '
      '(default FileNdjsonRecovery)',
      () async {
        final dir = await Directory.systemTemp.createTemp('bundle_recover_');
        addTearDown(() => dir.delete(recursive: true));
        final resultsPath = p.join(dir.path, 'results.ndjson');
        // A complete meta + result, then a summary line truncated mid-write
        // (no trailing newline, invalid JSON) — the crash signature.
        const truncated =
            '{"type":"meta","version":1,"run_id":"r1",'
            '"started_at":"2026-01-01T00:00:00.000Z","config_path":"/p.yaml"}\n'
            '{"type":"result","id":"a/b","name":"b","suite":"a",'
            '"simulator":"icarus","status":"pass","runtime_ms":10,'
            '"started_at":"2026-01-01T00:00:00.000Z",'
            '"finished_at":"2026-01-01T00:00:00.010Z","exit_code":0}\n'
            '{"type":"summary","total":1,"totals":{"pa';
        await File(resultsPath).writeAsString(truncated);

        final files = <String, String>{};
        // Default readText + default FileNdjsonRecovery → real disk path.
        final writer = DashboardBundleWriter(
          writeText: (path, contents) async => files[path] = contents,
          copyFile: (_, _) async {},
          listDirectory: (_) => const Stream<FileSystemEntity>.empty(),
          ensureDirectory: (_) async {},
          stdoutWriter: (_) {},
        );
        await writer.run(['/out', '--results', resultsPath]);

        // The complete records survived; the garbled summary tail was
        // dropped rather than crashing the decode.
        final consolidated = files.values.single;
        expect(consolidated, contains('"id": "a/b"'));
        expect(consolidated, contains('"status": "pass"'));
        // The on-disk file was repaired (truncated tail trimmed, trailing
        // newline restored).
        final repaired = await File(resultsPath).readAsString();
        expect(repaired.endsWith('\n'), isTrue);
        expect(repaired, isNot(contains('"totals":{"pa')));
      },
    );

    test('copies web bundle files', () async {
      const ndjson =
          '{"type":"meta","run_id":"r"}\n{"type":"summary","total":0,"totals":{}}';
      final files = <String, String>{};
      final copies = <String, String>{};
      final writer = DashboardBundleWriter(
        readText: (_) async => ndjson,
        writeText: (path, contents) async => files[path] = contents,
        copyFile: (src, dst) async => copies[dst] = src,
        listDirectory: (dir) async* {
          // Synthesize a fake build/web tree.
          yield _FakeFile('$dir/index.html', size: 200);
          yield _FakeFile('$dir/main.dart.js', size: 12000);
          yield _FakeFile('$dir/assets/font.ttf', size: 5000);
        },
        ensureDirectory: (_) async {},
        stdoutWriter: (_) {},
      );
      final result = await writer.run(
        const ['/out', '--results', '/in/r.ndjson', '--web-bundle', '/bld/web'],
      );
      expect(result.filesCopied, 3);
      expect(
        copies.keys,
        containsAll([
          p.join(_abs('/out'), 'index.html'),
          p.join(_abs('/out'), 'main.dart.js'),
        ]),
      );
    });

    test('rejects multiple positional output dirs', () {
      final writer = DashboardBundleWriter(
        readText: (_) async => '',
        writeText: (_, _) async {},
        copyFile: (_, _) async {},
        listDirectory: (_) => const Stream<FileSystemEntity>.empty(),
        ensureDirectory: (_) async {},
        stdoutWriter: (_) {},
      );
      expect(
        () => writer.run(const ['/a', '/b']),
        throwsA(isA<DashboardBundleException>()),
      );
    });
  });
}

/// Records the paths [recover] is invoked with; never touches the disk.
class _RecordingRecovery implements NdjsonRecovery {
  final List<String> calls = <String>[];

  @override
  Future<NdjsonRecoveryResult> recover(String path) async {
    calls.add(path);
    return NdjsonRecoveryResult.clean;
  }
}

class _FakeFile implements File {
  _FakeFile(this.path, {required this.size});
  @override
  final String path;
  final int size;

  @override
  int lengthSync() => size;

  // Below: stub everything else to satisfy the interface. We only
  // need `path` + `lengthSync` for the bundle-writer's traversal.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
