// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/shortcuts/shortcut_bindings_provider.dart';
import 'package:simcrux/core/shortcuts/shortcut_manager_widget.dart';
import 'package:simcrux/core/shortcuts/simcrux_action.dart';

/// Send the platform-appropriate modifier (Cmd on macOS, Ctrl
/// otherwise) wrapped around [trigger]. Matches the
/// `defaultBindings()` rule.
Future<void> _sendModifiedKey(
  WidgetTester tester,
  LogicalKeyboardKey trigger,
) async {
  final isMac = defaultTargetPlatform == TargetPlatform.macOS;
  final modifier = isMac
      ? LogicalKeyboardKey.metaLeft
      : LogicalKeyboardKey.controlLeft;
  await tester.sendKeyDownEvent(modifier);
  await tester.sendKeyDownEvent(trigger);
  await tester.sendKeyUpEvent(trigger);
  await tester.sendKeyUpEvent(modifier);
}

void main() {
  testWidgets('fires handler when a bound shortcut is pressed', (tester) async {
    var fired = 0;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: ShortcutManagerWidget(
            handlers: <SimcruxAction, VoidCallback>{
              SimcruxAction.openProject: () => fired++,
            },
            child: const Scaffold(
              body: Focus(autofocus: true, child: SizedBox.shrink()),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await _sendModifiedKey(tester, LogicalKeyboardKey.keyO);
    await tester.pump();

    expect(fired, equals(1));
  });

  testWidgets('does not throw when no handler is registered', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: ShortcutManagerWidget(
            child: Scaffold(
              body: Focus(autofocus: true, child: SizedBox.shrink()),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await _sendModifiedKey(tester, LogicalKeyboardKey.keyO);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('passes plain letter through when text field has focus '
      '(no Ctrl/Cmd)', (tester) async {
    var fired = 0;
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: ShortcutManagerWidget(
            handlers: <SimcruxAction, VoidCallback>{
              SimcruxAction.openProject: () => fired++,
            },
            child: Scaffold(
              body: TextField(
                controller: controller,
                autofocus: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byType(TextField));
    await tester.pump();

    // Plain 'o' (no Ctrl/Cmd) — the text field should receive it; the
    // shortcut manager must NOT fire openProject.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyO);
    await tester.pump();

    expect(fired, equals(0));
  });

  testWidgets(
    'conflict precedence: a freshly remapped action wins the contested chord',
    (tester) async {
      var runFired = false;
      var reRunFired = false;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: ShortcutManagerWidget(
              handlers: <SimcruxAction, VoidCallback>{
                SimcruxAction.runRegression: () => runFired = true,
                SimcruxAction.reRunSelected: () => reRunFired = true,
              },
              child: const Scaffold(
                body: Focus(autofocus: true, child: SizedBox.shrink()),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // runRegression holds F5 by default. Remap reRunSelected ONTO it
      // (reRunSelected becomes the customized interloper). Reuse runRegression's
      // own activator so the test tracks the default, whatever it is.
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ShortcutManagerWidget)),
      );
      final runChord = container.read(
        shortcutBindingsProvider,
      )[SimcruxAction.runRegression]!;
      container
          .read(shortcutBindingsProvider.notifier)
          .setBinding(SimcruxAction.reRunSelected, runChord);
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.f5);
      await tester.pump();

      // The user's remap fires; the default owner is shadowed (does not fire).
      expect(reRunFired, isTrue);
      expect(runFired, isFalse);
    },
  );

  group('a bare Space or Enter binding', () {
    // Space and Enter are how keyboard and screen-reader users activate the
    // focused control. A user binding either one to an action must not take
    // them away from buttons; away from a control the binding still fires.
    Future<(int Function(), int Function())> pumpWithSpaceBound(
      WidgetTester tester, {
      required bool focusButton,
      LogicalKeyboardKey key = LogicalKeyboardKey.space,
    }) async {
      var fired = 0;
      var pressed = 0;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: ShortcutManagerWidget(
              handlers: <SimcruxAction, VoidCallback>{
                SimcruxAction.runRegression: () => fired++,
              },
              child: Scaffold(
                body: Column(
                  children: [
                    TextButton(
                      autofocus: focusButton,
                      onPressed: () => pressed++,
                      child: const Text('Run'),
                    ),
                    Focus(
                      autofocus: !focusButton,
                      child: const SizedBox(width: 10, height: 10),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      ProviderScope.containerOf(
            tester.element(find.byType(ShortcutManagerWidget)),
          )
          .read(shortcutBindingsProvider.notifier)
          .setBinding(SimcruxAction.runRegression, SingleActivator(key));
      await tester.pump();
      return (() => fired, () => pressed);
    }

    testWidgets('Space activates the focused button instead', (tester) async {
      final (fired, pressed) = await pumpWithSpaceBound(
        tester,
        focusButton: true,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(pressed(), 1);
      expect(fired(), 0);
    });

    testWidgets('Enter activates the focused button instead', (tester) async {
      final (fired, pressed) = await pumpWithSpaceBound(
        tester,
        focusButton: true,
        key: LogicalKeyboardKey.enter,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(pressed(), 1);
      expect(fired(), 0);
    });

    testWidgets('still fires when focus is not on a control', (tester) async {
      final (fired, pressed) = await pumpWithSpaceBound(
        tester,
        focusButton: false,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(fired(), 1);
      expect(pressed(), 0);
    });
  });
}
