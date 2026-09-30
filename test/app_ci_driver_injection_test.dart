// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Verifies the `--ci` bootstrap path resolves its simulator-driver
// registry through the transient ProviderContainer built from
// `extraOverrides`, rather than a hardcoded set. This is the seam the
// Pro overlay (and the headless CI exit-code end-to-end test) rely on to
// inject a scripted, process-free driver into the real CLI-mode code
// path. Open-core coverage: a scripted driver injected via
// `simulatorDriverRegistryProvider` drives the run, and its failing
// outcome surfaces as the process exit code (`dart:io`'s `exitCode`).

import 'dart:io' as io;

import 'package:crux_license/crux_license_core.dart';
import 'package:crux_policy/crux_policy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/app.dart';
import 'package:simcrux/core/cli/cli_args.dart';
import 'package:simcrux/domain/enums/hdl_language.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/test_run.dart';
import 'package:simcrux/services/ci/fail_on_regression_policy.dart';
import 'package:simcrux/services/job_scheduler/job_scheduler_provider.dart';
import 'package:simcrux/services/license/headless_license_tier.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';

/// Minimal in-process [SimulatorDriver] registered as `icarus` that
/// replays a fixed pass/fail outcome without spawning any process.
class _FixedOutcomeDriver implements SimulatorDriver {
  _FixedOutcomeDriver({required this.pass, this.onExecute});

  final bool pass;
  final void Function()? onExecute;

  @override
  String get id => 'icarus';

  @override
  String get displayName => 'Fixed (ci-seam test)';

  @override
  SimulatorCapabilities get capabilities => SimulatorCapabilities(
    supportedLanguages: const {HdlLanguage.verilog},
    supportsVcd: false,
    supportsFst: false,
    supportsCocotb: false,
    requiresSeparateCompileStep: false,
    emitsStructuredOutput: false,
  );

  @override
  Future<String?> detectVersion(SimulatorBinaryConfig config) async => 'fixed';

  @override
  Future<CompileResult> compile(CompileRequest request) async =>
      const CompileResult(
        success: true,
        artifactPath: 'noop',
        stdout: '',
        stderr: '',
      );

  @override
  Stream<TestExecutionEvent> execute(ExecuteRequest request) async* {
    onExecute?.call();
    final now = DateTime.now().toUtc();
    yield TestExecutionFinished(
      status: pass ? TestStatus.pass : TestStatus.fail,
      exitCode: pass ? 0 : 1,
      startedAt: now,
      finishedAt: now.add(const Duration(milliseconds: 1)),
    );
  }

  @override
  void cancel(String testId) {}
}

