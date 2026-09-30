// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Where installed `.crux-theme.json` packs live: `themes/` in the
/// application-support directory, created on demand.
///
/// Settings → Appearance installs packs here and bootstrap restores the
/// active one from here, so the two cannot disagree about where a pack is.
/// Falls back to the system temp directory when `path_provider` is not
/// available (widget tests), so Settings → Appearance stays renderable.
Future<Directory> simcruxThemePackDirectory() async {
  try {
    final appSupport = await getApplicationSupportDirectory();
    final dir = Directory(p.join(appSupport.path, 'themes'));
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir;
  } on Object {
    return Directory.systemTemp;
  }
}
