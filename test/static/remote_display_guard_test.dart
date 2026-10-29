// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Static guard for what a Linux host displayed remotely (ssh X forwarding,
// VNC, ETX or NX, a farm job started from another host) needs from this app:
//
//  1. File dialogs drawn in-process with GTK. file_picker's own Linux code
//     asks the DBus desktop portal to draw them, which fails with no
//     reachable session bus. The runner serves crux_file_dialogs' channel and
//     bootstrap installs its GtkFilePicker; without either half, Open, Save
//     and Export fail there with a SocketException.
//  2. A link no browser opened, or a file no file manager showed, is
//     reported, never dropped: every link goes through cruxOpenUrl and every
//     reveal through cruxRevealFile, which name the address or the path.
//
// The launch test `integration_test/linux_file_dialog_test.dart` proves the
// dialog opens under Xvfb with no session bus; this test makes the wiring it
// depends on fail fast, on every platform.

import 'dart:io';

import 'package:crux_file_dialogs/crux_file_dialogs_guards.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

String _read(String path) => File(path).readAsStringSync();

String _code(String source) => source
    .split('\n')
    .map((line) {
      final comment = line.indexOf('//');
      return comment < 0 ? line : line.substring(0, comment);
    })
    .join('\n');

void main() {
  test('the Linux runner serves the GTK file-dialog channel', () {
    final findings = cruxCheckLinuxRunnerFileDialogs(
      myApplicationCc: _read('linux/runner/my_application.cc'),
      runnerCmake: _read('linux/runner/CMakeLists.txt'),
      linuxCmake: _read('linux/CMakeLists.txt'),
    );
    expect(findings, isEmpty, reason: findings.join('\n'));
  });

  test('bootstrap installs the GTK file picker once the binding is up', () {
    final app = _code(_read('lib/app.dart'));
    final binding = app.indexOf('WidgetsFlutterBinding.ensureInitialized();');
    final install = app.indexOf('useGtkFileDialogsOnLinux();');
    expect(install, isNonNegative, reason: 'bootstrap never installs it');
    expect(
      install,
      greaterThan(binding),
      reason: 'the picker is installed before the binding exists',
    );
  });

  test('links and reveals go through cruxOpenUrl and cruxRevealFile', () {
    final findings = <String>[];
    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      final code = _code(file.readAsStringSync());
      final rel = p.posix.joinAll(p.split(file.path));
      if (RegExp(r'\blaunchUrl(?:String)?\b').hasMatch(code)) {
        findings.add('$rel names launchUrl; call cruxOpenUrl instead.');
      }
      if (RegExp(r'\brevealInFileManager\b').hasMatch(code)) {
        findings.add(
          '$rel names revealInFileManager; call cruxRevealFile instead.',
        );
      }
    }
    expect(findings, isEmpty, reason: findings.join('\n'));
  });
}
