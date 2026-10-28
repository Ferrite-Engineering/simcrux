// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// The live end of the video rehearsal driver.
//
// A rehearsal replays a recording script against a real build, one step at a
// time, before anyone sits down to record it: press this chord, type this
// text, click the control this label names, take a screenshot. The steps
// arrive over the Dart VM service as calls to the `ext.crux.rehearsal`
// service extension, which only a debug or profile build exposes, and only
// when the app was started from `rehearsal/main.dart`.
//
// Everything here acts inside the app: pointer events go to the app's own
// gesture binding and key events to its own focus tree, never to the
// operating system. Nothing here can type into another window.
//
// This file is kept identical in the four desktop products; the rehearsal CI
// compares the copies, so change all four together.

import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The service extension the rehearsal driver calls.
const String kRehearsalExtension = 'ext.crux.rehearsal';

/// Registers [kRehearsalExtension]. Call it first in a rehearsal entry
/// point, before the app's own `main` runs.
///
/// Throws in a release build: a release build has no VM service, so the
/// extension could never be reached, and a release build that calls this
/// was built from the wrong entry point.
void registerCruxRehearsal() {
  if (kReleaseMode) {
    throw StateError(
      'The rehearsal entry point was compiled into a release build. '
      'Release builds use lib/main.dart; rehearsal/main.dart is for debug '
      'builds only.',
    );
  }
  CruxRehearsal? rehearsal;
  developer.registerExtension(kRehearsalExtension, (method, params) async {
    // The extension is registered before the app's own main runs, so a
    // driver can reach it while the app is still starting. Until the first
    // frame is on screen there is nothing to drive; say so, and the driver
    // asks again.
    final waiting = rehearsalNotReady();
    if (waiting != null) {
      return developer.ServiceExtensionResponse.result(
        jsonEncode({'ok': false, 'ready': false, 'detail': waiting}),
      );
    }
    rehearsal ??= CruxRehearsal(LiveWidgetController(WidgetsBinding.instance));
    Map<String, Object?> request;
    try {
      request = (jsonDecode(params['request'] ?? '{}') as Map)
          .cast<String, Object?>();
    } on FormatException catch (error) {
      return developer.ServiceExtensionResponse.error(
        developer.ServiceExtensionResponse.invalidParams,
        'request is not JSON: $error',
      );
    }
    final response = await rehearsal!.handle(request);
    return developer.ServiceExtensionResponse.result(jsonEncode(response));
  });
}

/// Why the app cannot be driven yet, or null once its first frame has been
/// drawn.
String? rehearsalNotReady() {
  final WidgetsBinding binding;
  try {
    binding = WidgetsBinding.instance;
  } on Object {
    return 'the app has not initialized its bindings yet';
  }
  return binding.firstFrameRasterized
      ? null
      : 'the app has not drawn its first frame yet';
}

/// One rehearsal session against a widget tree.
///
/// [controller] is a [LiveWidgetController] in a running app and the
/// [WidgetTester] in this file's tests, so the same code path is tested.
class CruxRehearsal {
  /// Creates a session that drives [controller].
  CruxRehearsal(
    this.controller, {
    this.findTimeout = const Duration(seconds: 5),
  });

  /// The tree being driven.
  final WidgetController controller;

  /// How long a step waits for the control it names to appear.
  final Duration findTimeout;

  static const int _scrollPointer = 7001;

  /// Answers one request. Never throws: a failure is `ok: false` with the
  /// reason, so the driver can report the step and stop the scene.
  Future<Map<String, Object?>> handle(Map<String, Object?> request) async {
    try {
      switch (request['op']) {
        case 'ping':
          return {
            'ok': true,
            'ready': true,
            'platform': defaultTargetPlatform.name,
            'debug': kDebugMode,
          };
        case 'prepare':
          await settle();
          return {'ok': true, 'detail': 'settled'};
        case 'perform':
          final step = (request['step']! as Map).cast<String, Object?>();
          final result = await perform(step);
          await settle();
          return result;
        case 'screenshot':
          return await screenshot();
        default:
          return {'ok': false, 'detail': 'unknown op ${request['op']}'};
      }
    } on Object catch (error) {
      return {'ok': false, 'detail': '$error'};
    }
  }

