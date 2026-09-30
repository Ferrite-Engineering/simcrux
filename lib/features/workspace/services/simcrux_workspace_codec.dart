// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_io/crux_io.dart';
import 'package:crux_workspace/crux_workspace.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/dashboard_view_mode.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/features/dashboard/models/dashboard_sort.dart';
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';

/// JSON codec for [SimcruxTabPayload], implementing
/// [`crux_workspace`](https://github.com/Ferrite-Engineering/crux-shared)'s
/// `WorkspaceCodec<P>`.
///
/// Tolerates corrupt or partial payloads gracefully — missing fields
/// fall back to the constructor defaults, malformed scalars fall back
/// to "no constraint", and unknown enum names fall back to the default
/// member. Schema-version handling lives in the framework; this codec
/// keeps payload-internal `schemaVersion` at 1 because the payload
/// shape has not evolved yet.
///
/// Serializes [SimcruxTabPayload] to/from JSON so payloads round-trip
/// cleanly between the workspace document and the per-tab
/// `.simcrux-session` export.
class SimcruxWorkspaceCodec extends WorkspaceCodec<SimcruxTabPayload> {
  /// Creates a [SimcruxWorkspaceCodec].
  const SimcruxWorkspaceCodec();

  @override
  int get schemaVersion => 1;

  @override
  Map<String, Object?> payloadToJson(SimcruxTabPayload payload) {
    return <String, Object?>{
      'configPath': payload.configPath,
      if (payload.selectedTestId != null)
        'selectedTestId': payload.selectedTestId,
      'filter': <String, Object?>{
        'statuses': payload.filterStatuses.map((s) => s.name).toList(),
        'suites': payload.filterSuites.toList(),
        'simulators': payload.filterSimulators.toList(),
        'testNameSubstring': payload.filterTestNameSubstring,
      },
      'sort': <String, Object?>{
        'column': payload.sort.column.name,
        'direction': payload.sort.direction.name,
      },
      'viewMode': payload.viewMode.name,
      'expandedSuites': payload.expandedSuites.toList(),
    };
  }

  @override
  SimcruxTabPayload payloadFromJson(Map<String, Object?> json) {
    final configPath = _readString(json['configPath']) ?? '';
    final selectedTestId = _readString(json['selectedTestId']);
    final filterRaw = json['filter'];
    final filter = filterRaw is Map<String, Object?>
        ? filterRaw
        : const <String, Object?>{};
    final sortRaw = json['sort'];
    final sort = sortRaw is Map<String, Object?>
        ? sortRaw
        : const <String, Object?>{};
    return SimcruxTabPayload(
      configPath: configPath,
      selectedTestId: selectedTestId,
      filterStatuses: _readStatuses(filter['statuses']),
      filterSuites: _readStringSet(filter['suites']),
      filterSimulators: _readStringSet(filter['simulators']),
      filterTestNameSubstring: _readString(filter['testNameSubstring']) ?? '',
      sort: _readSort(sort),
      viewMode: DashboardViewMode.fromName(_readString(json['viewMode'])),
      expandedSuites: _readStringSet(json['expandedSuites']),
    );
  }

  @override
  String displayNameFor(SimcruxTabPayload payload) {
    final path = payload.configPath;
    if (path.isEmpty) return '(new tab)';
    return p.basename(path);
  }

  @override
  String? identityOf(SimcruxTabPayload payload) {
    final path = payload.configPath.trim();
    // A tab with no config yet — the trailing "+" button's blank tab — has no
    // identity, so two of them are two tabs rather than one. Everything else
    // is identified by the config file it points at.
    if (path.isEmpty) return null;
    // The canonical key, not the raw string: a `simcrux.yaml` reached through
    // a relative launch argument, a `..` segment, a symlink or a differently
    // cased spelling is the same regression suite, and treating it as a
    // different one is what let a CLI relaunch stack a duplicate tab every
    // time.
    return canonicalPathKey(path);
  }

  static String? _readString(Object? raw) => raw is String ? raw : null;

  static Set<TestStatus> _readStatuses(Object? raw) {
    if (raw is! List) return const <TestStatus>{};
    final out = <TestStatus>{};
    for (final entry in raw) {
      if (entry is! String) continue;
      for (final s in TestStatus.values) {
        if (s.name == entry) {
          out.add(s);
          break;
        }
      }
    }
    return out;
  }

  static Set<String> _readStringSet(Object? raw) {
    if (raw is! List) return const <String>{};
    return raw.whereType<String>().toSet();
  }

  static DashboardSort _readSort(Map<String, Object?> raw) {
    var column = const DashboardSort().column;
    var direction = const DashboardSort().direction;
    final c = raw['column'];
    if (c is String) {
      for (final candidate in DashboardSortColumn.values) {
        if (candidate.name == c) {
          column = candidate;
          break;
        }
      }
    }
    final d = raw['direction'];
    if (d is String) {
      for (final candidate in DashboardSortDirection.values) {
        if (candidate.name == d) {
          direction = candidate;
          break;
        }
      }
    }
    return DashboardSort(column: column, direction: direction);
  }
}
