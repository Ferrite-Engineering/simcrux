// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_workspace/crux_workspace.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/dashboard_view_mode.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/features/dashboard/models/dashboard_sort.dart';
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';
import 'package:simcrux/features/workspace/services/simcrux_workspace_codec.dart';

void main() {
  const codec = SimcruxWorkspaceCodec();

  group('SimcruxWorkspaceCodec — round-trip', () {
    test('minimum payload (configPath only) round-trips intact', () {
      final original = SimcruxTabPayload(configPath: '/p/a.yaml');
      final json = codec.payloadToJson(original);
      final decoded = codec.payloadFromJson(json);
      expect(decoded, original);
    });

    test('rich payload with every chip + sort + view mode round-trips', () {
      final original = SimcruxTabPayload(
        configPath: '/p/cpu/simcrux.yaml',
        selectedTestId: 'alu/add',
        filterStatuses: const {TestStatus.fail, TestStatus.timeout},
        filterSuites: const {'alu', 'mem'},
        filterSimulators: const {'icarus', 'verilator'},
        filterTestNameSubstring: 'add',
        sort: const DashboardSort(
          column: DashboardSortColumn.duration,
        ),
        viewMode: DashboardViewMode.heatmap,
        expandedSuites: const {'alu', 'mem'},
      );
      final json = codec.payloadToJson(original);
      final decoded = codec.payloadFromJson(json);
      expect(decoded, original);
    });

    test('inspector-focused view mode round-trips', () {
      final original = SimcruxTabPayload(
        configPath: '/p/a.yaml',
        viewMode: DashboardViewMode.inspectorFocused,
      );
      final json = codec.payloadToJson(original);
      final decoded = codec.payloadFromJson(json);
      expect(decoded.viewMode, DashboardViewMode.inspectorFocused);
    });
  });

  group('SimcruxWorkspaceCodec — corrupt-file recovery', () {
    test('missing configPath falls back to empty string (placeholder tab)', () {
      final decoded = codec.payloadFromJson(const <String, Object?>{});
      expect(decoded.configPath, '');
    });

    test('non-string configPath ignored — falls back to empty string', () {
      final decoded = codec.payloadFromJson(<String, Object?>{
        'configPath': 42,
      });
      expect(decoded.configPath, '');
    });

    test('missing filter object falls back to all-empty chips', () {
      final decoded = codec.payloadFromJson(<String, Object?>{
        'configPath': '/p/a.yaml',
      });
      expect(decoded.filterStatuses, isEmpty);
      expect(decoded.filterSuites, isEmpty);
      expect(decoded.filterSimulators, isEmpty);
      expect(decoded.filterTestNameSubstring, '');
    });

    test('non-list filter values are silently ignored', () {
      final decoded = codec.payloadFromJson(<String, Object?>{
        'configPath': '/p/a.yaml',
        'filter': <String, Object?>{
          'statuses': 'not a list',
          'suites': 42,
          'simulators': null,
          'testNameSubstring': 7,
        },
      });
      expect(decoded.filterStatuses, isEmpty);
      expect(decoded.filterSuites, isEmpty);
      expect(decoded.filterSimulators, isEmpty);
      expect(decoded.filterTestNameSubstring, '');
    });

    test('unknown status / sort column / sort direction / view mode '
        'names fall back to defaults', () {
      final decoded = codec.payloadFromJson(<String, Object?>{
        'configPath': '/p/a.yaml',
        'filter': <String, Object?>{
          'statuses': ['bogus', 'fail'],
        },
        'sort': <String, Object?>{
          'column': 'bogusColumn',
          'direction': 'bogusDirection',
        },
        'viewMode': 'bogusMode',
      });
      expect(decoded.filterStatuses, const {TestStatus.fail});
      expect(decoded.sort, const DashboardSort());
      expect(decoded.viewMode, DashboardViewMode.table);
    });

    test('unknown extra payload keys are silently ignored', () {
      final decoded = codec.payloadFromJson(<String, Object?>{
        'configPath': '/p/a.yaml',
        'unknownFutureKey': {'nested': 42},
      });
      expect(decoded.configPath, '/p/a.yaml');
    });
  });

  group('SimcruxWorkspaceCodec — display name', () {
    test('non-empty configPath produces a basename', () {
      const codec = SimcruxWorkspaceCodec();
      final payload = SimcruxTabPayload(configPath: '/some/dir/cpu.yaml');
      expect(codec.displayNameFor(payload), 'cpu.yaml');
    });

    test('empty configPath produces the placeholder label', () {
      const codec = SimcruxWorkspaceCodec();
      final payload = SimcruxTabPayload(configPath: '');
      expect(codec.displayNameFor(payload), '(new tab)');
    });
  });

  group('SimcruxWorkspaceCodec — schema version', () {
    test('schemaVersion is 1 (payload shape v1)', () {
      expect(codec.schemaVersion, 1);
    });
  });

  group('SimcruxWorkspaceCodec — workspace integration', () {
    test('Workspace.fromJson round-trips a multi-tab workspace using '
        'this codec', () {
      final tab1 = WorkspaceTab<SimcruxTabPayload>(
        id: TabId.generate(),
        displayName: 'cpu.yaml',
        paneId: PaneId.generate(),
        payload: SimcruxTabPayload(
          configPath: '/p/cpu.yaml',
          selectedTestId: 'alu/add',
          filterStatuses: const {TestStatus.fail},
        ),
      );
      final tab2 = WorkspaceTab<SimcruxTabPayload>(
        id: TabId.generate(),
        displayName: 'mem.yaml',
        paneId: tab1.paneId,
        payload: SimcruxTabPayload(
          configPath: '/p/mem.yaml',
          viewMode: DashboardViewMode.heatmap,
        ),
      );
      final ws = Workspace<SimcruxTabPayload>(
        tabs: [tab1, tab2],
        panes: [WorkspacePane(id: tab1.paneId, activeTabId: tab1.id)],
        activePaneId: tab1.paneId,
      );

      final json = ws.toJson(codec);
      final decoded = Workspace<SimcruxTabPayload>.fromJson(json, codec);
      expect(decoded.tabs.length, 2);
      expect(decoded.tabs[0].payload, tab1.payload);
      expect(decoded.tabs[0].displayName, 'cpu.yaml');
      expect(decoded.tabs[1].payload, tab2.payload);
      expect(decoded.tabs[1].displayName, 'mem.yaml');
      expect(decoded.activePaneId, tab1.paneId);
    });
  });
}
