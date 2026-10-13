// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:crux_license/crux_license_core.dart';
import 'package:crux_policy/crux_policy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/core/app_info/build_info.dart';
import 'package:simcrux/core/cli/cli_args.dart';
import 'package:simcrux/core/cli/license_cli.dart';
import 'package:simcrux/core/cli/simcrux_cli.dart';
import 'package:simcrux/domain/enums/hdl_language.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/test_run.dart';
import 'package:simcrux/services/ci/fail_on_regression_policy.dart';
import 'package:simcrux/services/config/config_loader.dart';
import 'package:simcrux/services/license/headless_license_tier.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';

/// Answers license validation from a table keyed by the credential text.
class _TableValidator implements LicenseValidator {
  _TableValidator(this.outcomes);

  final Map<String, LicenseValidation> outcomes;

  @override
  String get name => 'table';

  @override
  Future<LicenseValidation> validate(
    String? rawCredential, {
    DateTime? now,
    String? fingerprint,
  }) async =>
      outcomes[rawCredential?.trim()] ??
      const LicenseRejected(LicenseRejection.malformed);
}

/// An in-process [SimulatorDriver] with a scripted outcome, so `--ci`
/// runs through the whole `SimcruxCli → CiRunner → LocalJobScheduler`
/// stack without any real toolchain. Unlike [DemoSimulatorDriver]'s
/// hash-derived outcomes, the verdict here is explicit — a test that
/// wants a failure asks for one.
class _ScriptedDriver implements SimulatorDriver {
  _ScriptedDriver({this.fails = false});

  final bool fails;

  static const String kId = 'scripted';

  @override
  String get id => kId;

  @override
  String get displayName => 'Scripted test driver';

  @override
  SimulatorCapabilities get capabilities => SimulatorCapabilities(
    supportedLanguages: const {
      HdlLanguage.verilog,
      HdlLanguage.systemVerilog,
      HdlLanguage.vhdl,
    },
    supportsVcd: false,
    supportsFst: false,
    supportsCocotb: false,
    requiresSeparateCompileStep: false,
    emitsStructuredOutput: false,
  );

  @override
  Future<String?> detectVersion(SimulatorBinaryConfig config) async =>
      'scripted 1.0';

  @override
  Future<CompileResult> compile(CompileRequest request) async =>
      const CompileResult(
        success: true,
        artifactPath: 'scripted',
        stdout: '',
        stderr: '',
      );

  @override
  Stream<TestExecutionEvent> execute(ExecuteRequest request) async* {
    final startedAt = DateTime.now().toUtc();
    yield TestExecutionFinished(
      status: fails ? TestStatus.fail : TestStatus.pass,
      exitCode: fails ? 1 : 0,
      startedAt: startedAt,
      finishedAt: startedAt,
      effectiveSeed: 0,
    );
  }

  @override
  void cancel(String testId) {
    // Nothing to cancel — execute completes synchronously.
  }
}

