// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_keybindings/crux_keybindings.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/shortcuts/keymap_presets.dart';
import 'package:simcrux/core/shortcuts/shortcut_bindings.dart';
import 'package:simcrux/core/shortcuts/simcrux_action.dart';

void main() {
  group('bindingsForPreset', () {
    test('simCrux preset round-trips through presetForBindings', () {
      // Can't use `equals(defaultBindings())` — SingleActivator has no ==.
      expect(presetForBindings(defaultBindings()), KeymapPreset.simCrux);
    });

    test('simCrux preset equals the defaults action-by-action', () {
      final defaults = defaultBindings();
      final preset = bindingsForPreset(KeymapPreset.simCrux);
      expect(preset.length, defaults.length);
      for (final action in SimcruxAction.values) {
        expect(
          KeyBindingResolver.activatorsEqual(preset[action], defaults[action]),
          isTrue,
          reason: '${action.name} should match its default',
        );
      }
    });
  });

  group('presetForBindings', () {
    test(
      'identifies an independently-built default map (by-value equality)',
      () {
        // Two defaultBindings() calls build distinct SingleActivator instances;
        // only value comparison via KeyBindingResolver.activatorsEqual matches.
        expect(
          presetForBindings(bindingsForPreset(KeymapPreset.simCrux)),
          KeymapPreset.simCrux,
        );
      },
    );

    test('returns null (Custom) for a hand-edited map', () {
      final custom = Map<SimcruxAction, ShortcutActivator>.of(defaultBindings())
        ..[SimcruxAction.openSearch] = const SingleActivator(
          LogicalKeyboardKey.keyJ,
          control: true,
        );
      expect(presetForBindings(custom), isNull);
    });

    test('returns null (Custom) when an action is unbound', () {
      final custom = Map<SimcruxAction, ShortcutActivator>.of(defaultBindings())
        ..remove(SimcruxAction.openSearch);
      expect(presetForBindings(custom), isNull);
    });
  });
}
