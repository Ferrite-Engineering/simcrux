// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/riscv_host_platform.dart';
import 'package:simcrux/domain/enums/riscv_reference_model.dart';
import 'package:simcrux/domain/enums/riscv_run_mode.dart';
import 'package:simcrux/domain/enums/riscv_toolchain_component.dart';
import 'package:simcrux/domain/models/riscv_config.dart';
import 'package:simcrux/services/simulator/riscv_toolchain_probe.dart';

// Toolchain detection is FIRST-CLASS, GRADED behaviour, not polish. That
// means three things get asserted here:
//
//  1. the probe reports per component, because `detectVersion`'s single
//     `String?` cannot describe four independent dependencies;
//  2. every component × platform cell has actionable guidance — not
//     "not found", but what to install and where from;
//  3. where the honest answer is WSL2, the guidance SAYS WSL2 rather than
//     implying a native path we know does not work.
//
// All three platforms are covered from one runner because `platform` is
// injected — the Windows copy, which is the least likely to be exercised
// by hand, is exactly the copy that matters most.

/// Scripted stand-in for `ProcessBackedSimulatorDriver.detectVersionOf`.
class _FakeProbe {
  _FakeProbe(this.byBinary);

  /// Binary name → banner, or absent for "not installed".
  final Map<String, String> byBinary;
  final List<String> probed = <String>[];

  Future<String?> call(
    String binary, {
    List<String> versionArgs = const <String>['--version'],
  }) async {
    probed.add(binary);
    return byBinary[binary];
  }
}

