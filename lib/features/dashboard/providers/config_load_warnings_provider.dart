// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the dashboard shows the active project's `info`-severity load
/// advisories (`RegressionConfig.loadWarnings`) in `ConfigLoadWarningsBanner`.
///
/// Open core always shows them: an advisory is how an open-core user learns
/// that a `seeds:` sweep ran once instead of expanding. The Pro overlay binds
/// this to its **Settings > Parameterization** warnings switch.
///
/// **It governs `info` entries only.** A `warning`-severity advisory says the
/// loader dropped a capability the file asked for (a simulator binary, an
/// environment, an option), and the banner shows those whatever this says:
/// a user who turned the parameterization noise off must still learn why
/// their simulator configuration was ignored.
final Provider<bool> showConfigLoadWarningsProvider = Provider<bool>(
  (_) => true,
  name: 'showConfigLoadWarningsProvider',
);
