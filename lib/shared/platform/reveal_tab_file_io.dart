// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:crux_ide_layout/crux_ide_layout.dart' show cruxRevealFile;

/// io implementation — see the conditional export in `reveal_tab_file.dart`.
void revealTabFile(String filePath) {
  // Fire and forget; a file manager that does not open is reported by
  // cruxRevealFile, which names the path.
  unawaited(cruxRevealFile(filePath));
}
