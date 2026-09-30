// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/shortcuts/shortcut_bindings.dart';
import 'package:simcrux/core/shortcuts/simcrux_action.dart';
import 'package:simcrux/core/shortcuts/simcrux_action_descriptors.dart';

/// Every action must be reachable, or be listed here with the reason it is not.
///
/// ## The defect class this closes
///
/// The most expensive defect class in the suite is work that ships and then
/// has no way in. An action's `surfaces` set is one line, it is silent when
/// empty, and nothing else checks it:
///
///  * LintCrux Pro's entire multi-project feature set (project switcher,
///    reopen recent, cross-project search) was built, tier-badged,
///    telemetry-instrumented, and reachable by nobody: a "hide the stub
///    actions" pass emptied the surface sets after it shipped.
///  * SimCrux's `dispatchPrAnnotations` had a working dispatcher and no menu
///    entry, while the user documentation described the menu entry's
///    behaviour in detail.
///  * NetCrux's X-Trace engine computed a correct result into a provider
///    nothing rendered, while its documentation called it shipped.
///
/// Each was found by a human reading code. This makes the machine read it.
///
/// ## Why an allowlist rather than a blanket ban
///
/// A surfaceless action is sometimes correct — a focus command bound only to a
/// chord, or an engine whose UI genuinely has not been built. What is never
/// correct is an *unexplained* one. The allowlist is a map so every entry
/// carries its reason: an allowance without one is indistinguishable from an
/// oversight six months later, which is precisely how the LintCrux case
/// survived.
///
/// When a surface lands, delete the entry. When one is emptied, this fails.
/// Currently empty, and that is the honest state: every SimCrux action is
/// reachable from a menu, the palette or a toolbar.
///
/// It was not empty. `focusTestBrowser` / `focusRunResults` sat here reading
/// "deliberately chord-only: they move focus between panes for keyboard
/// users" — which was not true of either. Neither had a handler; dispatching
/// one showed a "not yet implemented" snack, and the descriptor table said so
/// in as many words while this allowlist said the opposite. The entries were
/// what made the guard green, not what made the actions reachable, and the
/// binding assertion below had been reduced to enforcing that a stub keep its
/// chord. The actions were deleted (F6 / Shift+F6 region traversal is the
/// pane-to-pane focus movement SimCrux actually ships), and the contradiction
/// went with them.
///
/// The map stays as the seam the first test points new violations at.
///
/// ## A declared surface is only worth something if it is mounted
///
/// This guard reads the descriptor table, so on its own it credits an action
/// with a surface nobody renders. The other two halves live elsewhere:
/// `test/core/shortcuts/action_surface_conformance_test.dart` pumps each
/// surface widget and asserts it renders exactly the actions the table gives
/// it (in both directions for the hand-placed toolbar), and
/// `import_reachability_guard_test.dart` proves those widgets' files are
/// reached from the entry points — `DesktopMenuBar` from `lib/app.dart`,
/// `SimcruxToolbar` from the workspace screen, `CommandPaletteDialog` from
/// the `openCommandPalette` handler. The toolbar's overflow menu shares the
/// menu surface; SimCrux declares no surface of its own for it.
const _allowedSurfaceless = <SimcruxAction, String>{};

void main() {
  test('every action is reachable, or explains why not', () {
    final offenders = <String>[];

    for (final action in SimcruxAction.values) {
      final hasSurface = descriptorFor(action).surfaces.isNotEmpty;
      if (hasSurface) {
        // A surfaced action that is ALSO on the allowlist means the allowance
        // outlived the problem. Fail, so the list cannot rot.
        if (_allowedSurfaceless.containsKey(action)) {
          offenders.add(
            '${action.name}: now has a surface but is still allowlisted — '
            'delete its entry from _allowedSurfaceless',
          );
        }
        continue;
      }
      if (_allowedSurfaceless.containsKey(action)) continue;
      offenders.add(
        '${action.name}: declares no ActionSurface, so it appears in no menu, '
        'no palette and no toolbar. If that is deliberate, add it to '
        '_allowedSurfaceless with the reason. If not, give it a surface — '
        'this is the built-but-unreachable defect class.',
      );
    }

    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  test('an allowlisted action still has a keybinding to reach it by', () {
    // The allowlist exists for actions reachable some OTHER way. An entry with
    // no surface and no chord is not an exception to the rule — it is the bug
    // the rule is about, wearing an exemption.
    //
    // The allowlist is empty today, so the loop below asserts nothing. It is
    // kept because the first test's failure message sends the next
    // surfaceless action straight to `_allowedSurfaceless`, and this is what
    // stops "surfaceless AND unbound" being accepted there. The expectation
    // in front of it states that emptiness out loud, so the loop's vacuity is
    // a fact in the diff rather than a green test asserting nothing — when
    // you add the first entry, delete this line and let the loop work.
    expect(
      _allowedSurfaceless,
      isEmpty,
      reason:
          'every SimCrux action is reachable from a surface today. If you are '
          'adding the first allowlist entry, delete this expectation — the '
          'loop below is the check that entry needs.',
    );
    final unreachable = <String>[];
    for (final action in _allowedSurfaceless.keys) {
      final bound = defaultBindings().containsKey(action);
      if (!bound) {
        unreachable.add(
          '${action.name}: allowlisted as surfaceless AND has no default '
          'keybinding — it is reachable by nothing. Either give it a surface, '
          'give it a chord, or delete the action.',
        );
      }
    }
    expect(unreachable, isEmpty, reason: unreachable.join('\n'));
  });

  test('the guard is not vacuous', () {
    // If the enum or the descriptor table moved, every check above would pass
    // trivially.
    expect(SimcruxAction.values.length, greaterThan(10));
    expect(
      SimcruxAction.values.where(
        (a) => descriptorFor(a).surfaces.isNotEmpty,
      ),
      isNotEmpty,
      reason: 'no action has any surface — the descriptor table is not loading',
    );
  });
}
