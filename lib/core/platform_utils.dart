// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/foundation.dart';

/// True when running on a desktop platform (Linux, macOS, or Windows).
///
/// Used by adaptive UI surfaces (Settings, About, etc.) to decide
/// between a modal dialog (desktop) and a full-screen pushed route
/// (mobile / tablet) so behavior matches platform conventions.
bool get isDesktopPlatform =>
    defaultTargetPlatform == TargetPlatform.linux ||
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.windows;
