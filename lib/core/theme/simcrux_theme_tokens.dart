// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_theme/crux_theme.dart';

/// Registers SimCrux's themable-token catalogs with the shared
/// [ThemeRegistry]. Called once from [bootstrap]; idempotent so a
/// second bootstrap (test hot-restart, doubled init) is a no-op.
///
/// SimCrux currently only registers the suite-shared `chrome` catalog
/// — the app's product panes (test browser, run details, log preview,
/// trend tracking) don't yet have a curated theme-token catalog. When
/// they do, register the additional category here alongside the chrome
/// call.
void registerSimcruxThemeTokens() {
  registerCruxThemeChromeTokens();
}