void main() {
  late Directory tmp;
  late List<String> out;
  late List<String> err;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('simcrux-cli-');
    out = <String>[];
    err = <String>[];
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  Future<int> run(List<String> args, {SimcruxCli? cli}) =>
      (cli ?? SimcruxCli()).run(args, stdoutSink: out.add, stderrSink: err.add);

  SimcruxCli scriptedCli({bool fails = false}) => SimcruxCli(
    driverRegistry: SimulatorDriverRegistry(<String, SimulatorDriver>{
      _ScriptedDriver.kId: _ScriptedDriver(fails: fails),
    }),
  );

  String writeConfig() {
    final path = p.join(tmp.path, 'simcrux.yaml');
    File(p.join(tmp.path, 'top.v')).writeAsStringSync('module top;endmodule');
    File(path).writeAsStringSync('''
version: '1'
defaults:
  simulator: scripted
  pass_fail:
    type: exit_code
suites:
  smoke:
    sources:
      - top.v
    tests:
      - name: smoke_main
        top: top
''');
    return path;
  }

  group('SimcruxCli', () {
    test('--help prints the usage block and exits 0', () async {
      expect(await run(const ['--help']), 0);
      expect(out.join('\n'), contains('--ci'));
      expect(out.join('\n'), contains('--import-fusesoc'));
    });

    test('--version prints `simcrux <version>` and exits 0', () async {
      // The suite's headless convention, and the line the Homebrew formula's
      // test block runs against the published binary.
      expect(await run(const ['--version']), 0);
      expect(out, ['simcrux ${SimCruxBuildInfo.productVersion}']);
      expect(err, isEmpty);
    });

    test('an unknown flag exits 2 with the usage block on stderr', () async {
      expect(await run(const ['--no-such-flag']), 2);
      expect(err.join('\n'), contains('simcrux:'));
    });

    test('an invocation with nothing headless to do exits 2 rather than '
        'silently succeeding', () async {
      // The desktop app would open a window for these; a CI binary that
      // exited 0 having run nothing would be a silent false-clean.
      expect(await run(const <String>[]), 2);
      expect(err.join('\n'), contains('nothing to do headless'));
    });

    test('a positional project without --ci is a GUI invocation and '
        'exits 2', () async {
      final config = writeConfig();
      expect(await run(<String>[config]), 2);
      expect(err.join('\n'), contains('nothing to do headless'));
    });

    test('the suite-shared launch recovery flags are tolerated', () async {
      // `--reset` / `--no-restore` are GUI-session flags; the binary
      // strips them exactly as bootstrap() does instead of failing the
      // strict parser on a shared shell alias.
      final config = writeConfig();
      final code = await run(
        <String>['--reset', '--ci', config],
        cli: scriptedCli(),
      );
      expect(code, 0);
    });

    test('the first-run reset flags are accepted and do nothing', () async {
      // Both are desktop-app testing aids; a shared alias that passes them
      // to the headless binary must not fail the strict parser.
      final config = writeConfig();
      final code = await run(
        <String>['--reset-eula', '--reset-telemetry-consent', '--ci', config],
        cli: scriptedCli(),
      );
      expect(code, 0);
    });

    group('--import-fusesoc', () {
      test('writes the simcrux.yaml beside the core and exits 0', () async {
        final core = File(p.join(tmp.path, 'tiny.core'))
          ..writeAsStringSync('''
CAPI=2:
name: test:lib:tiny:1.0
filesets:
  rtl:
    files:
      - top.v
    file_type: verilogSource
targets:
  sim:
    default_tool: icarus
    filesets:
      - rtl
    toplevel: top
''');
        expect(await run(<String>['--import-fusesoc', core.path]), 0);
        expect(out.first, startsWith('simcrux: wrote'));
        expect(
          File(p.join(tmp.path, 'tiny.simcrux.yaml')).existsSync(),
          isTrue,
        );
      });

      test('a broken core exits 2', () async {
        final core = File(p.join(tmp.path, 'broken.core'))
          ..writeAsStringSync('not capi2 at all');
        expect(await run(<String>['--import-fusesoc', core.path]), 2);
        expect(err.join('\n'), isNotEmpty);
      });
    });

    group('--ci', () {
      test('a passing regression exits 0 and prints the summary', () async {
        final config = writeConfig();
        final code = await run(
          <String>['--ci', config],
          cli: scriptedCli(),
        );
        expect(code, 0);
        expect(out.join('\n'), contains('1 passed'));
      });

      test('a failing regression exits non-zero', () async {
        final config = writeConfig();
        final code = await run(
          <String>['--ci', config],
          cli: scriptedCli(fails: true),
        );
        expect(code, isNot(0));
      });

      test('--export junit writes the report', () async {
        final config = writeConfig();
        final report = p.join(tmp.path, 'report.xml');
        final code = await run(
          <String>['--ci', config, '--export', 'junit=$report'],
          cli: scriptedCli(),
        );
        expect(code, 0);
        expect(File(report).existsSync(), isTrue);
        expect(
          File(report).readAsStringSync(),
          contains('<testsuites'),
        );
      });

      test('a missing config exits 2', () async {
        final code = await run(
          <String>['--ci', p.join(tmp.path, 'missing.yaml')],
          cli: scriptedCli(),
        );
        expect(code, 2);
        expect(err.join('\n'), isNotEmpty);
      });

      // The ci.md recipe is `simcrux --ci --json … | jq .totals`. The JSON
      // used to be printed first and each export's `wrote … → …` line after
      // it, on the same stream, so jq failed on the second line as soon as
      // `--export` was added.
      test(
        '--json stdout is exactly one JSON document, exports and all',
        () async {
          final config = writeConfig();
          final junit = p.join(tmp.path, 'report.xml');
          final csv = p.join(tmp.path, 'report.csv');
          final code = await run(
            <String>[
              '--ci',
              '--json',
              // Without --baseline: the gate's "skipping" warning is one more
              // line that must not land on stdout.
              '--fail-on-regression',
              config,
              '--export',
              'junit=$junit',
              '--export',
              'csv=$csv',
            ],
            cli: scriptedCli(),
          );
          expect(code, 0);
          final decoded = jsonDecode(out.join('\n'));
          expect(decoded, <String, Object?>{
            'totals': <String, Object?>{'pass': 1},
          });
          // The confirmations still happen — on stderr.
          expect(err, contains('wrote junit → $junit'));
          expect(err, contains('wrote csv → $csv'));
          expect(
            err,
            anyElement(contains('--fail-on-regression set without --baseline')),
          );
          expect(File(junit).existsSync(), isTrue);
          expect(File(csv).existsSync(), isTrue);
        },
      );

      // The standalone binary does not carry the comparison engine. A gate
      // the job asked for and did not get must not report green, so it
      // refuses with exit 2 and names the executable that does run it.
      test(
        '--fail-on-regression --baseline exits 2 and names the desktop '
        'executable on stderr',
        () async {
          final config = writeConfig();
          final baseline = File(p.join(tmp.path, 'baseline.ndjson'))
            ..writeAsStringSync('');
          final code = await run(
            <String>[
              '--ci',
              config,
              '--baseline',
              baseline.path,
              '--fail-on-regression',
              // A threshold no run reaches: only the gate can fail this job.
              '--fail-threshold',
              '999',
            ],
            cli: SimcruxCli(
              driverRegistry: SimulatorDriverRegistry(
                <String, SimulatorDriver>{
                  _ScriptedDriver.kId: _ScriptedDriver(),
                },
              ),
            ),
          );
          expect(code, 2);
          expect(out.join('\n'), contains('1 passed'));
          expect(
            err,
            anyElement(
              allOf(
                startsWith('error: regression gate: '),
                contains('SimCrux.app/Contents/MacOS/SimCrux'),
              ),
            ),
          );
        },
      );

      test(
        'an unknown --export format is a usage error before any run',
        () async {
          final config = writeConfig();
          final report = p.join(tmp.path, 'report.pdf');
          final code = await run(
            <String>['--ci', config, '--export', 'pdf=$report'],
            cli: scriptedCli(),
          );
          // Exit 2, the usage-error code: it used to be skipped with a warning
          // and exit 0, a green job with no report.
          expect(code, 2);
          final message = err.join('\n');
          expect(message, contains('unknown format "pdf"'));
          expect(message, contains('Valid formats: junit, json, csv, html.'));
          expect(out, isEmpty, reason: 'nothing ran, so there is no verdict');
          expect(File(report).existsSync(), isFalse);
        },
      );
    });

    group('license tier under --ci', () {
      // A two-seed sweep. After the beta, only a Pro-equivalent tier expands
      // it; Open Core runs the test once.
      String writeSweepConfig() {
        final path = p.join(tmp.path, 'sweep.yaml');
        File(
          p.join(tmp.path, 'top.v'),
        ).writeAsStringSync('module top;endmodule');
        File(path).writeAsStringSync('''
version: '1'
defaults:
  simulator: scripted
  pass_fail:
    type: exit_code
suites:
  smoke:
    sources:
      - top.v
    tests:
      - name: sweep
        top: top
        seeds: [1, 2]
''');
        return path;
      }

      SimcruxCli licensedCli({
        required Map<String, LicenseValidation> outcomes,
        required List<LicenseTier> tiersSeen,
        FailOnRegressionPolicy policy =
            const UnavailableFailOnRegressionPolicy(),
      }) => SimcruxCli(
        driverRegistry: SimulatorDriverRegistry(<String, SimulatorDriver>{
          _ScriptedDriver.kId: _ScriptedDriver(),
        }),
        failOnRegressionPolicy: policy,
        licenseTierResolver: HeadlessLicenseTierResolver(
          validator: _TableValidator(outcomes),
          environment: const <String, String>{},
          loadPolicy: () =>
              const PolicyLoadResult(document: PolicyDocument.absent),
        ),
        configLoaderFactory: (tier, {required allowTooling}) {
          tiersSeen.add(tier);
          return ConfigLoader(
            licenseTier: tier,
            // Pinned, not defaulted: this tests post-beta behaviour on purpose.
            // ignore: avoid_redundant_argument_values
            betaPeriod: false,
            allowProjectDefinedTooling: allowTooling,
          );
        },
      );

      test('a Pro --license-file expands the sweep after the beta', () async {
        final config = writeSweepConfig();
        final license = File(p.join(tmp.path, 'simcrux.lic'))
          ..writeAsStringSync('PRO');
        final tiers = <LicenseTier>[];
        final code = await run(
          <String>['--ci', config, '--license-file', license.path],
          cli: licensedCli(
            outcomes: {
              'PRO': const LicenseAccepted(
                LicenseGrant(
                  issuerId: 'test',
                  tier: LicenseTier.pro,
                  products: {CruxProduct.simCrux},
                ),
              ),
            },
            tiersSeen: tiers,
          ),
        );
        expect(code, 0);
        expect(tiers, [LicenseTier.pro]);
        expect(out.join('\n'), contains('2 passed'));
        expect(err.join('\n'), contains('license: Pro'));
      });

      test(
        'the regression policy is handed the tier the license resolved',
        () async {
          final config = writeSweepConfig();
          final license = File(p.join(tmp.path, 'simcrux.lic'))
            ..writeAsStringSync('ENT');
          final policy = _TierRecordingPolicy();
          final code = await run(
            <String>[
              '--ci',
              config,
              '--license-file',
              license.path,
              '--fail-on-regression',
              '--baseline',
              p.join(tmp.path, 'baseline.ndjson'),
            ],
            cli: licensedCli(
              outcomes: {
                'ENT': const LicenseAccepted(
                  LicenseGrant(
                    issuerId: 'test',
                    tier: LicenseTier.enterprise,
                    products: {CruxProduct.simCrux},
                  ),
                ),
              },
              tiersSeen: <LicenseTier>[],
              policy: policy,
            ),
          );
          expect(code, 0);
          expect(policy.tiers, [LicenseTier.enterprise]);
        },
      );

      test('without a license the project loads as Open Core', () async {
        final config = writeSweepConfig();
        final tiers = <LicenseTier>[];
        final code = await run(
          <String>['--ci', config],
          cli: licensedCli(outcomes: const {}, tiersSeen: tiers),
        );
        expect(code, 0);
        expect(tiers, [LicenseTier.openCore]);
        expect(out.join('\n'), contains('1 passed'));
      });

      test('an unreadable --license-file exits 2 before running', () async {
        final config = writeSweepConfig();
        final tiers = <LicenseTier>[];
        final code = await run(
          <String>[
            '--ci',
            config,
            '--license-file',
            p.join(tmp.path, 'nope.lic'),
          ],
          cli: licensedCli(outcomes: const {}, tiersSeen: tiers),
        );
        expect(code, 2);
        expect(tiers, isEmpty, reason: 'nothing was loaded or run');
        expect(err.join('\n'), contains('nope.lic'));
      });
    });

    group('--allow-project-tooling', () {
      // End to end: the flag the user typed is what the loader the CI run
      // uses is built with. Without it, `simulators.<id>.path` / `.env`
      // and the `riscv.*.command` argv lists in the project file are
      // refused — see `AppSettings.allowProjectDefinedTooling`.
      String writeToolingConfig() {
        final path = p.join(tmp.path, 'tooling.yaml');
        File(
          p.join(tmp.path, 'top.v'),
        ).writeAsStringSync('module top;endmodule');
        File(path).writeAsStringSync('''
version: '1'
defaults:
  simulator: scripted
  pass_fail:
    type: exit_code
simulators:
  scripted:
    source: custom
    path: /tmp/pwn
    env:
      LD_PRELOAD: ./pwn.so
suites:
  smoke:
    sources:
      - top.v
    tests:
      - name: t
        top: top
''');
        return path;
      }

      SimcruxCli recordingCli(List<bool> seen) => SimcruxCli(
        driverRegistry: SimulatorDriverRegistry(<String, SimulatorDriver>{
          _ScriptedDriver.kId: _ScriptedDriver(),
        }),
        configLoaderFactory: (tier, {required allowTooling}) {
          seen.add(allowTooling);
          return ConfigLoader(
            licenseTier: tier,
            allowProjectDefinedTooling: allowTooling,
          );
        },
      );

      test('absent → the loader refuses the project file tooling', () async {
        final seen = <bool>[];
        final code = await run(
          <String>['--ci', writeToolingConfig()],
          cli: recordingCli(seen),
        );
        expect(code, 0);
        expect(seen, [false]);
      });

      test('present → the loader honors it', () async {
        final seen = <bool>[];
        final code = await run(
          <String>['--ci', '--allow-project-tooling', writeToolingConfig()],
          cli: recordingCli(seen),
        );
        expect(code, 0);
        expect(seen, [true]);
      });
    });

    group('license', () {
      // The shared fingerprint file lives under the account's data
      // directory; rooted in the temp dir so no test touches the real one.
      Map<String, String> env() => <String, String>{
        'HOME': tmp.path,
        'APPDATA': tmp.path,
        'LOCALAPPDATA': tmp.path,
        'XDG_DATA_HOME': tmp.path,
      };
      SimcruxCli licenseCli() => SimcruxCli(
        licenseCli: LicenseCli(
          environment: env(),
          machineName: () => 'agent-7',
          platform: 'linux',
        ),
      );

      test('fingerprint prints the shared install fingerprint, minting it '
          'once', () async {
        expect(await run(['license', 'fingerprint'], cli: licenseCli()), 0);
        expect(err, isEmpty);
        final first = out.single;
        expect(first, matches(RegExp(r'^[A-Za-z0-9_-]{16,256}$')));

        out.clear();
        expect(await run(['license', 'fingerprint'], cli: licenseCli()), 0);
        expect(
          out.single,
          first,
          reason: 'recorded in the shared file, so a second run reads it back',
        );
        // The same value `--ci` presents when it validates a machine file.
        expect(
          await SharedInstallFingerprint(environment: env()).readOrCreate(),
          first,
        );
      });

      test('request --out writes the offline activation request', () async {
        final outPath = p.join(tmp.path, 'agent.json');
        expect(
          await run([
            'license',
            'request',
            '--out',
            outPath,
          ], cli: licenseCli()),
          0,
        );
        expect(out, ['simcrux: wrote $outPath']);
        final doc =
            jsonDecode(File(outPath).readAsStringSync())
                as Map<String, Object?>;
        expect(doc['kind'], 'crux.offline-activation-request/v1');
        expect(doc['product'], CruxProduct.simCrux.entitlementCode);
        expect(doc['machine'], 'agent-7');
        expect(doc['platform'], 'linux');

        out.clear();
        expect(await run(['license', 'fingerprint'], cli: licenseCli()), 0);
        expect(doc['fingerprint'], out.single);
      });

      test('a usage error exits 2 with the usage block', () async {
        expect(await run(['license'], cli: licenseCli()), 2);
        expect(err.join('\n'), contains('Usage: simcrux license'));

        err.clear();
        expect(await run(['license', 'request'], cli: licenseCli()), 2);
        expect(err.join('\n'), contains('--out'));

        err.clear();
        expect(await run(['license', 'revoke'], cli: licenseCli()), 2);
        expect(err.join('\n'), contains('unknown command'));
        expect(out, isEmpty);
      });
    });

    test('defaultDriverRegistry carries the six built-in drivers', () {
      final registry = SimcruxCli.defaultDriverRegistry();
      for (final id in const [
        'icarus',
        'verilator',
        'ghdl',
        'cocotb',
        'riscv_arch',
        'riscv_formal',
      ]) {
        expect(registry.driverFor(id), isNotNull, reason: id);
      }
    });
  });
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
