// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// The rehearsal entry point: SimCrux with the rehearsal service extension
// registered, for replaying a recording script against a debug build.
//
//   flutter build linux --debug -t rehearsal/main.dart
//   flutter build macos --debug -t rehearsal/main.dart
//
// It lives outside lib/ on purpose. Every release build compiles
// lib/main.dart, and nothing in lib/ may import this directory;
// test/static/rehearsal_entry_guard_test.dart enforces both.

import 'package:simcrux/main.dart' as app;

import 'crux_rehearsal.dart';

Future<void> main(List<String> args) {
  registerCruxRehearsal();
  return app.main(args);
}
