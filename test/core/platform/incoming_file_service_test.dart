// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/platform/incoming_file_service.dart';

/// The Dart half of the macOS file-open handler: what it asks the native
/// side (`macos/Runner/AppDelegate.swift`) and what it emits.
///
/// The native side is played by mock handlers on the real channel names, so
/// a rename on either side of the contract turns these red. Whether the
/// Swift half builds is proved by the macOS build, not here.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger
      ..setMockMethodCallHandler(IncomingFileService.methodChannel, null)
      ..setMockStreamHandler(IncomingFileService.eventChannel, null);
  });

  /// Plays the native side: [launchFile] answers `getInitialFile`, and
  /// [later] is what the event channel delivers once listened to.
  void native({String? launchFile, List<Object?> later = const []}) {
    messenger
      ..setMockMethodCallHandler(IncomingFileService.methodChannel, (
        call,
      ) async {
        expect(call.method, 'getInitialFile');
        return launchFile;
      })
      ..setMockStreamHandler(
        IncomingFileService.eventChannel,
        MockStreamHandler.inline(
          onListen: (_, sink) {
            later.forEach(sink.success);
            sink.endOfStream();
          },
        ),
      );
  }

  test('the launch file comes first, then the ones that follow', () async {
    native(
      launchFile: '/work/soc/simcrux.yaml',
      later: ['/work/soc/other.yml', '/work/design.crux-project'],
    );
    expect(
      await IncomingFileService(supported: true).openedFiles().toList(),
      [
        '/work/soc/simcrux.yaml',
        '/work/soc/other.yml',
        '/work/design.crux-project',
      ],
    );
  });

  test('no launch file: only what arrives later', () async {
    native(later: ['/work/a.simcrux-workspace']);
    expect(
      await IncomingFileService(supported: true).openedFiles().toList(),
      ['/work/a.simcrux-workspace'],
    );
  });

  test('empty and non-string events are dropped', () async {
    native(launchFile: '', later: ['', 42, null, '/work/b.yaml']);
    expect(
      await IncomingFileService(supported: true).openedFiles().toList(),
      ['/work/b.yaml'],
    );
  });

  test(
    'with no native half it emits nothing and never listens to the event '
    'channel',
    () async {
      // No method handler: the call fails with MissingPluginException, as in
      // a runner without the handler. Listening to the event channel then
      // would be reported as an error by the framework, not to the stream.
      var listened = false;
      messenger.setMockStreamHandler(
        IncomingFileService.eventChannel,
        MockStreamHandler.inline(
          onListen: (_, sink) {
            listened = true;
            sink.endOfStream();
          },
        ),
      );
      expect(
        await IncomingFileService(supported: true).openedFiles().toList(),
        isEmpty,
      );
      expect(listened, isFalse);
    },
  );

  test('a native error is logged and emits nothing', () async {
    messenger.setMockMethodCallHandler(
      IncomingFileService.methodChannel,
      (_) async => throw PlatformException(code: 'boom'),
    );
    expect(
      await IncomingFileService(supported: true).openedFiles().toList(),
      isEmpty,
    );
  });

  test('off macOS nothing is asked', () async {
    var asked = false;
    messenger.setMockMethodCallHandler(IncomingFileService.methodChannel, (
      _,
    ) async {
      asked = true;
      return '/work/simcrux.yaml';
    });
    expect(
      await IncomingFileService(supported: false).openedFiles().toList(),
      isEmpty,
    );
    expect(asked, isFalse);
  });
}