void main() {
  RiscvToolchainProbe probeWith(
    _FakeProbe fake, {
    RiscvHostPlatform platform = RiscvHostPlatform.linux,
  }) => RiscvToolchainProbe(versionProbe: fake.call, platform: platform);

  group('binary resolution', () {
    test('derives the cross-compiler prefix from the ISA width', () {
      expect(
        RiscvToolchainProbe.crossCompilerBinary(
          const RiscvConfig(isa: 'rv32imc'),
        ),
        'riscv32-unknown-elf-gcc',
      );
      expect(
        RiscvToolchainProbe.crossCompilerBinary(
          const RiscvConfig(isa: 'rv64imafdc'),
        ),
        'riscv64-unknown-elf-gcc',
      );
    });

    test('honors an explicit prefix and directory', () {
      // p.equals: crossCompilerBinary joins with the host separator, so on
      // Windows this is `/opt/xpack/bin\riscv-none-elf-gcc` — the same file,
      // spelled with the platform's separator. The prefix-and-directory
      // behaviour under test is unaffected by which one it is.
      expect(
        p.equals(
          RiscvToolchainProbe.crossCompilerBinary(
            const RiscvConfig(
              toolchain: RiscvToolchainConfig(
                prefix: 'riscv-none-elf-',
                path: '/opt/xpack/bin',
              ),
            ),
          ),
          '/opt/xpack/bin/riscv-none-elf-gcc',
        ),
        isTrue,
      );
    });

    test('defaults the reference model to Spike, the easier one', () {
      expect(
        RiscvToolchainProbe.referenceModelBinary(const RiscvConfig()),
        'spike',
      );
    });

    test('picks the per-width Sail emulator', () {
      expect(
        RiscvToolchainProbe.referenceModelBinary(
          const RiscvConfig(
            isa: 'rv64i',
            reference: RiscvReferenceConfig(model: RiscvReferenceModel.sail),
          ),
        ),
        'riscv_sim_RV64',
      );
    });

    test('an explicit reference path wins over the convention', () {
      expect(
        RiscvToolchainProbe.referenceModelBinary(
          const RiscvConfig(
            reference: RiscvReferenceConfig(path: '/opt/riscv/bin/spike'),
          ),
        ),
        '/opt/riscv/bin/spike',
      );
    });
  });

  group('probe', () {
    test('reports all four components independently', () async {
      final fake = _FakeProbe({
        'riscv32-unknown-elf-gcc': 'riscv32-unknown-elf-gcc (g) 13.2.0',
        'spike': 'Spike RISC-V ISA Simulator 1.1.1-dev',
      });
      final report = await probeWith(fake).probe(
        const RiscvConfig(isa: 'rv32imc'),
      );
      expect(report.components, hasLength(4));
      expect(
        report[RiscvToolchainComponent.crossCompiler]!.found,
        isTrue,
      );
      expect(report[RiscvToolchainComponent.referenceModel]!.found, isTrue);
      expect(report[RiscvToolchainComponent.pythonRiscof]!.found, isFalse);
      expect(report[RiscvToolchainComponent.formalEngine]!.found, isFalse);
      expect(report.complete, isFalse);
      expect(report.missing, hasLength(2));
    });

    test('a found component carries its banner and no remediation', () async {
      final fake = _FakeProbe({'spike': 'Spike 1.1.1-dev'});
      final report = await probeWith(fake).probe(const RiscvConfig());
      final entry = report[RiscvToolchainComponent.referenceModel]!;
      expect(entry.version, 'Spike 1.1.1-dev');
      expect(entry.remediation, isNull);
    });

    test('a missing component carries remediation, never a bare flag', () {
      // Every cell of the 4 × 3 matrix must be actionable prose.
      for (final platform in RiscvHostPlatform.values) {
        final probe = probeWith(_FakeProbe(const {}), platform: platform);
        for (final component in RiscvToolchainComponent.values) {
          final guidance = probe.remediationFor(
            component,
            const RiscvConfig(isa: 'rv32imc'),
          );
          expect(
            guidance.length,
            greaterThan(60),
            reason:
                '${component.wireName} on ${platform.wireName} must say what '
                'to install, not just that something is missing',
          );
          expect(guidance, isNot(contains('...')));
        }
      }
    });

    test('demo mode probes nothing at all', () async {
      final fake = _FakeProbe(const {});
      final report = await probeWith(fake).probe(
        const RiscvConfig(mode: RiscvRunMode.demo, demoSignatures: 'corpus'),
      );
      expect(report.components, isEmpty);
      // The distinction that matters: SKIPPED, not probed-and-tolerated. A
      // probe that fires and is then ignored costs four spawns and invites
      // a future reader to "fix" the ignored result into a failure.
      expect(
        fake.probed,
        isEmpty,
        reason: 'demo mode spawns nothing — not even a version probe',
      );
    });
  });

  group('per-platform honesty', () {
    RiscvToolchainProbe on(RiscvHostPlatform platform) =>
        probeWith(_FakeProbe(const {}), platform: platform);

    test('Windows + Sail says WSL2 plainly and offers Spike', () {
      final guidance = on(RiscvHostPlatform.windows).remediationFor(
        RiscvToolchainComponent.referenceModel,
        const RiscvConfig(
          reference: RiscvReferenceConfig(model: RiscvReferenceModel.sail),
        ),
      );
      expect(guidance, contains('WSL2'));
      expect(guidance, contains('spike'));
      // The point: do not emit an invocation we know is broken and
      // let the user discover it through a subprocess failure at depth.
      expect(guidance, contains('not practically available'));
    });

    test('Windows + cross-compiler names WSL2 as better supported', () {
      expect(
        on(RiscvHostPlatform.windows).remediationFor(
          RiscvToolchainComponent.crossCompiler,
          const RiscvConfig(),
        ),
        contains('WSL2'),
      );
    });

    test('Windows + RISCOF does NOT say WSL2 — it works natively', () {
      final guidance = on(RiscvHostPlatform.windows).remediationFor(
        RiscvToolchainComponent.pythonRiscof,
        const RiscvConfig(),
      );
      expect(guidance, isNot(contains('WSL2')));
      expect(guidance, contains('venv'));
    });

    test('macOS guidance covers the Finder-PATH gotcha', () {
      // The suite-wide trap: an app launched from Finder inherits launchd's
      // truncated PATH, so a Homebrew install is invisible even though
      // `which` works in a terminal.
      for (final component in [
        RiscvToolchainComponent.crossCompiler,
        RiscvToolchainComponent.referenceModel,
        RiscvToolchainComponent.formalEngine,
      ]) {
        expect(
          on(RiscvHostPlatform.macos).remediationFor(
            component,
            const RiscvConfig(),
          ),
          contains('Finder'),
          reason: '${component.wireName} on macOS',
        );
      }
    });

    test('Linux guidance names concrete packages, not "install it"', () {
      expect(
        on(RiscvHostPlatform.linux).remediationFor(
          RiscvToolchainComponent.crossCompiler,
          const RiscvConfig(),
        ),
        contains('riscv64-elf-gcc'),
      );
      expect(
        on(RiscvHostPlatform.linux).remediationFor(
          RiscvToolchainComponent.formalEngine,
          const RiscvConfig(),
        ),
        contains('OSS CAD Suite'),
      );
    });

    test('optional components say they are optional', () {
      final riscof = on(RiscvHostPlatform.linux).remediationFor(
        RiscvToolchainComponent.pythonRiscof,
        const RiscvConfig(),
      );
      expect(riscof, contains('riscof_passthrough'));
      final formal = on(RiscvHostPlatform.linux).remediationFor(
        RiscvToolchainComponent.formalEngine,
        const RiscvConfig(),
      );
      expect(formal, contains('riscv-formal'));
    });

    test('no guidance ever suggests SimCrux will install anything', () {
      // We detect and guide; we never bundle and never auto-install, so
      // SimCrux conveys no third-party engine and carries none of its
      // redistribution obligations.
      for (final platform in RiscvHostPlatform.values) {
        for (final component in RiscvToolchainComponent.values) {
          final guidance = on(platform).remediationFor(
            component,
            const RiscvConfig(),
          );
          expect(guidance.toLowerCase(), isNot(contains('simcrux will')));
          expect(guidance.toLowerCase(), isNot(contains('bundled')));
        }
      }
    });
  });

  group('summaryLine', () {
    test('is null when nothing was found, matching detectVersion', () async {
      final report = await probeWith(_FakeProbe(const {})).probe(
        const RiscvConfig(),
      );
      // `SimulatorDriver.detectVersion` returns null for "not installed",
      // and the diagnostics probe simply omits the row.
      expect(report.summaryLine, isNull);
    });

    test('lists what was found and names what was not', () async {
      final report = await probeWith(
        _FakeProbe({'spike': 'Spike 1.1.1-dev'}),
      ).probe(const RiscvConfig());
      expect(report.summaryLine, contains('reference_model'));
      expect(report.summaryLine, contains('missing:'));
      expect(report.summaryLine, contains('cross_compiler'));
    });

    test('omits the missing clause when the toolchain is complete', () async {
      final report = await probeWith(
        _FakeProbe({
          'riscv32-unknown-elf-gcc': 'gcc 13.2.0',
          'spike': 'Spike 1.1.1',
          'riscof': 'riscof 1.25.3',
          'sby': 'sby 0.40',
        }),
      ).probe(const RiscvConfig(isa: 'rv32imc'));
      expect(report.complete, isTrue);
      expect(report.summaryLine, isNot(contains('missing')));
    });

    test('truncates a long banner rather than blowing out the row', () async {
      final report = await probeWith(
        _FakeProbe({'spike': 'x' * 200}),
      ).probe(const RiscvConfig());
      // The banner is clipped to 48 characters plus an ellipsis, so a
      // toolchain that prints a paragraph cannot blow out the diagnostics
      // row `detectVersion` feeds.
      expect(report.summaryLine, contains('…'));
      expect(report.summaryLine, isNot(contains('x' * 60)));
    });
  });

  group('toPlainText', () {
    test('renders every component and its remediation', () async {
      final report = await probeWith(
        _FakeProbe({'spike': 'Spike 1.1.1'}),
      ).probe(const RiscvConfig());
      final text = report.toPlainText();
      for (final component in RiscvToolchainComponent.values) {
        expect(text, contains(component.wireName));
      }
      expect(text, contains('NOT FOUND'));
      expect(text, contains('→'));
    });
  });
}
