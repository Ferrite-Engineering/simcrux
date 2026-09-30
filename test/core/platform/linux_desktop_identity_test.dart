// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

@TestOn('vm')
library;

import 'dart:io';

import 'package:crux_linux_integration/crux_linux_integration.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/platform/linux_desktop_identity.dart';

String _cmakeSet(String name) {
  final cmake = File('linux/CMakeLists.txt').readAsStringSync();
  final match = RegExp('set\\($name "([^"]+)"\\)').firstMatch(cmake);
  if (match == null) fail('linux/CMakeLists.txt sets no $name');
  return match.group(1)!;
}

/// Every extension `macos/Runner/Info.plist` registers a document type for.
Set<String> _macosExtensions() {
  final plist = File('macos/Runner/Info.plist').readAsStringSync();
  return <String>{
    for (final block in RegExp(
      '<key>CFBundleTypeExtensions</key>'
      r'\s*<array>(.*?)</array>',
      dotAll: true,
    ).allMatches(plist))
      ...RegExp(
        '<string>([^<]+)</string>',
      ).allMatches(block.group(1)!).map((m) => m.group(1)!),
  };
}

void main() {
  test('the open-core identity matches the Linux runner it launches', () {
    // The open-core build used to install the Pro identity, so an open-core
    // AppImage wrote a `SimCrux Pro` desktop entry whose Exec and app id
    // matched no binary or window of its own.
    expect(kSimcruxLinuxDesktopApp.appId, _cmakeSet('APPLICATION_ID'));
    expect(kSimcruxLinuxDesktopApp.execName, _cmakeSet('BINARY_NAME'));
    expect(kSimcruxLinuxDesktopApp.name, isNot(contains('Pro')));
  });

  test('every extension macOS registers is mapped on Linux too', () {
    // The two platforms' lists describe the same files. A double-click that
    // works on a Mac and does nothing on Linux is the defect this pairing
    // exists to stop, and it is invisible unless the two are compared. The
    // rules themselves live in crux_linux_integration, so all four products
    // are held to one definition of "mapped" rather than each writing its
    // own.
    final coverage = checkLinuxMimeCoverage(
      kSimcruxLinuxDesktopApp,
      registeredExtensions: _macosExtensions(),
      registeredExtensionsOf: kSimcruxLinuxYamlExtensions,
    );
    expect(coverage.problems, isEmpty, reason: '$coverage');
    expect(
      coverage.deliberatelyUnmapped,
      isEmpty,
      reason:
          'SimCrux claims all five of its extensions on Linux; a gap here '
          'means one was written off without this guard being told why',
    );
  });

  test('the rendered entry carries the types, semicolon-terminated', () {
    final entry = buildDesktopEntry(
      kSimcruxLinuxDesktopApp,
      appImagePath: '/home/eng/Apps/SimCrux-0.9.0-x86_64.AppImage',
    );
    final line = entry
        .split('\n')
        .firstWhere((l) => l.startsWith('MimeType='), orElse: () => '');
    expect(
      line,
      isNotEmpty,
      reason: 'no MimeType line: the file manager offers the app for nothing',
    );
    for (final type in kSimcruxLinuxDesktopApp.claimedTypeNames) {
      expect(line, contains('$type;'));
    }
  });

  test('the installed package declares our types and only ours', () {
    // The half the entry cannot supply. Without a glob for
    // `*.simcrux-workspace` the file is typed as JSON, and the entry naming
    // the type changes nothing — the application is never offered.
    final xml = buildMimePackage(kSimcruxLinuxDesktopApp);
    expect(xml, isNotNull, reason: 'no package: our own types map nothing');
    for (final type in const <String>[
      'application/x-edacrux-project',
      'application/x-simcrux-session',
      'application/x-simcrux-workspace',
    ]) {
      expect(xml, contains('<mime-type type="$type">'));
    }
    expect(xml, contains('<glob pattern="*.crux-project"/>'));
    expect(xml, contains('<comment>EDACrux design manifest</comment>'));

    // The YAML types are named in the entry and never declared: our
    // `<comment>` would become the "Kind" text of every YAML file on the
    // machine, SimCrux's or not.
    // Matched on the declaration itself, not the bare name: `x-yaml` is
    // also the manifest's parent, which is exactly where it belongs.
    expect(xml, isNot(contains('<mime-type type="application/x-yaml">')));
    expect(xml, isNot(contains('<mime-type type="application/yaml">')));
    expect(xml, isNot(contains('*.yaml')));
    expect(xml, isNot(contains('*.yml')));

    // A desktop that has never heard of our types still treats the files as
    // what they are made of, which is what makes declaring them safe.
    expect(xml, contains('<sub-class-of type="application/x-yaml"/>'));
    expect(xml, contains('<sub-class-of type="application/json"/>'));
  });

  test('bootstrap installs the identity it is given', () {
    // bootstrap cannot run in a unit test (it calls runApp and reads the
    // platform), so this reads the source, as the other entry-point guards do.
    final app = File('lib/app.dart').readAsStringSync();
    expect(
      app,
      contains('linuxDesktopApp ?? kSimcruxLinuxDesktopApp'),
      reason:
          'the identity is resolved at the call site now that it cannot be a '
          'default parameter value',
    );
    expect(app, isNot(contains("appId: 'com.ferriteengineering.simcrux_pro'")));
    expect(app, contains('linuxDesktopApp: linuxDesktopApp'));
  });
}
