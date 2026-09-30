// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/job_scheduler.dart';
import 'package:simcrux/domain/models/regression_request.dart';
import 'package:simcrux/services/config/config_loader.dart';
import 'package:simcrux/services/job_scheduler/local_job_scheduler.dart';
import 'package:simcrux/services/simulator/cocotb_driver.dart';
import 'package:simcrux/services/simulator/ghdl_driver.dart';
import 'package:simcrux/services/simulator/icarus_driver.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';
import 'package:simcrux/services/simulator/verilator_driver.dart';

/// Locates a binary on PATH by shelling out to `which` / `where`.
/// Returns null when the binary isn't installed.
Future<String?> _which(String binary) async {
  try {
    final cmd = Platform.isWindows ? 'where' : 'which';
    final result = await Process.run(cmd, [binary]);
    if (result.exitCode != 0) return null;
    final lines = (result.stdout as String)
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList(growable: false);
    return lines.isEmpty ? null : lines.first;
  } on Object {
    return null;
  }
}

Future<bool> _hasIverilog() async => (await _which('iverilog')) != null;
Future<bool> _hasGhdl() async => (await _which('ghdl')) != null;

/// True when this harness starts child processes translated (x86_64) on an
/// Apple Silicon host — the one host condition GHDL's fixture cannot survive.
///
/// `ghdl -e` is a two-toolchain step: GHDL's own code generator emits objects
/// for the architecture GHDL was built for, then GHDL shells out to the system
/// linker to bind them. Homebrew's `ghdl` is arm64-only, so it always runs
/// native and always emits arm64 objects; Apple's `ld` is universal, so it
/// starts in whatever architecture the spawning process prefers. When those
/// disagree, elaboration dies on "found architecture 'arm64', required
/// architecture 'x86_64'" and every test in the fixture reports `fail`.
///
/// Under `flutter test` that disagreement is real on an Apple Silicon host:
/// children of `flutter_tester` report `x86_64` from `uname -m` even though
/// the machine, the binary, and the Dart VM are all arm64 (children of a plain
/// `dart` run report `arm64`). Nothing in the pipeline under test is at fault —
/// the same three `ghdl` commands succeed from a native shell.
///
/// The other fixtures are unaffected: Icarus never links native objects, and
/// Verilator compiles *and* links through the same translated toolchain, so it
/// stays self-consistent whichever architecture it starts in.
Future<bool> _spawnsTranslatedChildren() async {
  if (!Platform.isMacOS) return false;
  final host = await Process.run('sysctl', ['-n', 'hw.optional.arm64']);
  if ((host.stdout as String).trim() != '1') return false;
  final child = await Process.run('uname', ['-m']);
  return (child.stdout as String).trim() == 'x86_64';
}

/// Gate for the two GHDL fixtures: the binary must be installed *and* the
/// harness must not be spawning translated children (see
/// [_spawnsTranslatedChildren]). Returns the skip reason, or null to run.
Future<String?> _ghdlSkipReason() async {
  if (!await _hasGhdl()) return 'ghdl not installed';
  if (await _spawnsTranslatedChildren()) {
    return 'this harness spawns translated (x86_64) children on an arm64 '
        'host, so `ghdl -e` cannot link its native arm64 objects';
  }
  return null;
}

/// Verilator's `--build` path compiles the generated model with a host
/// C++ toolchain via `make`, so the binary alone isn't enough to run
/// the fixture end-to-end — probe all three legs.
Future<bool> _hasVerilatorToolchain() async =>
    (await _which('verilator')) != null &&
    (await _which('make')) != null &&
    ((await _which('c++')) != null ||
        (await _which('g++')) != null ||
        (await _which('clang++')) != null);

/// Major version of the `verilator` on PATH, or null when it cannot be read.
Future<int?> _verilatorMajor() async {
  try {
    final r = await Process.run('verilator', ['--version']);
    final m = RegExp(r'Verilator\s+(\d+)\.').firstMatch('${r.stdout}');
    return m == null ? null : int.tryParse(m.group(1)!);
  } on ProcessException {
    return null;
  }
}

