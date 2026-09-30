// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Services-layer handle that opens a SimCrux project — a `simcrux.yaml`
/// regression config — as a workspace tab, on behalf of a CXP peer.
///
/// `request_open_artifact` names a file, and for a config the right answer
/// is the one the user gets from File → Open Project: a config tab. It is
/// not the external editor, which is where every `source` artifact used to
/// go, so VS Code's "Open in SimCrux Desktop" came back to VS Code as YAML
/// text while the ack said it was honoured. Opening a tab is workspace
/// business, which lives in the feature layer; this seam is how the CXP
/// inbound path reaches it without the services layer importing a feature.
///
/// The feature layer publishes an [opener] here and clears it when it goes
/// away. [opener] is `null` while nothing is published (headless startup,
/// unit tests); [open] then degrades to `false`, so the request is declined
/// with a reason instead of throwing.
///
/// [opener] is handed a config path that has already been checked, with any
/// `<design>.crux-project` manifest already swapped for the config it names:
/// it must open exactly that path, and swap nothing, so that the string the
/// check judged is the string opened.
class CxpProjectOpenHandle {
  /// Opens the SimCrux config at the given absolute path as a workspace tab,
  /// or focuses the tab that already holds it, returning whether it did.
  Future<bool> Function(String configPath)? opener;

  /// Opens [configPath], returning `false` when no opener is published.
  Future<bool> open(String configPath) async =>
      (await opener?.call(configPath)) ?? false;
}

/// App-wide [CxpProjectOpenHandle]. Root-scoped by design — the bridge from
/// root scope (the CXP inbound path) into the workspace's tabs.
final Provider<CxpProjectOpenHandle> cxpProjectOpenHandleProvider =
    Provider<CxpProjectOpenHandle>((ref) => CxpProjectOpenHandle());
