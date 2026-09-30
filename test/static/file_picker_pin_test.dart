// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Refuses `file_picker` 12.0.0, which is **broken on macOS**.
///
/// 12.0.0 split the plugin into federated platform packages and, in the split,
/// lost the macOS Dart implementation. `file_picker_darwin` 1.0.0 has one Dart
/// class serving two native handlers that speak different protocols: it sends
/// the iOS method names (the *file type* — `custom`, `any`, `image`) while
/// `MacOSFilePickerHandler.swift` switches on the *operation* (`pickFiles`,
/// `saveFile`, `getDirectoryPath`). Every call lands on
/// `FlutterMethodNotImplemented`, which reaches Dart as:
///
///     MissingPluginException(No implementation found for method custom on
///     channel miguelruivo.flutter.plugins.filepicker)
///
/// Open, save and pick-directory are all dead on macOS. Only `clear` survives.
///
/// **Why a static guard rather than a test that opens a file.** Nothing caught
/// this. `flutter analyze` was clean, every unit test passed, and CI was green
/// on all eight repositories — because the suite has no macOS UI test that
/// reaches a file picker, and Linux (pure Dart), Windows (`windows_file_picker`)
/// and iOS are all unaffected. The failure appeared the first time a human
/// opened a file in a desktop build. A version assertion is the cheapest thing
/// that fails in CI instead.
///
/// 12.0.0-beta.7 is the last working version: it carries a *separate*
/// `lib/src/platform/macos/file_picker_macos.dart` that speaks the macOS
/// protocol. It is a prerelease, hence the exact pin rather than a caret.
///
/// Lift this only when a `file_picker_darwin` newer than 1.0.0 publishes with
/// the macOS Dart implementation restored — and verify by opening a file in a
/// real macOS build before believing it.
void main() {
  const pinnedVersion = '12.0.0-beta.7';

  late String lock;

  setUpAll(() {
    final file = File('pubspec.lock');
    expect(
      file.existsSync(),
      isTrue,
      reason:
          'pubspec.lock is missing, so this guard cannot see the resolved '
          'version. The lock is tracked on purpose — an untracked lock is how '
          'the unwanted 12.0.0 arrived in the first place, by caret drift on a '
          'prerelease constraint.',
    );
    // Line endings normalised before matching. Windows checks the lock out
    // with CRLF, and both patterns below anchor on '\n' — so on Windows they
    // matched nothing, the version came back null, and this guard failed in
    // every repository on the nightly windows-latest job while passing
    // everywhere a human ran it.
    lock = file.readAsStringSync().replaceAll('\r\n', '\n');
  });

  test('file_picker stays pinned to the last version that works on macOS', () {
    final match = RegExp(
      r'^  file_picker:\n(?:.*\n)*?    version: "([^"]+)"',
      multiLine: true,
    ).firstMatch(lock);

    expect(
      match?.group(1),
      pinnedVersion,
      reason:
          'file_picker must resolve to $pinnedVersion. 12.0.0 is broken on '
          'macOS: open, save and pick-directory all raise '
          'MissingPluginException because file_picker_darwin 1.0.0 speaks the '
          'iOS method-name protocol to the macOS native handler.\n\n'
          'This is invisible to analyze, to the unit suite and to CI — the '
          'first symptom is a human failing to open a file. Do not relax the '
          'pin to make this test pass.',
    );
  });

  test('no federated file_picker platform package is resolved', () {
    // The federated packages exist only in 12.0.0 and later. Their presence is
    // the structural signature of the broken split, and catches the case where
    // the version assertion above is satisfied by a `dependency_overrides`
    // entry while a transitive dependant still drags the split packages in.
    const federated = [
      'android_file_picker',
      'file_picker_darwin',
      'file_picker_linux',
      'file_picker_platform_interface',
      'file_picker_web',
      'windows_file_picker',
    ];

    final found = federated
        .where((name) => lock.contains('\n  $name:\n'))
        .toList();

    expect(
      found,
      isEmpty,
      reason:
          'Resolved federated file_picker packages: ${found.join(', ')}. These '
          'ship only with file_picker 12.0.0+, whose macOS implementation does '
          'not work. $pinnedVersion is monolithic and pulls in none of them.',
    );
  });
}
