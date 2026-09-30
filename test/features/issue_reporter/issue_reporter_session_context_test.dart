// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_issue_reporter/crux_issue_reporter.dart';
import 'package:crux_workspace/crux_workspace.dart' as crux;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/suite.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_run.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/dashboard/providers/regression_runner.dart';
import 'package:simcrux/features/diagnostics/providers/simulator_versions_provider.dart';
import 'package:simcrux/features/issue_reporter/providers/issue_reporter_overrides.dart';
import 'package:simcrux/features/issue_reporter/providers/issue_reporter_session_context.dart';
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';
import 'package:simcrux/features/workspace/providers/container_managers.dart';
import 'package:simcrux/features/workspace/providers/simcrux_pane_overrides.dart';
import 'package:simcrux/features/workspace/providers/simcrux_tab_overrides.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';
import 'package:simcrux/features/workspace/services/simcrux_workspace_codec.dart';

import '../../support/answered_telemetry.dart';

/// ── The private strings a realistic SimCrux session is full of ──────────
///
/// Every one of these is something a user would be horrified to find in a
/// public GitHub issue. The privacy test below builds a session containing all
/// of them and asserts none survives into the rendered Session State body.
const _projectPath = '/Users/jane/work/acme-secret-asic/simcrux.yaml';
const _sourcePath = '/Users/jane/work/acme-secret-asic/rtl/crypto_core.sv';
const _includeDir = '/Users/jane/work/acme-secret-asic/rtl/include';
const _stdoutPath = '/Users/jane/work/acme-secret-asic/.simcrux/run/out.log';
const _stderrPath = '/Users/jane/work/acme-secret-asic/.simcrux/run/err.log';
const _dumpPath = '/Users/jane/work/acme-secret-asic/.simcrux/run/dump.fst';
const _binaryOverride = '/opt/acme-internal/toolchain/bin';
const _suiteName = 'acme_crypto_regression';
const _testName = 'aes256_keyexpand_timing_leak';
const _topModule = 'tb_acme_crypto_core';
const _failureMessage =
    'ASSERTION FAILED in /Users/jane/work/acme-secret-asic/rtl/crypto_core.sv '
    'line 412 — key schedule mismatch';

/// Every private token that must not appear in the report, individually.
const _forbiddenTokens = <String>[
  _projectPath,
  _sourcePath,
  _includeDir,
  _stdoutPath,
  _stderrPath,
  _dumpPath,
  _binaryOverride,
  _suiteName,
  _testName,
  _topModule,
  _failureMessage,
  'acme',
  'Acme',
  'jane',
  'secret',
  'crypto_core',
];

RegressionConfig _populatedConfig() {
  final spec = TestSpec(
    id: '$_suiteName/$_testName',
    name: _testName,
    suiteName: _suiteName,
    simulatorId: 'verilator',
    top: _topModule,
    sources: const [_sourcePath],
    includeDirs: const [_includeDir],
    defines: const {'ACME_SECRET_WIDTH': '256'},
  );
  final spec2 = TestSpec(
    id: '$_suiteName/smoke',
    name: 'smoke',
    suiteName: _suiteName,
    simulatorId: 'icarus',
    top: _topModule,
    sources: const [_sourcePath],
  );
  return RegressionConfig(
    projectFilePath: _projectPath,
    schemaVersion: '1',
    suites: [
      Suite(name: _suiteName, tests: [spec, spec2]),
    ],
    simulatorBinaries: const {
      'verilator': SimulatorBinaryConfig(
        simulatorId: 'verilator',
        source: SimulatorBinarySource.custom,
        customPath: _binaryOverride,
      ),
    },
  );
}

RegressionRunState _completedRun() {
  final started = DateTime.utc(2026, 9, 15, 10, 30);
  return RegressionRunState(
    run: TestRun(
      id: 'run-1',
      startedAt: started,
      testIds: const ['$_suiteName/$_testName', '$_suiteName/smoke'],
      finishedAt: started.add(const Duration(minutes: 4)),
      results: [
        TestResult(
          testId: '$_suiteName/$_testName',
          runId: 'run-1',
          status: TestStatus.fail,
          startedAt: started,
          finishedAt: started.add(const Duration(minutes: 2)),
          exitCode: 1,
          stdoutPath: _stdoutPath,
          stderrPath: _stderrPath,
          waveformPath: _dumpPath,
          failureMessage: _failureMessage,
        ),
        TestResult(
          testId: '$_suiteName/smoke',
          runId: 'run-1',
          status: TestStatus.pass,
          startedAt: started,
          finishedAt: started.add(const Duration(minutes: 1)),
          exitCode: 0,
          stdoutPath: _stdoutPath,
        ),
      ],
    ),
    isFinished: true,
  );
}

