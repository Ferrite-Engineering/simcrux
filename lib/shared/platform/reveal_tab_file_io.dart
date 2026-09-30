// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_io/crux_io.dart' as crux_io;

/// io implementation — see the conditional export in `reveal_tab_file.dart`.
void revealTabFile(String filePath) {
  // Best-effort fire-and-forget; failures are swallowed inside crux_io.
  // ignore: discarded_futures
  crux_io.revealInFileManager(filePath);
}