Future<String> _writeConfig() async {
  final dir = await io.Directory.systemTemp.createTemp('simcrux_ci_seam_');
  addTearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });
  io.File('${dir.path}/tb.v').writeAsStringSync('module tb; endmodule\n');
  io.File('${dir.path}/simcrux.yaml').writeAsStringSync(
    "version: '1'\n"
    '\n'
    'defaults:\n'
    '  simulator: icarus\n'
    '  pass_fail:\n'
    '    type: exit_code\n'
    '  waveform:\n'
    '    capture: never\n'
    '\n'
    'suites:\n'
    '  smoke:\n'
    '    description: seam test\n'
    '    tests:\n'
    '      - name: alu\n'
    '        top: tb\n'
    '        sources:\n'
    '          - tb.v\n',
  );
  return '${dir.path}/simcrux.yaml';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('--ci resolves the driver registry from extraOverrides '
      '(injected failing driver → exit 1)', () async {
    final configPath = await _writeConfig();
    final saved = io.exitCode;
    addTearDown(() => io.exitCode = saved);

    io.exitCode = 0;
    await bootstrap(
      args: ['--ci', configPath],
      extraOverrides: [
        simulatorDriverRegistryProvider.overrideWithValue(
          SimulatorDriverRegistry({'icarus': _FixedOutcomeDriver(pass: false)}),
        ),
      ],
    );

    expect(
      io.exitCode,
      1,
      reason:
          'the injected scripted driver failed the only test, so the '
          '--fail-threshold default (1) must surface as exit 1 — proving '
          'the override flowed into the CI scheduler',
    );
  });

  test('--ci with an injected passing driver exits 0', () async {
    final configPath = await _writeConfig();
    final saved = io.exitCode;
    addTearDown(() => io.exitCode = saved);

    io.exitCode = 0;
    await bootstrap(
      args: ['--ci', configPath],
      extraOverrides: [
        simulatorDriverRegistryProvider.overrideWithValue(
          SimulatorDriverRegistry({'icarus': _FixedOutcomeDriver(pass: true)}),
        ),
      ],
    );

    expect(io.exitCode, 0, reason: 'a clean run leaves the exit code at 0');
  });

  test(
    '--ci with an unreadable --license-file exits 2 without running',
    () async {
      final configPath = await _writeConfig();
      final saved = io.exitCode;
      addTearDown(() => io.exitCode = saved);

      io.exitCode = 0;
      var executed = false;
      await bootstrap(
        args: [
          '--ci',
          configPath,
          '--license-file',
          '${io.File(configPath).parent.path}/missing.lic',
        ],
        extraOverrides: [
          simulatorDriverRegistryProvider.overrideWithValue(
            SimulatorDriverRegistry({
              'icarus': _FixedOutcomeDriver(
                pass: true,
                onExecute: () => executed = true,
              ),
            }),
          ),
        ],
      );

      expect(
        io.exitCode,
        2,
        reason: 'the license the job asked for is missing',
      );
      expect(executed, isFalse, reason: 'the regression never started');
    },
  );

  test(
    '--ci passes --license-file to the license resolver from the container',
    () async {
      final configPath = await _writeConfig();
      final saved = io.exitCode;
      addTearDown(() => io.exitCode = saved);

      io.exitCode = 0;
      final resolver = _RecordingResolver();
      await bootstrap(
        args: ['--ci', configPath, '--license-file', '/ci/simcrux.lic'],
        extraOverrides: [
          headlessLicenseTierResolverProvider.overrideWithValue(resolver),
          simulatorDriverRegistryProvider.overrideWithValue(
            SimulatorDriverRegistry({
              'icarus': _FixedOutcomeDriver(pass: true),
            }),
          ),
        ],
      );

      expect(resolver.requestedPaths, ['/ci/simcrux.lic']);
      expect(io.exitCode, 0);
    },
  );

  test(
    '--ci hands the regression policy the tier the run resolved',
    () async {
      final configPath = await _writeConfig();
      final saved = io.exitCode;
      addTearDown(() => io.exitCode = saved);

      io.exitCode = 0;
      final policy = _TierRecordingPolicy();
      await bootstrap(
        args: [
          '--ci',
          configPath,
          '--fail-on-regression',
          '--baseline',
          '/ci/baseline.ndjson',
        ],
        extraOverrides: [
          headlessLicenseTierResolverProvider.overrideWithValue(
            _RecordingResolver(),
          ),
          failOnRegressionPolicyProvider.overrideWithValue(policy),
          simulatorDriverRegistryProvider.overrideWithValue(
            SimulatorDriverRegistry({
              'icarus': _FixedOutcomeDriver(pass: true),
            }),
          ),
        ],
      );

      expect(
        policy.tiers,
        [LicenseTier.pro],
        reason:
            'the regression gate is a paid capability; the policy that '
            'provides it has to see the tier --ci resolved, not a default',
      );
      expect(io.exitCode, 0);
    },
  );

  group('headless invocations end the process', () {
    test(
      'an unrecognized argument exits 2 instead of opening the GUI',
      () async {
        final saved = io.exitCode;
        addTearDown(() => io.exitCode = saved);
        io.exitCode = 0;
        final headless = await bootstrap(args: ['--exprot', 'junit=x.xml']);
        expect(headless, isTrue, reason: 'returned before runApp');
        expect(io.exitCode, 2);
      },
    );

    test(
      'runSimcrux exits with the --ci outcome once the run is done',
      () async {
        final configPath = await _writeConfig();
        final saved = io.exitCode;
        addTearDown(() => io.exitCode = saved);
        io.exitCode = 0;
        final exits = <int>[];
        await runSimcrux(
          args: ['--ci', configPath],
          extraOverrides: [
            simulatorDriverRegistryProvider.overrideWithValue(
              SimulatorDriverRegistry({
                'icarus': _FixedOutcomeDriver(pass: false),
              }),
            ),
          ],
          exitProcess: (code) async => exits.add(code),
        );
        expect(
          exits,
          [1],
          reason:
              'a desktop runner does not exit when main returns, so the '
              'entry point must end the process itself',
        );
      },
    );

    test('runSimcrux exits after --help', () async {
      final saved = io.exitCode;
      addTearDown(() => io.exitCode = saved);
      io.exitCode = 0;
      final exits = <int>[];
      await runSimcrux(
        args: const ['--help'],
        exitProcess: (code) async => exits.add(code),
      );
      expect(exits, [0]);
    });
  });
}

/// Records what the `--ci` path asked it to resolve, then grants Pro.
class _RecordingResolver extends HeadlessLicenseTierResolver {
  _RecordingResolver()
    : super(
        environment: const <String, String>{},
        loadPolicy: () =>
            const PolicyLoadResult(document: PolicyDocument.absent),
      );

  final List<String?> requestedPaths = <String?>[];

  @override
  Future<HeadlessLicenseResolution> resolve({String? licenseFilePath}) async {
    requestedPaths.add(licenseFilePath);
    return const HeadlessLicenseResolution(tier: LicenseTier.pro);
  }
}

/// Records the tier each regression decision was asked under, and passes.
class _TierRecordingPolicy implements FailOnRegressionPolicy {
  final List<LicenseTier> tiers = <LicenseTier>[];

  @override
  Future<FailOnRegressionDecision> shouldFailWithExitCode({
    required TestRun candidate,
    required CliArgs args,
    required LicenseTier licenseTier,
  }) async {
    tiers.add(licenseTier);
    return FailOnRegressionDecision.pass;
  }
}
