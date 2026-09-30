// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Signature for a PR-annotation action opener.
typedef PrAnnotationOpener = void Function(BuildContext context);

/// Opens the PR-annotation target configuration surface
/// (`SimcruxAction.configurePrAnnotationTarget`).
///
/// **Open-core default `null`** — no target UI exists without the Pro
/// overlay, and the action handler surfaces the Pro-gated snack. The Pro
/// overlay mounts its Settings → PR Annotation section in a dialog.
final Provider<PrAnnotationOpener?> prAnnotationSettingsOpenerProvider =
    Provider<PrAnnotationOpener?>((ref) => null);

/// Dispatches the active run's annotations to the configured target
/// (`SimcruxAction.dispatchPrAnnotations`).
///
/// **Open-core default `null`** — open core registers only
/// `NoopPrAnnotationDispatcher`, so there is nowhere to post. The Pro
/// overlay's opener builds the batch from the active run, posts it, and
/// reports the outcome.
final Provider<PrAnnotationOpener?> prAnnotationDispatchOpenerProvider =
    Provider<PrAnnotationOpener?>((ref) => null);
