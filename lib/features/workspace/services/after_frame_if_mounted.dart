// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Runs [action] once the current frame is done, and only if [context] is
/// still mounted by then.
///
/// For a `ref.listen` callback in a tab's widget that reads providers through
/// the widget's `ref`, when the provider it listens to is not one of the tab's
/// own. Such a provider (`runDeltaProvider`, `licenseTierProvider`) lives in
/// the root container, so the widget's subscription to it is held by the root
/// and outlives the tab's container: closing a tab disposes the container at
/// once, while the tab's widgets leave the tree only on the next frame, and a
/// listener notified in between reads through a disposed container and throws.
/// By the time this frame's post-frame callbacks run, a closed tab's widgets
/// are gone and `context.mounted` is false, so the action is dropped.
///
/// A listener on a provider that lives in the tab's own container needs
/// neither: disposing the container ends the subscription.
void runAfterFrameIfMounted(BuildContext context, VoidCallback action) {
  SchedulerBinding.instance
    ..addPostFrameCallback((_) {
      if (context.mounted) action();
    })
    // A listener notified between frames would otherwise wait for the next
    // frame something else asks for.
    ..ensureVisualUpdate();
}