/// Builds a container wired the way the app is — root + per-tab managers —
/// with one open tab holding a fully populated, path-saturated session.
Future<({ProviderContainer container, CruxIssueSessionContext session})>
_populatedSession({
  Map<String, String> versions = const {},
}) async {
  final workspaceDir = Directory.systemTemp.createTempSync(
    'issue_reporter_session_test',
  );
  addTearDown(() {
    if (workspaceDir.existsSync()) workspaceDir.deleteSync(recursive: true);
  });

  final root = ProviderContainer(
    overrides: [
      ...answeredTelemetryOverrides(),
      // Keep the workspace off path_provider: `flutter test` on Windows has no
      // registered plugin, and this test only needs a scratch directory.
      simcruxWorkspaceServiceProvider.overrideWithValue(
        crux.WorkspaceService<SimcruxTabPayload>(
          codec: const SimcruxWorkspaceCodec(),
          directoryFactory: () async => workspaceDir,
        ),
      ),
      simulatorVersionsProvider.overrideWith((ref) async => versions),
    ],
  );
  addTearDown(root.dispose);

  final managers = WorkspaceContainerManagers(
    tabs: crux.TabContainerManager(
      rootContainer: root,
      overridesFactory: root.read(simcruxTabOverridesFactoryProvider),
    ),
    panes: crux.PaneContainerManager(
      rootContainer: root,
      overridesFactory: simcruxPaneOverrides,
    ),
  );
  addTearDown(managers.dispose);

  final scoped = ProviderContainer(
    parent: root,
    overrides: [
      workspaceContainerManagersProvider.overrideWithValue(managers),
      // Same placement as bootstrap()'s scopedContainer: the contributor has
      // to materialize below the managers override to see the per-tab
      // containers at all.
      ...simcruxIssueReporterScopedOverrides,
    ],
  );
  addTearDown(scoped.dispose);

  // Resolve the (stubbed) version probe before snapshotting, so the assertions
  // see the detected versions rather than the still-loading placeholder.
  await scoped.read(simulatorVersionsProvider.future);

  final workspace = scoped.read(workspaceProvider.notifier);
  await scoped.read(workspaceProvider.future);
  await workspace.openTab(
    displayName: 'simcrux.yaml',
    payload: SimcruxTabPayload(configPath: _projectPath),
  );

  final tabId = scoped.read(workspaceProvider).value!.activeTabId!;
  final tab = managers.tabs.containerFor(tabId);
  tab.read(activeConfigProvider.notifier).replace(_populatedConfig());
  tab.read(regressionRunnerProvider.notifier).state = AsyncData(
    _completedRun(),
  );

  return (
    container: scoped,
    session: scoped.read(cruxIssueSessionContextProvider),
  );
}

/// A Windows drive prefix at a token boundary (`C:`, ` D:`), as opposed to the
/// trailing colon of the report's own markdown labels.
final _windowsDrivePrefix = RegExp(r'(^|\s)[A-Za-z]:');

/// Renders the Session State markdown exactly as the reporter dialog does.
String _renderSessionBody(CruxIssueSessionContext session) {
  const service = CruxIssueReporterService(
    config: CruxIssueReporterConfig(
      productName: 'SimCrux',
      repositorySlug: 'Ferrite-Engineering/simcrux',
    ),
  );
  return service
      .buildSessionCategory(title: 'Session State', context: session)
      .markdownBody;
}

