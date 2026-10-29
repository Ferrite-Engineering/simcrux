// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// The app tool/x11_keys/check_key_probe.sh builds twice, with the Linux
// runner's keymap guard and without it, to show what a key press does on a
// trusted and on an untrusted X display. It prints every key and every edit
// that reaches the framework, so the script can tell a delivered key from a
// dropped one: KEY <label> per key down, TEXT <field contents> per edit, and
// SHORTCUT save when Ctrl+S fires.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  HardwareKeyboard.instance.addHandler((event) {
    if (event is KeyDownEvent) {
      stdout.writeln('KEY ${event.logicalKey.keyLabel}');
    }
    return false;
  });
  runApp(const KeyProbeApp());
}

class KeyProbeApp extends StatelessWidget {
  const KeyProbeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            const SingleActivator(LogicalKeyboardKey.keyS, control: true): () =>
                stdout.writeln('SHORTCUT save'),
          },
          child: Center(
            child: SizedBox(
              width: 400,
              child: TextField(
                autofocus: true,
                onChanged: (text) => stdout.writeln('TEXT $text'),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
