// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

import 'package:crux_settings/crux_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/features/dashboard/models/dashboard_column_layout.dart';

/// `SharedPreferences` codec for the results table's column widths.
///
/// Stored as one JSON object of column name to weight. A column missing or
/// unreadable in it takes its default; the others keep theirs.
class DashboardColumnLayoutCodec
    implements SettingsCodec<DashboardColumnLayout> {
  /// Const constructor — the codec is stateless.
  const DashboardColumnLayoutCodec();

  /// `SharedPreferences` key holding the JSON object.
  static const String prefsKey = 'simcrux.dashboardColumnWeights';

  @override
  Future<DashboardColumnLayout> load(SharedPreferences prefs) async {
    final raw = prefs.get(prefsKey);
    if (raw is! String) return DashboardColumnLayout.defaults;
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return DashboardColumnLayout.defaults;
    }
    if (decoded is! Map<String, Object?>) {
      return DashboardColumnLayout.defaults;
    }
    return DashboardColumnLayout({
      for (final column in DashboardColumnLayout.columns)
        if (decoded[column.name] case final num weight)
          column: weight.toDouble(),
    });
  }

  @override
  Future<void> save(SharedPreferences prefs, DashboardColumnLayout settings) =>
      prefs.setString(
        prefsKey,
        jsonEncode({
          for (final entry in settings.weights.entries)
            entry.key.name: entry.value,
        }),
      );
}
