// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

final _log = Logger('simcrux.platform');

/// Receives files macOS opens on SimCrux's behalf: a Finder double-click,
/// `open -a SimCrux <file>`, or a file dropped on the Dock icon.
///
/// `macos/Runner/Info.plist` registers four document types (`.yaml`/`.yml`,
/// `.crux-project`, `.simcrux-session`, `.simcrux-workspace`), so Finder
/// offers SimCrux for them and launches it on a double-click. macOS delivers
/// the file as an Apple Event, not as a command-line argument, so without a
/// receiver the app opened empty. The native half is `application(_:open:)`
/// in `macos/Runner/AppDelegate.swift`, registered by
/// `macos/Runner/MainFlutterWindow.swift`; it buffers what arrives before
/// Dart is listening, which on a cold launch is the file that caused the
/// launch.
///
/// What arrives is routed exactly as the same path on the command line
/// would be (see `CliRegressionBootstrapper`), so a
/// double-clicked project loads through the same config loader, with the
/// same project-tooling gate, and does not start a regression unless the
/// user turned on running on open. A double-click is a zero-click open of
/// whatever file was clicked, which is why nothing here may take a shorter
/// route.
///
/// Windows and Linux receive files as command-line arguments, and web has
/// no files to receive, so there [openedFiles] never emits. The channel
/// names mirror WaveCrux's.
class IncomingFileService {
  /// Creates an [IncomingFileService]. [supported] defaults to "running on
  /// macOS"; tests pass it to exercise the channel off macOS.
  IncomingFileService({bool? supported})
    : _supported = supported ?? (!kIsWeb && Platform.isMacOS);

  /// Method channel answering `getInitialFile`.
  static const MethodChannel methodChannel = MethodChannel(
    'com.simcrux/incoming_file',
  );

  /// Event channel carrying files opened while the app is running.
  static const EventChannel eventChannel = EventChannel(
    'com.simcrux/incoming_file_stream',
  );

  final bool _supported;

  /// Absolute paths of the files macOS opens on the app's behalf, starting
  /// with any that launched it.
  ///
  /// Listening asks the native side for the launch file first (which also
  /// tells it Dart is ready), then follows the event channel for the rest:
  /// a second file in the same Finder selection, and every later
  /// double-click while the app runs. Listen once, from the widget that
  /// routes the paths, and only in the state that will route them: the
  /// native side hands the launch file out once.
  ///
  /// Emits nothing where there is no native half to ask: off macOS, and in
  /// a runner or a test that registers no handler. Probing with the method
  /// call first is what keeps the event channel from being listened to with
  /// nothing on the other end, which Flutter reports as an error rather than
  /// delivering it to the stream.
  Stream<String> openedFiles() async* {
    if (!_supported) return;
    final String? first;
    try {
      first = await methodChannel.invokeMethod<String>('getInitialFile');
    } on MissingPluginException {
      return;
    } on PlatformException catch (e) {
      _log.warning('Could not read the file macOS opened at launch: $e');
      return;
    }
    if (first != null && first.isNotEmpty) yield first;
    yield* eventChannel
        .receiveBroadcastStream()
        .where((event) => event is String && event.isNotEmpty)
        .cast<String>();
  }
}

/// The app's [IncomingFileService]. Overridden in tests.
final Provider<IncomingFileService> incomingFileServiceProvider =
    Provider<IncomingFileService>((ref) => IncomingFileService());
