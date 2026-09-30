// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the dashboard shows the active project's load advisories
/// (`RegressionConfig.loadWarnings`) in `ConfigLoadWarningsBanner`.
///
/// Open core always shows them: an advisory is how an open-core user learns
/// that a `seeds:` sweep ran once instead of expanding. The Pro overlay binds
/// this to its **Settings > Parameterization** warnings switch.
final Provider<bool> showConfigLoadWarningsProvider = Provider<bool>(
  (_) => true,
  name: 'showConfigLoadWarningsProvider',
);
