// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_keybindings/crux_keybindings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:simcrux/core/shortcuts/simcrux_action.dart';

/// The cross-suite [KeymapCodec] configured for SimCrux's action set and schema
/// id. Shared by the persistence store and keymap Export/Import.
final KeymapCodec<SimcruxAction> simCruxKeymapCodec = KeymapCodec(
  actions: SimcruxAction.values,
  schema: 'simcrux.keymap',
);

/// Platform-aware default key bindings for every [SimcruxAction].
///
/// Uses Cmd (meta) on macOS / iOS and Ctrl on Linux / Windows.
/// Mirrors the WaveCrux / NetCrux convention so an engineer switching
/// between Crux apps on the same machine encounters the same modifier
/// scheme.
Map<SimcruxAction, ShortcutActivator> defaultBindings() {
  final isMac =
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.iOS;
  SingleActivator mod(LogicalKeyboardKey key, {bool shift = false}) =>
      SingleActivator(
        key,
        meta: isMac,
        control: !isMac,
        shift: shift,
      );

  return <SimcruxAction, ShortcutActivator>{
    // ── file ──────────────────────────────────────────────────────────────
    SimcruxAction.openProject: mod(LogicalKeyboardKey.keyO),
    // Cmd/Ctrl+I — "I for Import", mirroring WaveCrux's importGtkwSession
    // (suite UI-consistency pass). The former Cmd/Ctrl+Shift+I slot now
    // belongs to openTabDiagnostics, WaveCrux's suite-wide Tab
    // Diagnostics chord.
    SimcruxAction.importFusesoc: mod(LogicalKeyboardKey.keyI),
    // closeTab: Cmd/Ctrl+W — the universal "close" convention and the sole
    // owner of this chord, matching WaveCrux and LintCrux (suite
    // keyboard-parity pass). closeProject moves to Cmd/Ctrl+Shift+W.
    SimcruxAction.closeTab: mod(LogicalKeyboardKey.keyW),
    SimcruxAction.closeProject: mod(LogicalKeyboardKey.keyW, shift: true),
    // F5 = Run, matching LintCrux and the VS-Code-like chrome the suite
    // shares. Re-Run Selected keeps the Shift+Mod+R form below.
    SimcruxAction.runRegression: const SingleActivator(LogicalKeyboardKey.f5),
    SimcruxAction.reRunSelected: mod(LogicalKeyboardKey.keyR, shift: true),
    SimcruxAction.cancelRegression: const SingleActivator(
      LogicalKeyboardKey.escape,
    ),
    SimcruxAction.quit: mod(LogicalKeyboardKey.keyQ),
    // ── view ──────────────────────────────────────────────────────────────
    SimcruxAction.toggleTestBrowser: mod(LogicalKeyboardKey.digit1),
    SimcruxAction.toggleInspector: mod(LogicalKeyboardKey.digit2),
    SimcruxAction.toggleLogPanel: mod(LogicalKeyboardKey.digit3),
    // Cmd/Ctrl+Shift+K — theme toggle, matching WaveCrux / NetCrux /
    // LintCrux (suite keyboard-parity pass). No collision: no other
    // SimCrux binding uses Shift+K.
    SimcruxAction.toggleTheme: mod(LogicalKeyboardKey.keyK, shift: true),
    // ── navigate ──────────────────────────────────────────────────────────
    // Nothing. Cmd/Ctrl+Shift+1 and +2 were bound to the focus stubs, which
    // only ever showed a "not yet implemented" notice; both chords are free
    // again. Keyboard navigation is F6 / Shift+F6 region traversal, which the
    // focus system owns rather than a binding.
    // ── search / palette ──────────────────────────────────────────────────
    SimcruxAction.openSearch: mod(LogicalKeyboardKey.keyF),
    SimcruxAction.openCommandPalette: mod(LogicalKeyboardKey.keyP, shift: true),
    // ── multi-project workspace ───────────────────────────────────────────
    // Ctrl/Cmd+P opens the project switcher (VSCode "Quick Open" style).
    // Ctrl/Cmd+Shift+F opens cross-project search.
    SimcruxAction.switchProject: mod(LogicalKeyboardKey.keyP),
    SimcruxAction.searchAcrossProjects: mod(
      LogicalKeyboardKey.keyF,
      shift: true,
    ),
    // ── tools / help ──────────────────────────────────────────────────────
    SimcruxAction.openSettings: mod(LogicalKeyboardKey.comma),
    // Cross-probe (CXP) panel. ⌘/Ctrl+Shift+X — "X" for cross-probe. The
    // panel is also reachable from the Tools menu; this gives it a default
    // accelerator so it is discoverable without hunting through the menu.
    SimcruxAction.openCrossProbePanel: mod(
      LogicalKeyboardKey.keyX,
      shift: true,
    ),
    SimcruxAction.openAbout: const SingleActivator(LogicalKeyboardKey.f1),
    // Diagnostics — WaveCrux parity (suite UI-consistency pass):
    // Cmd/Ctrl+Shift+I ("Inspect tab") opens the Tab Diagnostics drawer,
    // Cmd/Ctrl+Shift+M ("Memory") opens the App Diagnostics dialog.
    SimcruxAction.openTabDiagnostics: mod(LogicalKeyboardKey.keyI, shift: true),
    SimcruxAction.openAppDiagnostics: mod(LogicalKeyboardKey.keyM, shift: true),
    // ── split-pane ────────────────────────────────────────────────────────
    // Mirrors WaveCrux's split-pane binding choices so an engineer who
    // switches between Crux apps sees the same modifier scheme.
    // Cmd/Ctrl+\ → Split Pane Right; Cmd/Ctrl+K W → Close Pane;
    // Cmd/Ctrl+K → → Focus Other Pane. The "K W" / "K →" chord form
    // is non-trivial with the simple SingleActivator surface, so for
    // v1 we use the single-key forms (Cmd/Ctrl+\\ for split; the
    // close-pane and focus-other-pane actions are command-palette /
    // menu-only). Move Tab to Other Pane is command-palette only by
    // design (the gesture equivalent is drag-tab-to-pane).
    SimcruxAction.splitPaneRight: mod(LogicalKeyboardKey.backslash),
  };
}