/// The cocotb fixture's Makefile run needs the Cocotb install
/// (`cocotb-config`), `make`, and the co-installed backend simulator
/// the fixture pins (`sim: icarus`) — probe all three legs.
Future<bool> _hasCocotbToolchain() async =>
    (await _which('cocotb-config')) != null &&
    (await _which('make')) != null &&
    (await _which('iverilog')) != null;

/// Runs the test fixture rooted at [fixtureDir] through the full
/// ConfigLoader → JobScheduler → driver pipeline and returns the
/// completed test ids mapped to their final status.
Future<Map<String, TestStatus>> _runFixture(String fixtureDir) async {
  final configPath = p.join(fixtureDir, 'simcrux.yaml');
  final loader = ConfigLoader();
  final config = await loader.load(configPath);
  final scheduler = LocalJobScheduler(
    driverRegistry: SimulatorDriverRegistry({
      'icarus': IcarusDriver(),
      'verilator': VerilatorDriver(),
      'ghdl': GhdlDriver(),
      'cocotb': CocotbDriver(),
    }),
    config: config,
  );
  final tests = [for (final s in config.suites) ...s.tests];
  final results = <String, TestStatus>{};
  final done = Completer<void>();
  final sub = scheduler
      .submit(
        RegressionRequest(
          runId: 'fixture-${DateTime.now().toUtc().millisecondsSinceEpoch}',
          tests: tests,
        ),
      )
      .listen(
        (event) {
          switch (event) {
            case TestFinished(:final result):
              results[result.testId] = result.status;
            case RegressionFinished():
              if (!done.isCompleted) done.complete();
            case TestStarted():
            case TestLog():
            case TestProgress():
              break;
          }
        },
      );
  await done.future;
  await sub.cancel();
  return results;
}

void _assertExpected(
  String fixtureDir,
  Map<String, TestStatus> actualByTestId,
) {
  final expectedFile = File(p.join(fixtureDir, '.expected_results.json'));
  final expectedDoc =
      jsonDecode(expectedFile.readAsStringSync()) as Map<String, dynamic>;
  final entries = (expectedDoc['tests'] as List).cast<Map<String, dynamic>>();
  for (final entry in entries) {
    final id = entry['id'] as String;
    final expectedName = entry['expected_status'] as String;
    final actual = actualByTestId[id];
    expect(
      actual,
      isNotNull,
      reason: 'Expected a result for test `$id` in fixture $fixtureDir',
    );
    expect(
      actual!.name,
      expectedName,
      reason:
          'Test `$id` in fixture $fixtureDir expected '
          '$expectedName but got ${actual.name}',
    );
  }
}

