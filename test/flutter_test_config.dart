// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:crux_workspace/crux_workspace.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tree-wide test harness configuration (auto-discovered by `flutter test`
/// for every test under `test/`).
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  // The welcome screen's CruxGlowingAppIcon runs perpetual
  // AnimationController.repeat loops; without this, any test that renders
  // the empty-canvas route can never pumpAndSettle.
  CruxGlowingAppIcon.debugDisableAnimations = true;

  // [ModalGuard] is process-global re-entrancy state for exclusive modal
  // surfaces. A widget test that pumps a guarded dialog/drawer open and
  // tears down without dismissing it leaves its key set, which would
  // suppress the next test's open. Reset before every test for isolation.
  setUp(ModalGuard.reset);

  await testMain();
}
