// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Launch test: on Linux, a file dialog opens with no reachable DBus session
// bus, as on a host displayed remotely (ssh X forwarding, VNC, ETX or NX, a
// farm job started from another host).
//
// It runs in this app's own build, so the runner under test is
// `linux/runner/my_application.cc` with the crux_file_dialogs channel. The
// Linux file-dialog workflow runs it under Xvfb with DBUS_SESSION_BUS_ADDRESS
// naming a socket that does not exist, passes
// `--dart-define=CRUX_FILE_DIALOG_PROBE=true`, and has xdotool installed. It
// then checks, in order:
//
//  1. file_picker's own portal implementation fails there, so the
//     environment really has no session bus;
//  2. the GTK picker bootstrap installs opens a dialog, found as an X window
//     by its title;
//  3. Escape in that dialog answers the call with a cancel, so the reply
//     comes back over the channel.
//
// Without the define (the weekly integration suite, another platform) it
// skips: the steps need the virtual display and xdotool.

import 'dart:async';
import 'dart:io';

import 'package:crux_file_dialogs/crux_file_dialogs.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'helpers/app_driver.dart' show suppressPlatformSemanticsLeak;

const bool _probe = bool.fromEnvironment('CRUX_FILE_DIALOG_PROBE');

/// The title the dialog is opened with and found by.
const String _title = 'crux-file-dialog-probe';

/// The X window ids whose name is exactly [_title].
Future<List<String>> _dialogWindows() async {
  final result = await Process.run('xdotool', <String>[
    'search',
    '--onlyvisible',
    '--name',
    '^$_title\$',
  ]);
  return '${result.stdout}'
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
}

Future<void> _xdotool(List<String> arguments) async {
  final result = await Process.run('xdotool', arguments);
  if (result.exitCode != 0) {
    fail('xdotool ${arguments.join(' ')}: ${result.stderr}');
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  suppressPlatformSemanticsLeak();

  testWidgets(
    'a file dialog opens on the display with no session bus',
    (tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      final portal = FilePickerPlatform.instance;
      expect(portal, isNot(isA<GtkFilePicker>()));

      // 1. The portal implementation has no bus to talk to.
      Object? portalError;
      try {
        await portal
            .pickFiles(dialogTitle: 'portal')
            .timeout(const Duration(seconds: 20));
      } on Object catch (e) {
        portalError = e;
      }
      expect(
        portalError,
        isNotNull,
        reason:
            "file_picker's portal call succeeded, so a session bus is "
            'reachable and this run proves nothing',
      );

      // 2. The GTK picker opens a dialog the X server can see.
      useGtkFileDialogsOnLinux();
      expect(FilePickerPlatform.instance, isA<GtkFilePicker>());
      final picked = FilePicker.pickFiles(dialogTitle: _title);
      var windows = const <String>[];
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (windows.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        windows = await _dialogWindows();
      }
      expect(
        windows,
        isNotEmpty,
        reason: 'no X window titled "$_title" appeared',
      );

      // 3. Escape cancels it, and the cancel comes back as null.
      FilePickerResult? result;
      var answered = false;
      unawaited(
        picked.then((value) {
          result = value;
          answered = true;
        }),
      );
      for (var attempt = 0; attempt < 5 && !answered; attempt++) {
        await _xdotool(<String>['windowfocus', '--sync', windows.first]);
        await _xdotool(<String>['key', '--clearmodifiers', 'Escape']);
        final until = DateTime.now().add(const Duration(seconds: 4));
        while (!answered && DateTime.now().isBefore(until)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
      expect(answered, isTrue, reason: 'the dialog never answered');
      expect(result, isNull);
      expect(await _dialogWindows(), isEmpty);
    },
    skip: !_probe || !Platform.isLinux,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
