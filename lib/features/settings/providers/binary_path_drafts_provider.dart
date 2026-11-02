// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What the binary-path fields in Settings > Engines show but have not saved
/// yet, by engine id.
///
/// A field records its text here as the user types and removes it once the
/// value is saved. Check Formal Tools reads it, so the check runs against the
/// paths on screen rather than the last ones saved.
final NotifierProvider<BinaryPathDrafts, Map<String, String>>
binaryPathDraftsProvider =
    NotifierProvider<BinaryPathDrafts, Map<String, String>>(
      BinaryPathDrafts.new,
    );

/// Notifier behind [binaryPathDraftsProvider].
class BinaryPathDrafts extends Notifier<Map<String, String>> {
  @override
  Map<String, String> build() => const <String, String>{};

  /// Records [value] as what the field for [engineId] shows.
  void set(String engineId, String value) {
    state = <String, String>{...state, engineId: value};
  }

  /// Forgets [engineId]'s draft because its value is saved.
  ///
  /// With [ifValue], only when the draft is still that text, so a path typed
  /// while the save was running is kept.
  void clear(String engineId, {String? ifValue}) {
    final draft = state[engineId];
    if (draft == null || (ifValue != null && draft != ifValue)) return;
    state = <String, String>{...state}..remove(engineId);
  }
}