void main() {
  group('fixture pipeline', () {
    test('iverilog_pass smoke fixture reports pass end-to-end', () async {
      if (!await _hasIverilog()) {
        markTestSkipped('iverilog not installed; skipping integration fixture');
        return;
      }
      final fixture = p.normalize(
        p.absolute('test/fixtures/projects/iverilog_pass'),
      );
      final results = await _runFixture(fixture);
      _assertExpected(fixture, results);
    });

    test('iverilog_fail smoke fixture reports fail end-to-end', () async {
      if (!await _hasIverilog()) {
        markTestSkipped('iverilog not installed; skipping integration fixture');
        return;
      }
      final fixture = p.normalize(
        p.absolute('test/fixtures/projects/iverilog_fail'),
      );
      final results = await _runFixture(fixture);
      _assertExpected(fixture, results);
    });

    test(
      'verilator_pass smoke fixture reports pass end-to-end',
      () async {
        // The historical stub skipped unconditionally because
        // `--build` needs more than the verilator binary: a host C++
        // toolchain + make compile the generated model. The probe now
        // covers all three legs, so CI without the toolchain skips and
        // a dev machine with it runs the real compile → execute →
        // classify pipeline.
        if (!await _hasVerilatorToolchain()) {
          markTestSkipped(
            'verilator/make/C++ toolchain not installed; '
            'skipping integration fixture',
          );
          return;
        }
        final fixture = p.normalize(
          p.absolute('test/fixtures/projects/verilator_pass'),
        );
        final results = await _runFixture(fixture);
        _assertExpected(fixture, results);
      },
      // Verilating + compiling the C++ model is real work — allow far
      // more than the 30 s default without letting a hang run forever.
      timeout: const Timeout(Duration(minutes: 5)),
    );

    test(
      'verilator_timing: # delays, -Wall style warnings and options.args '
      'pass end-to-end on Verilator 5',
      () async {
        if (!await _hasVerilatorToolchain()) {
          markTestSkipped('verilator/make/C++ toolchain not installed');
          return;
        }
        final major = await _verilatorMajor();
        if (major == null || major < 5) {
          markTestSkipped('needs Verilator 5 or newer (found $major)');
          return;
        }
        final fixture = p.normalize(
          p.absolute('test/fixtures/projects/verilator_timing'),
        );
        final results = await _runFixture(fixture);
        _assertExpected(fixture, results);
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    test('vhdl_pass smoke fixture reports pass end-to-end (ghdl)', () async {
      if (await _ghdlSkipReason() case final reason?) {
        markTestSkipped('$reason; skipping integration fixture');
        return;
      }
      final fixture = p.normalize(
        p.absolute('test/fixtures/projects/vhdl_pass'),
      );
      final results = await _runFixture(fixture);
      _assertExpected(fixture, results);
    });

    test('vhdl_fail smoke fixture reports fail end-to-end (ghdl)', () async {
      // Gated on the same condition as vhdl_pass: a translated-child host
      // makes this fixture report `fail` for the wrong reason (a link error,
      // not the assertion the fixture is about), which is a false pass.
      if (await _ghdlSkipReason() case final reason?) {
        markTestSkipped('$reason; skipping integration fixture');
        return;
      }
      final fixture = p.normalize(
        p.absolute('test/fixtures/projects/vhdl_fail'),
      );
      final results = await _runFixture(fixture);
      _assertExpected(fixture, results);
    });

    test(
      'cocotb_dff fixture reports pass end-to-end (icarus backend)',
      () async {
        // The historical stub skipped unconditionally because the
        // Makefile run needs a co-installed backend simulator and a
        // working Cocotb Python install, not just cocotb-config + make.
        // The probe now covers the fixture's actual toolchain (the
        // fixture pins `sim: icarus`), so CI without it skips and a dev
        // machine with it runs the real make-driven compile-and-run.
        if (!await _hasCocotbToolchain()) {
          markTestSkipped(
            'cocotb-config/make/iverilog not installed; '
            'skipping integration fixture',
          );
          return;
        }
        final fixture = p.normalize(
          p.absolute('test/fixtures/projects/cocotb_dff'),
        );
        final results = await _runFixture(fixture);
        _assertExpected(fixture, results);
      },
      // The make run compiles the Icarus model and boots the Cocotb
      // Python runtime — allow far more than the 30 s default.
      timeout: const Timeout(Duration(minutes: 5)),
    );

    test(
      'mixed-language fixture loads through ConfigLoader',
      () async {
        // The mixed_language fixture exercises the config-load +
        // simulator-routing path for a Verilog + VHDL + Cocotb-Python
        // source list. Cocotb admits all three language families, so
        // ConfigLoader().load() succeeds without a mixed-language error.
        // A full Cocotb run would require the same toolchain as the
        // cocotb_dff fixture above; CI exercises only the config path.
        final fixture = p.normalize(
          p.absolute('test/fixtures/projects/mixed_language'),
        );
        final config = await ConfigLoader().load(
          p.join(fixture, 'simcrux.yaml'),
        );
        expect(config.suites.single.tests.single.name, 'mixed_smoke');
        expect(config.suites.single.tests.single.simulatorId, 'cocotb');
        expect(config.suites.single.tests.single.sources, hasLength(3));
      },
    );
  });
}
