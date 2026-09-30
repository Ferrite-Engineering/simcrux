// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/core/shortcuts/shortcut_bindings_provider.dart';
import 'package:simcrux/core/shortcuts/shortcut_conflicts.dart';
import 'package:simcrux/core/shortcuts/simcrux_action.dart';

/// A [ShortcutManager] that passes all key events through when a
/// text-input widget ([EditableText]) currently holds focus.
///
/// Without this guard, single-character shortcuts would swallow
/// keystrokes inside dialogs or inline text fields. Mirrors the
/// WaveCrux / NetCrux pattern.
class _TextAwareShortcutManager extends ShortcutManager {
  _TextAwareShortcutManager({required super.shortcuts});

  @override
  KeyEventResult handleKeypress(BuildContext context, KeyEvent event) {
    if (_isTextInputFocused() && _isBareLetter()) {
      return KeyEventResult.ignored;
    }
    if (_activatesFocusedControl(event)) return KeyEventResult.ignored;
    return super.handleKeypress(context, event);
  }

  /// True for a bare Space or Enter while the focused widget is a control
  /// that Space and Enter activate — a button, a check box, a tile.
  ///
  /// This manager sits above the framework's own `Space → ActivateIntent`
  /// shortcut, and every SimCrux shortcut handler is always enabled, so a
  /// user who binds a bare Space or Enter to an action would otherwise lose
  /// both keys on every focused button: keyboard and screen-reader users
  /// activate controls with exactly those keys. Controls that accept
  /// activation own them; everywhere else the binding still fires.
  static bool _activatesFocusedControl(KeyEvent event) {
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.space &&
        key != LogicalKeyboardKey.enter &&
        key != LogicalKeyboardKey.numpadEnter) {
      return false;
    }
    if (!_isBareLetter() || HardwareKeyboard.instance.isShiftPressed) {
      return false;
    }
    final focusContext = FocusManager.instance.primaryFocus?.context;
    if (focusContext == null) return false;
    final action = Actions.maybeFind<ActivateIntent>(focusContext);
    return action != null && action.isEnabled(const ActivateIntent());
  }

  /// True when the current event has no Ctrl / Cmd / Alt modifier.
  /// Shift alone is not counted — bare Shift+key combos should still
  /// be blocked inside text fields.
  static bool _isBareLetter() =>
      !HardwareKeyboard.instance.isControlPressed &&
      !HardwareKeyboard.instance.isMetaPressed &&
      !HardwareKeyboard.instance.isAltPressed;

  /// True when a text-input widget is anywhere in the focus ancestry.
  ///
  /// `EditableText` attaches its `FocusNode` to an inner `Focus`
  /// child, so `primaryFocus.context.widget` is never `EditableText`
  /// itself; walking up the ancestor elements finds it reliably.
  static bool _isTextInputFocused() {
    final focusContext = FocusManager.instance.primaryFocus?.context;
    if (focusContext == null) return false;
    if (focusContext.widget is EditableText) return true;
    var found = false;
    focusContext.visitAncestorElements((element) {
      if (element.widget is EditableText) {
        found = true;
        return false;
      }
      return true;
    });
    return found;
  }
}

/// Wraps [child] with Flutter's [Shortcuts] and [Actions] machinery,
/// using bindings from [shortcutBindingsProvider].
///
/// Pass [handlers] for globally-scoped actions (e.g. opening the
/// command palette). Context-sensitive actions (zoom, pan,
/// navigation) should register their own [Actions] widget lower in
/// the tree — unhandled intents propagate up to the global handler.
class ShortcutManagerWidget extends ConsumerWidget {
  /// Creates a shortcut-manager scope rooted at [child].
  const ShortcutManagerWidget({
    required this.child,
    this.handlers = const <SimcruxAction, VoidCallback>{},
    super.key,
  });

  /// The subtree that should resolve shortcut activators through these
  /// bindings.
  final Widget child;

  /// Callbacks invoked when a matched shortcut fires. Actions not
  /// present here propagate to [Actions] widgets registered below.
  final Map<SimcruxAction, VoidCallback> handlers;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bindings = ref.watch(shortcutBindingsProvider);
    // Resolve collisions deterministically: when two actions share a chord, the
    // user's customized binding wins over the action that holds it by default
    // (shadowed losers are dropped), so a fresh remap actually fires. Previously
    // the map literal let whichever action came later in `bindings` iteration
    // order (SimcruxAction enum declaration order) silently win.
    final effective = resolveShortcutConflicts(bindings).effectiveBindings;
    return Shortcuts.manager(
      manager: _TextAwareShortcutManager(
        shortcuts: <ShortcutActivator, Intent>{
          for (final e in effective.entries)
            e.value: SimcruxActionIntent(e.key),
        },
      ),
      child: Actions(
        actions: <Type, Action<Intent>>{
          SimcruxActionIntent: CallbackAction<SimcruxActionIntent>(
            onInvoke: (intent) {
              handlers[intent.action]?.call();
              return null;
            },
          ),
        },
        child: child,
      ),
    );
  }
}
