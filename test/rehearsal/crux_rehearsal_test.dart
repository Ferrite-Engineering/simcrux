// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// The rehearsal step handler against small widget trees. The handler takes a
// WidgetController, so the tester here runs the same code a live rehearsal
// runs through LiveWidgetController.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../rehearsal/crux_rehearsal.dart';

Future<CruxRehearsal> _pump(WidgetTester tester, Widget body) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: body)));
  return CruxRehearsal(tester, findTimeout: const Duration(milliseconds: 300));
}

Map<String, Object?> _step(String kind, {String? label, List<String>? keys}) =>
    {'kind': kind, 'label': ?label, 'keys': ?keys};

Map<String, Object?> _press(List<String> mods, String key, {int repeat = 1}) =>
    {
      'kind': 'press',
      'text': 'press ${[...mods, key].join('+')}',
      'repeat': repeat,
      'chords': [
        {'mods': mods, 'key': key},
      ],
    };

void main() {
  group('click', () {
    testWidgets('clicks the control whose text the step names', (tester) async {
      var taps = 0;
      final rehearsal = await _pump(
        tester,
        TextButton(onPressed: () => taps++, child: const Text('Worst paths')),
      );
      final result = await rehearsal.perform(
        _step('click', label: 'Worst paths'),
      );
      expect(result['ok'], isTrue, reason: '${result['detail']}');
      expect(taps, 1);
    });

    testWidgets('matches the way the static check does', (tester) async {
      var taps = 0;
      final rehearsal = await _pump(
        tester,
        TextButton(
          onPressed: () => taps++,
          child: const Text('Show Seed Failure Heatmap...'),
        ),
      );
      final result = await rehearsal.perform(
        _step('choose', label: 'show seed failure heatmap…'),
      );
      expect(result['ok'], isTrue, reason: '${result['detail']}');
      expect(taps, 1);
    });

    testWidgets('finds an icon button by its tooltip', (tester) async {
      var taps = 0;
      final rehearsal = await _pump(
        tester,
        IconButton(
          tooltip: 'Run',
          onPressed: () => taps++,
          icon: const Icon(Icons.play_arrow),
        ),
      );
      final result = await rehearsal.perform(_step('click', label: 'Run'));
      expect(result['ok'], isTrue, reason: '${result['detail']}');
      expect(taps, 1);
    });

    testWidgets('finds a control by an ARB key used as its widget key', (
      tester,
    ) async {
      var taps = 0;
      final rehearsal = await _pump(
        tester,
        IconButton(
          key: const ValueKey<String>('toolbarRun'),
          onPressed: () => taps++,
          icon: const Icon(Icons.play_arrow),
        ),
      );
      final result = await rehearsal.perform(
        _step('click', label: 'Run', keys: ['toolbarRun']),
      );
      expect(result['ok'], isTrue, reason: '${result['detail']}');
      expect(taps, 1);
    });

    testWidgets('a label nothing shows is the first divergence', (
      tester,
    ) async {
      final rehearsal = await _pump(tester, const Text('Flow Runs'));
      final result = await rehearsal.perform(
        _step('click', label: 'Worst paths'),
      );
      expect(result['ok'], isFalse);
      expect(result['detail'], contains('Worst paths'));
    });

    testWidgets('a label behind a modal barrier cannot be clicked', (
      tester,
    ) async {
      var taps = 0;
      final rehearsal = await _pump(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () {
              taps++;
              unawaited(
                showDialog<void>(
                  context: context,
                  builder: (_) => const AlertDialog(content: Text('Busy')),
                ),
              );
            },
            child: const Text('Open'),
          ),
        ),
      );
      expect(
        (await rehearsal.perform(_step('click', label: 'Open')))['ok'],
        isTrue,
      );
      await tester.pumpAndSettle();
      final again = await rehearsal.perform(_step('click', label: 'Open'));
      expect(again['ok'], isFalse);
      expect(taps, 1);
    });

    testWidgets('a disabled button is a divergence, not a silent click', (
      tester,
    ) async {
      final rehearsal = await _pump(
        tester,
        const FilledButton(onPressed: null, child: Text('Accept')),
      );
      final result = await rehearsal.perform(_step('click', label: 'Accept'));
      expect(result['ok'], isFalse);
      expect(result['detail'], contains('disabled'));
    });

    testWidgets('right-click sends the secondary button', (tester) async {
      var secondary = 0;
      final rehearsal = await _pump(
        tester,
        GestureDetector(
          onSecondaryTap: () => secondary++,
          child: const Text('alu.sv'),
        ),
      );
      final result = await rehearsal.perform(
        _step('right_click', label: 'alu.sv'),
      );
      expect(result['ok'], isTrue, reason: '${result['detail']}');
      expect(secondary, 1);
    });
  });

  group('hold', () {
    testWidgets('passes while the label is on screen', (tester) async {
      final rehearsal = await _pump(
        tester,
        const Text('Reload Driver Plugins'),
      );
      expect(
        (await rehearsal.perform(
          _step('hold', label: 'Reload Driver Plugins'),
        ))['ok'],
        isTrue,
      );
      expect(
        (await rehearsal.perform(_step('hold', label: 'Flow Runs')))['ok'],
        isFalse,
      );
    });
  });

  group('press', () {
    Widget shortcuts(Map<ShortcutActivator, VoidCallback> bindings) =>
        CallbackShortcuts(
          bindings: bindings,
          child: const Focus(autofocus: true, child: Text('ready')),
        );

    testWidgets('the primary modifier is Control off macOS', (tester) async {
      var palette = 0;
      final rehearsal = await _pump(
        tester,
        shortcuts({
          const SingleActivator(
            LogicalKeyboardKey.keyP,
            control: true,
            shift: true,
          ): () =>
              palette++,
        }),
      );
      await tester.pump();
      final result = await rehearsal.perform(_press(['primary', 'shift'], 'P'));
      expect(result['ok'], isTrue, reason: '${result['detail']}');
      expect(palette, 1);
    });

    testWidgets('the primary modifier is Command on macOS', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      var palette = 0;
      final rehearsal = await _pump(
        tester,
        shortcuts({
          const SingleActivator(
            LogicalKeyboardKey.keyP,
            meta: true,
            shift: true,
          ): () =>
              palette++,
        }),
      );
      await tester.pump();
      final result = await rehearsal.perform(_press(['primary', 'shift'], 'P'));
      expect(result['ok'], isTrue, reason: '${result['detail']}');
      expect(palette, 1);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('repeats a chord the script says to press twice', (
      tester,
    ) async {
      var toggles = 0;
      final rehearsal = await _pump(
        tester,
        shortcuts({
          const SingleActivator(LogicalKeyboardKey.digit1, control: true): () =>
              toggles++,
        }),
      );
      await tester.pump();
      await rehearsal.perform(_press(['primary'], '1', repeat: 2));
      expect(toggles, 2);
    });

    testWidgets('a function key nothing binds is a divergence', (tester) async {
      final rehearsal = await _pump(tester, shortcuts({}));
      await tester.pump();
      final result = await rehearsal.perform(_press([], 'F5'));
      expect(result['ok'], isFalse);
      expect(result['detail'], contains('F5'));
    });

    testWidgets('a bare Esc with nothing to dismiss is not a failure', (
      tester,
    ) async {
      final rehearsal = await _pump(tester, shortcuts({}));
      await tester.pump();
      expect((await rehearsal.perform(_press([], 'Esc')))['ok'], isTrue);
    });

    testWidgets('an unknown key name fails the step', (tester) async {
      final rehearsal = await _pump(tester, shortcuts({}));
      expect((await rehearsal.perform(_press([], 'Hyper')))['ok'], isFalse);
    });
  });

  group('type and clear', () {
    testWidgets('types into the focused field and clears it', (tester) async {
      final controller = TextEditingController(text: '>');
      addTearDown(controller.dispose);
      final changes = <String>[];
      final rehearsal = await _pump(
        tester,
        TextField(
          controller: controller,
          autofocus: true,
          onChanged: changes.add,
        ),
      );
      await tester.pump();
      final typed = await rehearsal.perform({
        'kind': 'type',
        'text': 'heatmap',
      });
      expect(typed['ok'], isTrue, reason: '${typed['detail']}');
      expect(controller.text, '>heatmap');
      expect(changes.last, '>heatmap');
      expect((await rehearsal.perform({'kind': 'clear'}))['ok'], isTrue);
      expect(controller.text, isEmpty);
    });

    testWidgets('Enter submits the focused field', (tester) async {
      final submitted = <String>[];
      final rehearsal = await _pump(
        tester,
        TextField(autofocus: true, onSubmitted: submitted.add),
      );
      await tester.pump();
      await rehearsal.perform({'kind': 'type', 'text': 'echo'});
      final result = await rehearsal.perform(_press([], 'Enter'));
      expect(result['ok'], isTrue, reason: '${result['detail']}');
      expect(submitted, ['echo']);
    });

    testWidgets('typing with no field focused is a divergence', (tester) async {
      final rehearsal = await _pump(tester, const Text('no field'));
      final result = await rehearsal.perform({'kind': 'type', 'text': 'x'});
      expect(result['ok'], isFalse);
    });
  });

  group('scroll', () {
    testWidgets('scrolls the largest visible list', (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      final rehearsal = await _pump(
        tester,
        ListView(
          controller: controller,
          children: [
            for (var i = 0; i < 100; i++)
              SizedBox(height: 40, child: Text('$i')),
          ],
        ),
      );
      final down = await rehearsal.perform({
        'kind': 'scroll',
        'direction': 'down',
      });
      expect(down['ok'], isTrue, reason: '${down['detail']}');
      expect(controller.offset, greaterThan(0));
    });
  });

  group('requests', () {
    testWidgets('a step a driver cannot perform is skipped, not failed', (
      tester,
    ) async {
      final rehearsal = await _pump(tester, const Text('x'));
      final result = await rehearsal.handle({
        'op': 'perform',
        'step': {'kind': 'pointer'},
      });
      expect(result.containsKey('ok'), isTrue);
      expect(result['ok'], isNull);
    });

    testWidgets('an unknown op is an error answer, not a throw', (
      tester,
    ) async {
      final rehearsal = await _pump(tester, const Text('x'));
      expect((await rehearsal.handle({'op': 'dance'}))['ok'], isFalse);
      expect((await rehearsal.handle({'op': 'ping'}))['ok'], isTrue);
    });
  });

  group('readiness', () {
    testWidgets('names what the app is still waiting for', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: Text('x')));
      final binding = WidgetsBinding.instance;
      expect(
        rehearsalNotReady(),
        binding.firstFrameRasterized ? isNull : contains('first frame'),
      );
    });
  });

  group('keys', () {
    test('every key word the scripts use has a logical key', () {
      for (final name in [
        'Esc',
        'Enter',
        'Return',
        'Tab',
        'Space',
        'Delete',
        'F5',
        'F12',
        'P',
        '1',
        ',',
        r'\',
        '/',
      ]) {
        expect(CruxRehearsal.logicalKeyFor(name), isNotNull, reason: name);
      }
      expect(CruxRehearsal.logicalKeyFor('P'), LogicalKeyboardKey.keyP);
      expect(CruxRehearsal.logicalKeyFor(','), LogicalKeyboardKey.comma);
      expect(CruxRehearsal.logicalKeyFor('F5'), LogicalKeyboardKey.f5);
    });

    test('physical keys are the US layout ones', () {
      expect(
        CruxRehearsal.physicalKeyFor(LogicalKeyboardKey.keyP),
        PhysicalKeyboardKey.keyP,
      );
      expect(
        CruxRehearsal.physicalKeyFor(LogicalKeyboardKey.digit1),
        PhysicalKeyboardKey.digit1,
      );
      expect(
        CruxRehearsal.physicalKeyFor(LogicalKeyboardKey.f5),
        PhysicalKeyboardKey.f5,
      );
      expect(
        CruxRehearsal.physicalKeyFor(LogicalKeyboardKey.comma),
        PhysicalKeyboardKey.comma,
      );
    });

    test('labels normalize the way the static check normalizes them', () {
      expect(normalizeLabel('Show Flaky Tests…'), 'show flaky tests');
      expect(
        normalizeLabel('Import Formal Project...'),
        'import formal project',
      );
      expect(normalizeLabel('  Test:  '), 'test');
      expect(normalizeLabel('Don’t   ask'), "don't ask");
    });
  });
}
