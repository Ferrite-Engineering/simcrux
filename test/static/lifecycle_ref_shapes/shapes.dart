// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Synthetic shapes exercising the detection rules in
// `../lifecycle_ref_use_test.dart`.
//
// The POSITIVE shapes each reproduce a way `Ref` reaches into a
// lifecycle callback; the scanner must flag every one. The NEGATIVE
// shapes are the control — legitimate patterns that must stay clean, so
// a scanner that passes by flagging everything fails here.
//
// This file is deliberately outside `lib/`, so the production scan
// never sees it; the shape test resolves it on its own. It is never
// executed — only read as text — so the shapes need not be runnable
// providers.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

final registryProvider = Provider<_Registry>((ref) => _Registry());

class _Registry {
  void unregister(Object token) {}
}

// === POSITIVE: must be flagged =============================================

// --- Shape 1: direct `ref.read` in the callback body. -----------------------
// The statements below the read never run.

class DirectShape extends Notifier<int> {
  StreamSubscription<void>? _subscription;
  final Object _token = Object();

  @override
  int build() {
    ref.onDispose(() async {
      ref.read(registryProvider).unregister(_token);
      await _subscription?.cancel();
    });
    return 0;
  }
}

// --- Shape 2: the callback calls a helper that reads `ref`. ------------------
// The motivating bug. A scanner that only matches literal `ref.` inside
// the callback body misses this entirely.

class HelperShape extends Notifier<int> {
  StreamSubscription<void>? _subscription;
  final Object _token = Object();

  @override
  int build() {
    ref.onDispose(() async {
      _releaseActiveRunToken();
      await _subscription?.cancel();
    });
    return 0;
  }

  void _releaseActiveRunToken() {
    final token = _token;
    ref.read(registryProvider).unregister(token);
  }
}

// --- Shape 2b: the helper chain is two levels deep. -------------------------

class TransitiveHelperShape extends Notifier<int> {
  @override
  int build() {
    ref.onDispose(_outer);
    return 0;
  }

  void _outer() => _inner();

  void _inner() => ref.read(registryProvider).unregister(this);
}

// --- Shape 3: a closure capturing `ref`, stored and registered later. -------

class TearOffShape extends Notifier<int> {
  @override
  int build() {
    ref.onDispose(_teardown);
    return 0;
  }

  void _teardown() {
    ref.invalidate(registryProvider);
  }
}

// --- Shape 4: the same hazard in the non-dispose lifecycle hooks. -----------
// `onCancel` / `onResume` / the listener hooks run while the provider is
// still alive, but trip the identical callback-stack assertion.

class OnCancelShape extends Notifier<int> {
  @override
  int build() {
    ref.onCancel(() => ref.read(registryProvider));
    return 0;
  }
}

class OnResumeShape extends Notifier<int> {
  @override
  int build() {
    ref.onResume(() => ref.read(registryProvider));
    return 0;
  }
}

class OnAddListenerShape extends Notifier<int> {
  @override
  int build() {
    ref.onAddListener(() => ref.read(registryProvider));
    return 0;
  }
}

class OnRemoveListenerShape extends Notifier<int> {
  @override
  int build() {
    ref.onRemoveListener(() => ref.read(registryProvider));
    return 0;
  }
}

// --- Shape 5: `ref` reached after an `await` inside an async callback. ------
// The callback stack has unwound, so the debug assertion does not fire —
// this one fails in RELEASE builds too, with "Cannot use the Ref ...
// after it has been disposed".

class AsyncGapShape extends Notifier<int> {
  @override
  int build() {
    ref.onDispose(() async {
      await Future<void>.delayed(Duration.zero);
      ref.read(registryProvider).unregister(this);
    });
    return 0;
  }
}

// === NEGATIVE: must stay clean =============================================

// --- Control 1: the service is captured EAGERLY, before the hook. -----------
// This is the prescribed fix. It must not be flagged.

class EagerCaptureControl extends Notifier<int> {
  StreamSubscription<void>? _subscription;
  final Object _token = Object();
  _Registry? _registry;

  @override
  int build() {
    _registry = ref.read(registryProvider);
    ref.onDispose(() async {
      _releaseActiveRunToken();
      await _subscription?.cancel();
    });
    return 0;
  }

  void _releaseActiveRunToken() {
    final token = _token;
    _registry?.unregister(token);
  }
}

// --- Control 2: a tear-off of a method that never touches `ref`. ------------

class PlainTearOffControl extends Notifier<int> {
  StreamSubscription<void>? _subscription;

  @override
  int build() {
    ref.onDispose(_teardown);
    return 0;
  }

  Future<void> _teardown() async {
    await _subscription?.cancel();
  }
}

// --- Control 3: `ref` used in a callback that RUNS while alive. -------------
// A stream listener attached during build fires outside the callback
// stack, so reading `ref` from it is legitimate.

class LiveCallbackControl extends Notifier<int> {
  @override
  int build() {
    final controller = StreamController<void>();
    final sub = controller.stream.listen((_) {
      ref.read(registryProvider);
    });
    ref.onDispose(sub.cancel);
    return 0;
  }
}

// --- Control 4: a helper that touches `ref` only OUTSIDE the hook it --------
// registers. Calling it from build() is fine; the hook it installs is
// itself clean.

class HookRegisteringHelperControl extends Notifier<int> {
  @override
  int build() {
    _attach();
    return 0;
  }

  void _attach() {
    final registry = ref.read(registryProvider);
    ref.onDispose(() => registry.unregister(this));
  }
}

// --- Control 5: `onDispose` on a foreign receiver, not a `Ref`. -------------

class FakeController {
  void onDispose(void Function() cb) {}
}

class ForeignReceiverControl {
  final FakeController controller = FakeController();
  final Object ref = Object();

  void attach() {
    controller.onDispose(ref.toString);
  }
}