void main() {
  // The workspace notifier reaches the services binding when it persists.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SimCrux issue-reporter session context', () {
    test(
      'PRIVACY: a Session State body carries no file paths',
      () async {
        final (:container, :session) = await _populatedSession(
          versions: const {
            'icarus': 'Icarus Verilog version 12.0 (stable)',
            'verilator': 'Verilator 5.020 2024-01-01 rev v5.020',
          },
        );
        expect(container, isNotNull);

        final body = _renderSessionBody(session);

        // Sanity: the session really is populated, so this is not a vacuous
        // pass over an empty report.
        expect(body, contains('Suites'));
        expect(body, contains('Tests'));
        expect(body, contains('verilator'));

        // 1. No path separators at all.
        expect(
          body,
          isNot(contains('/')),
          reason: 'a POSIX path separator leaked into the issue body:\n$body',
        );
        expect(
          body,
          isNot(contains(r'\')),
          reason: 'a Windows path separator leaked into the issue body:\n$body',
        );
        // 2. No Windows drive prefix. Anchored at a token boundary — the
        //    markdown labels themselves end in `:` (`**Open project tabs:**`),
        //    so a bare `[A-Za-z]:` would match the report's own formatting.
        expect(
          body,
          isNot(contains(_windowsDrivePrefix)),
          reason: 'a Windows drive prefix leaked into the issue body:\n$body',
        );

        // 3. No individual private token — paths, suite names, testbench
        //    names, top-module names, failure text.
        for (final token in _forbiddenTokens) {
          expect(
            body.toLowerCase(),
            isNot(contains(token.toLowerCase())),
            reason: '"$token" leaked into the issue body:\n$body',
          );
        }
      },
    );

    test(
      'PRIVACY: the structured attributes carry no paths either',
      () async {
        final (:container, :session) = await _populatedSession();
        expect(container, isNotNull);

        final rendered = session.attributes.toString();
        expect(rendered, isNot(contains('/')));
        expect(rendered, isNot(contains(r'\')));
        for (final token in _forbiddenTokens) {
          expect(
            rendered.toLowerCase(),
            isNot(contains(token.toLowerCase())),
            reason: '"$token" leaked into the Pro-overlay attributes',
          );
        }
      },
    );

    test('reports the counts a triager actually needs', () async {
      final (:container, :session) = await _populatedSession();
      expect(container, isNotNull);

      String valueOf(String label) =>
          session.fields.firstWhere((f) => f.label == label).value;

      expect(valueOf('Open project tabs'), '1');
      expect(valueOf('Active project'), 'loaded');
      expect(valueOf('Config schema version'), '1');
      expect(valueOf('Suites'), '1');
      expect(valueOf('Tests'), '2');
      expect(valueOf('Configured simulators'), 'icarus, verilator');
      expect(valueOf('Simulator binary overrides'), '1');
      expect(valueOf('Run state'), 'finished');
      expect(valueOf('Tests in run'), '2');
      expect(valueOf('Results recorded'), '2');
      expect(valueOf('Passed'), '1');
      expect(valueOf('Failed'), '1');
    });

    test('reports detected simulator versions', () async {
      final (:container, :session) = await _populatedSession(
        versions: const {
          'icarus': 'Icarus Verilog version 12.0 (stable)',
          'verilator': 'Verilator 5.020',
        },
      );
      expect(container, isNotNull);

      final versions = session.fields
          .firstWhere((f) => f.label == 'Detected versions')
          .value;
      expect(versions, contains('icarus Icarus Verilog version 12.0'));
      expect(versions, contains('verilator Verilator 5.020'));
    });

    test('says so when no version has been detected', () async {
      final (:container, :session) = await _populatedSession();
      expect(container, isNotNull);

      expect(
        session.fields.firstWhere((f) => f.label == 'Detected versions').value,
        kIssueSessionNotProbed,
      );
    });

    test('degrades to an empty-but-valid snapshot in a bare scope', () {
      // No workspace plumbing at all — opening the reporter must never be the
      // thing that crashes.
      final container = ProviderContainer(
        overrides: [
          ...answeredTelemetryOverrides(),
          ...simcruxIssueReporterScopedOverrides,
        ],
      );
      addTearDown(container.dispose);

      final session = container.read(cruxIssueSessionContextProvider);
      expect(session.isNotEmpty, isTrue);

      String valueOf(String label) =>
          session.fields.firstWhere((f) => f.label == label).value;
      expect(valueOf('Open project tabs'), '0');
      expect(valueOf('Active project'), '(none loaded)');
      expect(valueOf('Run state'), 'idle');

      final body = _renderSessionBody(session);
      expect(body, isNot(contains('/')));
    });
  });

  group('scrubVersionBanner', () {
    test('leaves an ordinary banner untouched', () {
      expect(
        scrubVersionBanner('Icarus Verilog version 12.0 (stable)'),
        'Icarus Verilog version 12.0 (stable)',
      );
    });

    test('redacts a POSIX install prefix a locally built toolchain prints', () {
      final scrubbed = scrubVersionBanner(
        'GHDL 4.0.0 built at /home/jane/src/ghdl/build',
      );
      expect(scrubbed, isNot(contains('/')));
      expect(scrubbed, contains('GHDL 4.0.0'));
      expect(scrubbed, contains(kIssueSessionRedacted));
    });

    test('redacts a Windows path and drive prefix', () {
      final scrubbed = scrubVersionBanner(
        r'Verilator 5.020 C:\Users\jane\tools\verilator',
      );
      expect(scrubbed, isNot(contains(r'\')));
      expect(scrubbed, isNot(contains(_windowsDrivePrefix)));
      expect(scrubbed, contains('Verilator 5.020'));
    });

    test('a wholly path-shaped banner collapses to the sentinel', () {
      expect(scrubVersionBanner('/opt/acme/bin/sim'), kIssueSessionRedacted);
      expect(scrubVersionBanner('   '), kIssueSessionRedacted);
    });

    test(
      'PRIVACY: a path-bearing banner cannot reach the report body',
      () async {
        final (:container, :session) = await _populatedSession(
          versions: const {
            'verilator':
                'Verilator 5.020 built from /Users/jane/acme/verilator',
          },
        );
        expect(container, isNotNull);

        final body = _renderSessionBody(session);
        expect(body, isNot(contains('/')));
        expect(body, contains('Verilator 5.020'));
      },
    );
  });
}
