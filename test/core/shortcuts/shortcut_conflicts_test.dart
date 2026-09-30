// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/shortcuts/shortcut_bindings.dart';
import 'package:simcrux/core/shortcuts/shortcut_conflicts.dart';
import 'package:simcrux/core/shortcuts/simcrux_action.dart';

void main() {
  group('resolveShortcutConflicts', () {
    test('a customized remap wins the chord over the default owner', () {
      // runRegression holds F5 by default; the user remaps reRunSelected
      // (default Ctrl/Cmd+Shift+R) onto F5.
      const f5 = SingleActivator(LogicalKeyboardKey.f5);
      final r = resolveShortcutConflicts({
        SimcruxAction.runRegression: f5, // == its default → owner
        SimcruxAction.reRunSelected: f5, // != its default → interloper
      });
      // Runtime precedence: the interloper fires; the owner is shadowed.
      expect(
        r.effectiveBindings.containsKey(SimcruxAction.reRunSelected),
        isTrue,
      );
      expect(
        r.effectiveBindings.containsKey(SimcruxAction.runRegression),
        isFalse,
      );
      // Asymmetric UI view: both rows agree reRunSelected is the winner.
      expect(
        r.conflicts[SimcruxAction.runRegression]!.winner,
        SimcruxAction.reRunSelected,
      );
      expect(
        r.conflicts[SimcruxAction.reRunSelected]!.winner,
        SimcruxAction.reRunSelected,
      );
      expect(r.conflictChordCount, 1);
    });

    test('the default keymap has no collisions (every chord is unique)', () {
      final r = resolveShortcutConflicts(defaultBindings());
      expect(r.conflicts, isEmpty);
      expect(r.conflictChordCount, 0);
    });
  });
}
