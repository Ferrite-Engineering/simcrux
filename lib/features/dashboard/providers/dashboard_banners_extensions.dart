// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Extension-point provider that returns the list of full-width
/// banner widgets the dashboard renders **above** all other chrome
/// (above the `SimcruxToolbar`, above the filter bars, above the
/// results table).
///
/// Each entry is rendered as-is — usually a [MaterialBanner] or a
/// `Column` of banners. Widgets that have nothing to show should
/// render `SizedBox.shrink()` so they don't add vertical padding.
///
/// Open-core default returns an empty list. The Pro overlay
/// populates it with the regression alerts banner.
/// Adding a new banner contributor means inserting it into this
/// provider via `proOverrides` — the open-core dashboard already
/// consumes the list, so no UI changes are needed when a new
/// contributor lands.
final Provider<List<Widget>> dashboardBannersProvider = Provider<List<Widget>>(
  (_) => const <Widget>[],
);