  /// Performs one step. `ok` is true when the step did what it says, false
  /// when the build diverged from the script, and null when the step is not
  /// one a driver can perform (the person recording does it).
  Future<Map<String, Object?>> perform(Map<String, Object?> step) async {
    final kind = step['kind'];
    switch (kind) {
      case 'press':
        return await _press(step);
      case 'type':
        return _type(step['text']! as String);
      case 'clear':
        return _clear();
      case 'click':
      case 'choose':
      case 'right_click':
        return await _click(step, secondary: kind == 'right_click');
      case 'hold':
        final finder = await _waitFor(step);
        return finder == null
            ? _missing(step)
            : {'ok': true, 'detail': 'showing "${step['label']}"'};
      case 'scroll':
        return await _scroll(up: step['direction'] == 'up');
      default:
        return {'ok': null, 'detail': 'not a step a driver performs: $kind'};
    }
  }

  // -------------------------------------------------------------------------
  // Finding a control by what the script calls it
  // -------------------------------------------------------------------------

  /// The control a step names, by its label (visible text, tooltip or
  /// semantics label, matched the way the static check matches ARB strings)
  /// or by a key: the label itself, or any ARB key whose English string is
  /// the label (`keys`). Only hit-testable matches count: a label behind a
  /// modal barrier or scrolled out of view is not one the take can click.
  Finder? findControl(Map<String, Object?> step) {
    final label = step['label'] as String?;
    final keys = [
      ?label,
      ...((step['keys'] as List?) ?? const []).cast<String>(),
    ];
    final wanted = label == null ? null : normalizeLabel(label);
    bool matches(String? text) =>
        wanted != null && text != null && normalizeLabel(text) == wanted;
    final candidates = <Finder>[
      if (wanted != null) ...[
        find.byWidgetPredicate(
          (w) => w is Text && matches(w.data ?? w.textSpan?.toPlainText()),
        ),
        find.byWidgetPredicate(
          (w) => w is RichText && matches(w.text.toPlainText()),
        ),
        find.byWidgetPredicate(
          (w) =>
              w is Tooltip &&
              matches(w.message ?? w.richMessage?.toPlainText()),
        ),
        find.byWidgetPredicate(
          (w) => w is Semantics && matches(w.properties.label),
        ),
      ],
      for (final key in keys) find.byKey(ValueKey<String>(key)),
    ];
    for (final candidate in candidates) {
      final hit = candidate.hitTestable();
      if (hit.evaluate().isNotEmpty) {
        return hit.first;
      }
    }
    return null;
  }

  Future<Finder?> _waitFor(Map<String, Object?> step) async {
    const poll = Duration(milliseconds: 100);
    final polls = findTimeout.inMilliseconds ~/ poll.inMilliseconds;
    for (var i = 0; ; i++) {
      final finder = findControl(step);
      if (finder != null || i >= polls) {
        return finder;
      }
      await controller.pump(poll);
    }
  }

  Map<String, Object?> _missing(Map<String, Object?> step) => {
    'ok': false,
    'detail': 'nothing on screen reads "${step['label']}"',
  };

  // -------------------------------------------------------------------------
  // Pointer steps
  // -------------------------------------------------------------------------

  Future<Map<String, Object?>> _click(
    Map<String, Object?> step, {
    required bool secondary,
  }) async {
    final finder = await _waitFor(step);
    if (finder == null) {
      return _missing(step);
    }
    final disabled = _disabledReason(finder);
    if (disabled != null) {
      return {'ok': false, 'detail': '"${step['label']}" is $disabled'};
    }
    await controller.tap(
      finder,
      kind: PointerDeviceKind.mouse,
      buttons: secondary ? kSecondaryMouseButton : kPrimaryButton,
    );
    return {'ok': true, 'detail': 'clicked "${step['label']}"'};
  }

  /// Why the control under [finder] would ignore a click, or null.
  String? _disabledReason(Finder finder) {
    String? reason;
    finder.evaluate().first.visitAncestorElements((element) {
      final widget = element.widget;
      if (widget is ButtonStyleButton) {
        reason = widget.enabled ? null : 'disabled';
        return false;
      }
      if (widget is IconButton) {
        reason = widget.onPressed == null ? 'disabled' : null;
        return false;
      }
      if (widget is ListTile) {
        reason = widget.enabled ? null : 'disabled';
        return false;
      }
      return true;
    });
    return reason;
  }

