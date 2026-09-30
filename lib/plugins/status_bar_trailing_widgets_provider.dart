// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Open-core extension point: widgets injected into the trailing (right) end
/// of `RegressionStatusBar`, after the busy indicator.
///
/// Open-core returns an empty list, so the status bar renders unchanged. The
/// closed-source Pro overlay overrides this binding to inject its
/// own chrome without forking the open-core widget — the seam WaveCrux has
/// carried since its collaborative-session status chip shipped, generalized to
/// the rest of the suite so a Pro overlay has somewhere to put a status chip
/// in every product rather than only one.
///
/// Injected widgets are responsible for rendering nothing
/// (`SizedBox.shrink()`) when they have nothing to show, so the slot adds no
/// visual weight when idle.
final statusBarTrailingWidgetsProvider = Provider<List<Widget>>(
  (_) => const <Widget>[],
);
