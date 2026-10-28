// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the Linux runner's software-renderer fallback (#36).
///
/// Flutter's GTK embedder presents frames through a GDK OpenGL context. On a
/// display that cannot create one (VNC, X forwarding without GLX, a virtual
/// machine without 3D acceleration) it logs "Failed to create OpenGL context"
/// and draws nothing, so the window never appears. The runner asks the
/// display for a context on a throwaway window first and, when that fails,
/// selects the software renderer. The software renderer draws through Skia,
/// so Impeller has to be off as well, or the engine aborts at the first line
/// of text.
///
/// The engine reads both settings when `fl_view_new` creates it, so the order
/// inside `my_application_activate` is load-bearing, and a regenerated
/// runner (`flutter create`) loses all of it. CI's launch smoke
/// (`tool/linux_smoke/launch_smoke.sh`) proves the behaviour on Xvfb; this
/// guard names the line that went missing.
void main() {
  const path = 'linux/runner/my_application.cc';
  late String source;
  late String activate;

  setUpAll(() {
    final file = File(path);
    expect(file.existsSync(), isTrue, reason: '$path is missing');
    source = file.readAsStringSync();
    final start = source.indexOf('static void my_application_activate(');
    expect(start, isNonNegative, reason: 'no my_application_activate');
    activate = source.substring(start, source.indexOf('\n}\n', start));
  });

  test('the runner probes the display for an OpenGL context', () {
    expect(source, contains('gdk_window_create_gl_context'));
    expect(source, contains('gdk_gl_context_realize'));
  });

  test('a renderer the user chose is left alone', () {
    expect(
      source,
      contains('if (g_getenv("FLUTTER_LINUX_RENDERER") != nullptr) {'),
    );
    expect(
      source,
      contains('g_setenv("FLUTTER_LINUX_RENDERER", "software", FALSE)'),
    );
  });

  test('the fallback says so on stderr', () {
    expect(source, contains('falling back to'));
    expect(source, contains('the software renderer'));
  });

  test('probe and Impeller switch both run before the engine is made', () {
    final probe = activate.indexOf('select_renderer_for_display();');
    final impeller = activate.indexOf(
      'fl_dart_project_set_enable_impeller(project, FALSE)',
    );
    final view = activate.indexOf('fl_view_new(');
    expect(probe, isNonNegative, reason: 'activate does not call the probe');
    expect(
      impeller,
      isNonNegative,
      reason: 'Impeller must be off under the software renderer',
    );
    expect(view, isNonNegative);
    expect(probe, lessThan(view));
    expect(impeller, lessThan(view));
  });

  test('CI launches the release bundle with and without GLX', () {
    final ci = File('.github/workflows/ci.yml').readAsStringSync();
    expect(
      ci,
      contains(
        './tool/linux_smoke/launch_smoke.sh build/linux/x64/release/bundle',
      ),
    );
    expect(File('tool/linux_smoke/xwd_frame.py').existsSync(), isTrue);
  });
}