  Future<Map<String, Object?>> _scroll({required bool up}) async {
    final scrollables = find.byType(Scrollable).hitTestable();
    if (scrollables.evaluate().isEmpty) {
      return {'ok': false, 'detail': 'nothing on screen scrolls'};
    }
    // The largest visible scrollable is the one the take means by "scroll".
    Element? largest;
    var largestArea = 0.0;
    for (final element in scrollables.evaluate()) {
      final box = element.renderObject;
      if (box is RenderBox && box.hasSize) {
        final area = box.size.width * box.size.height;
        if (area > largestArea) {
          largest = element;
          largestArea = area;
        }
      }
    }
    final box = largest!.renderObject! as RenderBox;
    final centre = box.localToGlobal(box.size.center(Offset.zero));
    // A device of its own: the mouse a click used stays added (it keeps
    // hovering), and adding a device twice is an error.
    final pointer = TestPointer(
      _scrollPointer,
      PointerDeviceKind.mouse,
      _scrollPointer,
    );
    await controller.sendEventToBinding(pointer.addPointer(location: centre));
    await controller.sendEventToBinding(pointer.hover(centre));
    await controller.sendEventToBinding(
      pointer.scroll(Offset(0, up ? -240 : 240)),
    );
    await controller.sendEventToBinding(pointer.removePointer());
    return {'ok': true, 'detail': up ? 'scrolled up' : 'scrolled down'};
  }

  // -------------------------------------------------------------------------
  // Keyboard steps
  // -------------------------------------------------------------------------

  Future<Map<String, Object?>> _press(Map<String, Object?> step) async {
    final chords = ((step['chords'] as List?) ?? const [])
        .cast<Map<Object?, Object?>>();
    if (chords.isEmpty) {
      return {'ok': false, 'detail': 'no keys in "${step['text']}"'};
    }
    final repeat = (step['repeat'] as int?) ?? 1;
    final details = <String>[];
    for (var i = 0; i < repeat; i++) {
      for (final chord in chords) {
        final mods = ((chord['mods'] as List?) ?? const []).cast<String>();
        final name = chord['key']! as String;
        final key = logicalKeyFor(name);
        if (key == null) {
          return {'ok': false, 'detail': 'no key named "$name"'};
        }
        final handled = await sendChord(key, mods);
        if (!handled && _isShortcut(key, mods)) {
          // A shortcut nothing answered is a script step the build no
          // longer binds, or a binding behind a disabled surface.
          return {
            'ok': false,
            'detail': 'nothing answered ${_describe(name, mods)}',
          };
        }
        details.add(
          '${_describe(name, mods)}${handled ? '' : ' (not handled)'}',
        );
      }
      await settle();
    }
    return {'ok': true, 'detail': details.join(', ')};
  }

  static bool _isShortcut(LogicalKeyboardKey key, List<String> mods) =>
      mods.any((m) => m != 'shift') ||
      (key.keyId >= LogicalKeyboardKey.f1.keyId &&
          key.keyId <= LogicalKeyboardKey.f24.keyId);

  static String _describe(String name, List<String> mods) =>
      [...mods, name].join('+');

  /// Sends [key] with [mods] held, the way a keyboard would: modifiers
  /// down, the key down and up, modifiers up. Whether anything handled the
  /// key-down is the result.
  ///
  /// `primary` is the platform's command modifier: Meta on macOS, Control
  /// everywhere else, matching how the products bind their shortcuts.
  Future<bool> sendChord(LogicalKeyboardKey key, List<String> mods) async {
    final modifiers = <LogicalKeyboardKey>[
      for (final mod in mods) ?_modifierFor(mod),
    ];
    for (final modifier in modifiers) {
      _dispatch(_down(modifier));
    }
    var handled = _dispatch(_down(key, character: _characterFor(key, mods)));
    _dispatch(_up(key));
    for (final modifier in modifiers.reversed) {
      _dispatch(_up(modifier));
    }
    // Enter in a text field submits through the text input connection, not
    // through a key event; finish what the platform's input method would.
    if (!handled && key == LogicalKeyboardKey.enter && mods.isEmpty) {
      final field = _focusedField();
      if (field != null) {
        field.performAction(
          field.widget.textInputAction ??
              (field.widget.maxLines == 1
                  ? TextInputAction.done
                  : TextInputAction.newline),
        );
        handled = true;
      }
    }
    await controller.pump();
    return handled;
  }

  /// Delivers [event] the way the engine's key path does: to the keyboard
  /// state and its handlers, then to the focus tree.
  ///
  /// The focus tree is reached through the key event manager's message
  /// handler, which is deprecated for apps to set but is still how the
  /// framework's own FocusManager receives every key; there is no other
  /// public way to hand a key event to the focused widget's Shortcuts.
  bool _dispatch(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance.handleKeyEvent(event);
    // The framework's FocusManager listens here; see the comment above.
    // ignore: deprecated_member_use
    final handler = ServicesBinding.instance.keyEventManager.keyMessageHandler;
    // The message type that handler takes; deprecated with it.
    // ignore: deprecated_member_use
    final focus = handler?.call(KeyMessage([event], null)) ?? false;
    return keyboard || focus;
  }

