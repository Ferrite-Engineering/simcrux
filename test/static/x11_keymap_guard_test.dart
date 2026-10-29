// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Static guard for linux/runner/x11_keymap_guard.cc, which keeps a key press
// on an untrusted X display (`ssh -X`) from crashing the app. Nothing calls
// it: it works by defining gdk_keymap_lookup_key in the executable, so a
// runner that stops compiling it, or a rename that changes the definition,
// loses the guard with no build error. This holds the wiring on every
// platform; .github/workflows/linux-untrusted-keys.yml proves it works.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// A CMake file with its `#` comments removed, so a mention in a comment does
// not count as wiring.
String _cmakeCode(String path) => File(path)
    .readAsStringSync()
    .split('\n')
    .map((line) {
      final comment = line.indexOf('#');
      return comment < 0 ? line : line.substring(0, comment);
    })
    .join('\n');

void main() {
  test(
    'the Linux runner compiles the keymap guard and links what it needs',
    () {
      final cmake = _cmakeCode('linux/runner/CMakeLists.txt');
      expect(cmake, contains('"x11_keymap_guard.cc"'));
      expect(cmake, contains(r'${CMAKE_DL_LIBS}'));
      expect(cmake, contains('PkgConfig::X11'));
    },
  );

  test('the guard defines gdk_keymap_lookup_key and forwards to GDK', () {
    final source = File('linux/runner/x11_keymap_guard.cc').readAsStringSync();
    // At file scope, so it has GDK's C linkage and is exported.
    expect(
      source,
      contains(
        '\nguint gdk_keymap_lookup_key(GdkKeymap* keymap, '
        'const GdkKeymapKey* key) {',
      ),
    );
    expect(source, contains('dlsym(RTLD_NEXT, "gdk_keymap_lookup_key")'));
    expect(source, contains('XDisplayKeycodes('));
  });
}
