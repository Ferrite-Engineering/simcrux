// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_workspace/crux_workspace.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';

/// The recently opened SimCrux projects (`simcrux.yaml` files).
///
/// The suite's shared Recent list: opening records an entry, a row can be
/// removed, Clear Recent empties the list, and a file that has gone is shown
/// as missing and dropped when opened.
///
/// Every place that opens a project calls
/// `ref.read(recentProjects.provider.notifier).markOpened(path)` after the
/// open succeeded.
final CruxRecentList recentProjects = CruxRecentList(
  name: 'recentProjects',
  store: _AppSettingsRecentStore.new,
  // The cap SimCrux's list has always had, named where it is set.
  // ignore: avoid_redundant_argument_values
  capacity: AppSettings.recentProjectsMax,
);

/// Keeps the list where SimCrux has always kept it: inside [AppSettings], as a
/// JSON-encoded string under `simcrux.recentProjectPaths`.
///
/// Not a `CruxPrefsRecentStore`: that reads a string-list preference, finds a
/// string under this key, reads it as empty, and the next save would destroy
/// every user's list.
class _AppSettingsRecentStore implements CruxRecentStore {
  _AppSettingsRecentStore(this._ref);

  final Ref _ref;

  @override
  Future<List<String>> load() async {
    try {
      final settings = await _ref.read(appSettingsProvider.future);
      return settings.recentProjectPaths;
    } on Object {
      return const <String>[];
    }
  }

  @override
  Future<void> save(List<String> entries) =>
      _ref.read(appSettingsProvider.notifier).setRecentProjects(entries);
}