  KeyDownEvent _down(LogicalKeyboardKey key, {String? character}) =>
      KeyDownEvent(
        physicalKey: physicalKeyFor(key),
        logicalKey: key,
        character: character,
        timeStamp: Duration.zero,
      );

  KeyUpEvent _up(LogicalKeyboardKey key) => KeyUpEvent(
    physicalKey: physicalKeyFor(key),
    logicalKey: key,
    timeStamp: Duration.zero,
  );

  static LogicalKeyboardKey? _modifierFor(String mod) {
    final isMac =
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.iOS;
    return switch (mod) {
      'primary' =>
        isMac ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft,
      'meta' => LogicalKeyboardKey.metaLeft,
      'control' => LogicalKeyboardKey.controlLeft,
      'alt' => LogicalKeyboardKey.altLeft,
      'shift' => LogicalKeyboardKey.shiftLeft,
      _ => null,
    };
  }

  static String? _characterFor(LogicalKeyboardKey key, List<String> mods) {
    if (mods.any((m) => m != 'shift')) {
      return null;
    }
    if (key == LogicalKeyboardKey.enter) {
      return '\n';
    }
    final label = key.keyLabel;
    if (label.length != 1) {
      return null;
    }
    return mods.contains('shift') ? label.toUpperCase() : label.toLowerCase();
  }

  /// The key a script names: a letter, a digit, a punctuation mark, `F1`
  /// to `F24`, or a word (`Esc`, `Enter`, `Tab`, `Space`, `Delete`).
  static LogicalKeyboardKey? logicalKeyFor(String name) {
    final word = switch (name.toLowerCase()) {
      'esc' || 'escape' => LogicalKeyboardKey.escape,
      'enter' || 'return' => LogicalKeyboardKey.enter,
      'tab' => LogicalKeyboardKey.tab,
      'space' => LogicalKeyboardKey.space,
      'delete' || 'backspace' => LogicalKeyboardKey.backspace,
      'up' => LogicalKeyboardKey.arrowUp,
      'down' => LogicalKeyboardKey.arrowDown,
      'left' => LogicalKeyboardKey.arrowLeft,
      'right' => LogicalKeyboardKey.arrowRight,
      _ => null,
    };
    if (word != null) {
      return word;
    }
    final function = RegExp(r'^[Ff](\d{1,2})$').firstMatch(name);
    if (function != null) {
      final n = int.parse(function.group(1)!);
      return n >= 1 && n <= 24
          ? LogicalKeyboardKey(LogicalKeyboardKey.f1.keyId + n - 1)
          : null;
    }
    if (name.length == 1) {
      // Letters, digits and ASCII punctuation are their own lower-case code
      // point, which is how the logical key ids are defined.
      final code = name.toLowerCase().codeUnitAt(0);
      if (code > 0x20 && code < 0x7f) {
        return LogicalKeyboardKey(code);
      }
    }
    return null;
  }

  static const Map<int, int> _usbPunctuation = {
    0x2d: 0x0007002d, // -
    0x3d: 0x0007002e, // =
    0x5b: 0x0007002f, // [
    0x5d: 0x00070030, // ]
    0x5c: 0x00070031, // backslash
    0x3b: 0x00070033, // ;
    0x27: 0x00070034, // '
    0x60: 0x00070035, // `
    0x2c: 0x00070036, // ,
    0x2e: 0x00070037, // .
    0x2f: 0x00070038, // /
  };

