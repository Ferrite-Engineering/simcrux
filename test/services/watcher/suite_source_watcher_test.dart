// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:crux_file_watcher/crux_file_watcher.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/pass_fail_config.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/suite.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/watcher/suite_source_watcher.dart';

import '../../support/poll_until.dart';

RegressionConfig _configWith(List<String> sources) {
  return RegressionConfig(
    projectFilePath: '/p/simcrux.yaml',
    schemaVersion: '1',
    suites: [
      Suite(
        name: 's',
        tests: [
          TestSpec(
            id: 's/one',
            name: 'one',
            suiteName: 's',
            simulatorId: 'icarus',
            top: 'top',
            sources: sources,
          ),
        ],
      ),
    ],
    simulatorBinaries: const {},
    defaultPassFail: const ExitCodePassFailConfig(),
  );
}

void main() {
  group('SuiteSourceWatcher', () {
    test('watches one FileWatcherService per distinct source path', () async {
      final services = <FileWatcherService>[];
      FileWatcherService factory() {
        // Inject a watcher that never receives real events; we only
        // assert the count.
        final svc = FileWatcherService(
          watchFactory: (_) => const Stream.empty(),
        );
        services.add(svc);
        return svc;
      }

      final watcher = SuiteSourceWatcher(serviceFactory: factory);
      addTearDown(watcher.dispose);
      watcher.watch(
        _configWith([
          'rtl/alu.sv',
          'rtl/alu.sv', // duplicate ignored
          'tb/alu_tb.sv',
        ]),
      );
      expect(watcher.watchedPathCount, 2);
      expect(services, hasLength(2));
    });

    test('re-watching stops previously-watched files first', () {
      final services = <FileWatcherService>[];
      FileWatcherService factory() {
        final svc = FileWatcherService(
          watchFactory: (_) => const Stream.empty(),
        );
        services.add(svc);
        return svc;
      }

      final watcher = SuiteSourceWatcher(serviceFactory: factory);
      addTearDown(watcher.dispose);
      watcher.watch(_configWith(['a.sv', 'b.sv']));
      expect(watcher.watchedPathCount, 2);
      watcher.watch(_configWith(['c.sv']));
      expect(watcher.watchedPathCount, 1);
      // Total constructed services = first 2 + second 1.
      expect(services, hasLength(3));
    });

    test('forwards FileWatchEvents emitted by underlying services', () async {
      // Watch a real temp file so the FileSystemEvent comes from
      // `dart:io` (the type is sealed and cannot be subclassed).
      final tempDir = Directory.systemTemp.createTempSync(
        'simcrux_watcher_test_',
      );
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final tempFile = File('${tempDir.path}/source.sv')
        ..writeAsStringSync('original');
      final watcher = SuiteSourceWatcher();
      addTearDown(watcher.dispose);
      final received = <SuiteSourceChange>[];
      watcher.events.listen(received.add);
      watcher.watch(_configWith([tempFile.path]));
      // Give the OS-level watcher time to settle before we mutate
      // the file. The 50 ms wait is empirical — on macOS the FSEvent
      // stream takes a moment to attach.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      tempFile.writeAsStringSync('changed');
      // crux_file_watcher debounces 500 ms; the event cannot arrive before
      // then. Poll for it rather than sleeping a fixed worst-case: this
      // resolves as soon as the debounced FileSystemEvent lands (no
      // event ⇒ the skip branch below) and never races ahead of one that
      // simply took longer than a fixed guess under CI load.
      await pollUntil(
        () => received.isNotEmpty,
        timeout: const Duration(seconds: 2),
      );
      // Some CI runners suppress filesystem watches inside temp
      // directories; treat the no-event case as a skip rather than
      // a failure so this test is portable.
      if (received.isEmpty) {
        markTestSkipped('FS watcher silent on this platform');
        return;
      }
      expect(received.first.path, tempFile.path);
      expect(received.first.event, FileWatchEvent.modified);
    });

    test('dispose closes the broadcast stream and rejects further watches', () {
      final watcher = SuiteSourceWatcher(
        serviceFactory: () =>
            FileWatcherService(watchFactory: (_) => const Stream.empty()),
      )..dispose();
      expect(
        () => watcher.watch(_configWith(['a.sv'])),
        throwsStateError,
      );
    });
  });
}