  /// The US-layout physical key for [key]. Shortcut matching reads the
  /// logical key; the physical one only has to be stable and distinct so the
  /// keyboard state stays consistent between a key's down and up.
  static PhysicalKeyboardKey physicalKeyFor(LogicalKeyboardKey key) {
    final known = <LogicalKeyboardKey, PhysicalKeyboardKey>{
      LogicalKeyboardKey.escape: PhysicalKeyboardKey.escape,
      LogicalKeyboardKey.enter: PhysicalKeyboardKey.enter,
      LogicalKeyboardKey.tab: PhysicalKeyboardKey.tab,
      LogicalKeyboardKey.space: PhysicalKeyboardKey.space,
      LogicalKeyboardKey.backspace: PhysicalKeyboardKey.backspace,
      LogicalKeyboardKey.arrowUp: PhysicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.arrowDown: PhysicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowLeft: PhysicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight: PhysicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.metaLeft: PhysicalKeyboardKey.metaLeft,
      LogicalKeyboardKey.controlLeft: PhysicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.altLeft: PhysicalKeyboardKey.altLeft,
      LogicalKeyboardKey.shiftLeft: PhysicalKeyboardKey.shiftLeft,
    }[key];
    if (known != null) {
      return known;
    }
    final id = key.keyId;
    if (id >= LogicalKeyboardKey.f1.keyId &&
        id <= LogicalKeyboardKey.f12.keyId) {
      return PhysicalKeyboardKey(0x0007003a + id - LogicalKeyboardKey.f1.keyId);
    }
    if (id >= 0x61 && id <= 0x7a) {
      return PhysicalKeyboardKey(0x00070004 + id - 0x61);
    }
    if (id >= 0x31 && id <= 0x39) {
      return PhysicalKeyboardKey(0x0007001e + id - 0x31);
    }
    if (id == 0x30) {
      return PhysicalKeyboardKey.digit0;
    }
    return PhysicalKeyboardKey(_usbPunctuation[id] ?? (0x00070100 + id));
  }

  // -------------------------------------------------------------------------
  // Text steps
  // -------------------------------------------------------------------------

  EditableTextState? _focusedField() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) {
      return null;
    }
    if (context is StatefulElement && context.state is EditableTextState) {
      return context.state as EditableTextState;
    }
    return context.findAncestorStateOfType<EditableTextState>();
  }

  Map<String, Object?> _type(String text) {
    final field = _focusedField();
    if (field == null) {
      return {'ok': false, 'detail': 'no text field has focus to type into'};
    }
    final value = field.textEditingValue;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final updated = value.text.replaceRange(
      selection.start,
      selection.end,
      text,
    );
    field.userUpdateTextEditingValue(
      TextEditingValue(
        text: updated,
        selection: TextSelection.collapsed(
          offset: selection.start + text.length,
        ),
      ),
      SelectionChangedCause.keyboard,
    );
    return {'ok': true, 'detail': 'typed "$text"'};
  }

  Map<String, Object?> _clear() {
    final field = _focusedField();
    if (field == null) {
      return {'ok': false, 'detail': 'no text field has focus to clear'};
    }
    field.userUpdateTextEditingValue(
      TextEditingValue.empty,
      SelectionChangedCause.keyboard,
    );
    return {'ok': true, 'detail': 'cleared the field'};
  }

  // -------------------------------------------------------------------------
  // Frames and screenshots
  // -------------------------------------------------------------------------

  /// Lets the frame after a step finish: pumps until nothing is scheduled,
  /// or two seconds pass (an ambient animation never stops scheduling).
  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await controller.pump(const Duration(milliseconds: 100));
      if (!controller.binding.hasScheduledFrame) {
        return;
      }
    }
  }

  /// The app's last frame as a base64 PNG. Reads the root layer, which only
  /// a debug build keeps; a profile build answers `ok: false`.
  Future<Map<String, Object?>> screenshot() async {
    final view = RendererBinding.instance.renderViews.first;
    final layer = view.debugLayer;
    if (layer is! OffsetLayer) {
      return {'ok': false, 'detail': 'screenshots need a debug build'};
    }
    final physical = view.flutterView.physicalSize;
    final image = await layer.toImage(Offset.zero & physical);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) {
        return {'ok': false, 'detail': 'the frame did not encode'};
      }
      return {
        'ok': true,
        'width': image.width,
        'height': image.height,
        'png': base64Encode(bytes.buffer.asUint8List()),
      };
    } finally {
      image.dispose();
    }
  }
}

/// A label as the static check compares it: no ellipsis, no trailing colon,
/// straight apostrophes, collapsed whitespace, lower case. Inline widgets in
/// rich text (an icon or a badge) are dropped.
String normalizeLabel(String label) {
  var text = label
      .replaceAll('\u{FFFC}', ' ')
      .replaceAll('…', '')
      .replaceAll('...', '')
      .replaceAll('’', "'")
      .trim();
  while (text.endsWith(':')) {
    text = text.substring(0, text.length - 1).trim();
  }
  for (final quote in ['*', '_', '"', '“', '”']) {
    while (text.startsWith(quote)) {
      text = text.substring(1);
    }
    while (text.endsWith(quote)) {
      text = text.substring(0, text.length - 1);
    }
  }
  return text.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
}
