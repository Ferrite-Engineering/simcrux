// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/core/cli/flow_cli.dart';
import 'package:simcrux/core/cli/flow_exit_code.dart';
import 'package:simcrux/core/cli/flow_signal_reaper.dart';
import 'package:simcrux/core/cli/simcrux_cli.dart';
import 'package:simcrux/domain/enums/hdl_language.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/services/flow/flow_metric_keys.dart';
import 'package:simcrux/services/flow/librelane_flow_driver.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';

import '../../services/flow/flow_fakes.dart';
import '../../services/flow/librelane_run_builder.dart';

/// `simcrux flow`: the exit-code table, one test per code, help first, the
/// version held to the pubspec, results on stdout and diagnostics on
/// stderr, and the nextpnr WNS derivation named in `--json`.
void main() {
  const fixtures = 'verification/fixtures/flow/nextpnr';
  late Directory tmp;
  late List<String> out;
  late List<String> err;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('flow_cli_');
    out = <String>[];
    err = <String>[];
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  FlowCli cli({
    SimulatorDriverRegistry? registry,
    FlowSignalReaper Function()? reaper,
  }) => FlowCli(
    stdoutSink: out.add,
    stderrSink: err.add,
    driverRegistry: registry ?? SimulatorDriverRegistry(const {}),
    signalReaper: reaper,
    currentDirectory: () => tmp.path,
  );

  /// A run directory holding a copy of a fixture's report.
  String runOf(String fixture) {
    final dir = Directory(p.join(tmp.path, fixture))..createSync();
    File('$fixtures/$fixture/report.json').copySync(
      p.join(dir.path, 'report.json'),
    );
    return dir.path;
  }

  group('help first, version, usage', () {
    test(
      '-h anywhere prints usage on stdout and exits 0 before any work',
      () async {
        for (final args in [
          ['-h'],
          ['--help'],
          ['gate', '--bogus', '-h'],
          ['run', '/no/such/project.yaml', '--help'],
        ]) {
          out.clear();
          expect(await cli().run(args), FlowExitCode.met, reason: '$args');
          expect(out.join('\n'), contains('Usage: simcrux flow'));
        }
        expect(err, isEmpty);
      },
    );

    test(
      '--version prints the name as typed and the pubspec version',
      () async {
        final pubspec = File('pubspec.yaml').readAsStringSync();
        final version = RegExp(
          r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)',
          multiLine: true,
        ).firstMatch(pubspec)!.group(1);
        expect(await cli().run(['--version']), FlowExitCode.met);
        expect(out.single, 'simcrux $version');
        final renamed = FlowCli(
          stdoutSink: out.add,
          stderrSink: err.add,
          driverRegistry: SimulatorDriverRegistry(const {}),
          programName: 'simcrux-1.2',
        );
        out.clear();
        await renamed.run(['--version']);
        expect(out.single, 'simcrux-1.2 $version');
      },
    );

    test('the whole binary routes flow and answers --help with 0', () async {
      final lines = <String>[];
      final code = await SimcruxCli().run(
        ['flow', '--help'],
        stdoutSink: lines.add,
        stderrSink: lines.add,
      );
      expect(code, 0);
      expect(lines.join('\n'), contains('--fail-on-wns'));
    });
  });

  group('the exit-code table', () {
    test('0 met: a met report with no thresholds', () async {
      expect(await cli().run(['gate', runOf('path_ice40_met')]), 0);
      expect(out.last, contains('met'));
    });

    test('1 violated: a violated report with no thresholds', () async {
      expect(await cli().run(['gate', runOf('path_ice40_violated')]), 1);
    });

    test('0 met: thresholds decide instead of the verdict', () async {
      // The violated fixture missed 1000 MHz but reached well over 50.
      expect(
        await cli().run([
          'gate',
          runOf('path_ice40_violated'),
          '--fail-on-fmax-below',
          '50',
        ]),
        0,
      );
    });

    test('1 violated: a failed threshold', () async {
      expect(
        await cli().run([
          'gate',
          runOf('path_ice40_met'),
          '--fail-on',
          'fmax__achieved__mhz<5000',
        ]),
        1,
      );
    });

    test('2 couldNotEvaluate: a run directory with no report', () async {
      final empty = Directory(p.join(tmp.path, 'empty'))..createSync();
      File(p.join(empty.path, 'pnr.log')).writeAsStringSync('Info: nothing\n');
      expect(await cli().run(['gate', empty.path]), 2);
    });

    test('2 couldNotEvaluate: a stopped LibreLane run', () async {
      final run = LibreLaneRunBuilder(tmp.path)
        ..step('yosys-synthesis', complete: false);
      expect(await cli().run(['gate', run.root]), 2);
    });

    test(
      '2 couldNotEvaluate: a threshold whose metric the run lacks',
      () async {
        expect(
          await cli().run([
            'gate',
            runOf('path_ice40_met'),
            '--fail-on-hold-wns',
            '0',
          ]),
          2,
        );
      },
    );

    test('3 orgThresholdViolated is in the table, labelled', () {
      expect(FlowExitCode.orgThresholdViolated, 3);
      expect(FlowExitCode.labelFor(3), 'org_threshold_violated');
    });

    test('64 usage: unknown subcommand, unknown flag, missing path, bad '
        '--fail-on', () async {
      expect(await cli().run(['frobnicate']), 64);
      expect(await cli().run(['gate', runOf('path_ice40_met'), '--bogus']), 64);
      expect(await cli().run(['gate', p.join(tmp.path, 'missing')]), 64);
      expect(
        await cli().run(['gate', runOf('path_ecp5_met'), '--fail-on', 'x~3']),
        64,
      );
      expect(await cli().run(['export', runOf('path_gowin_met')]), 64);
      expect(err, isNotEmpty);
      expect(out, isEmpty, reason: 'diagnostics go to stderr');
    });

    test('65 dataErr: a report that exists but cannot be converted', () async {
      final bad = Directory(p.join(tmp.path, 'bad'))..createSync();
      File(p.join(bad.path, 'report.json')).writeAsStringSync('{"fmax": [');
      expect(await cli().run(['gate', bad.path]), 65);
      expect(await cli().run(['ingest', bad.path]), 65);
    });

    test('130 and 143: a signal cancels the run and re-exits 128+N', () async {
      for (final (signal, code) in [
        (ProcessSignal.sigint, 130),
        // SIGTERM cannot be watched on Windows, so the reaper watches only
        // SIGINT there and a SIGTERM would wait forever.
        if (!Platform.isWindows) (ProcessSignal.sigterm, 143),
      ]) {
        final project = _flowProject(tmp, 'sig${signal.signalNumber}');
        final driver = _ScriptedFlowDriver(hang: true);
        final signals = StreamController<ProcessSignal>.broadcast();
        final run = cli(
          registry: SimulatorDriverRegistry({'nextpnr': driver}),
          reaper: () => FlowSignalReaper(
            watch: (s) => signals.stream.where((x) => x == s),
          ),
        ).run(['run', project]);
        while (!driver.started) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        signals.add(signal);
        expect(await run, code);
        expect(driver.cancelled, isTrue);
        await signals.close();
      }
    });

    test('every code has a label, and labelFor is total', () {
      for (final code in FlowExitCode.all) {
        expect(FlowExitCode.labelFor(code), isNot('unexpected'));
      }
      expect(FlowExitCode.labelFor(99), 'unexpected');
      expect(FlowExitCode.all, [0, 1, 2, 3, 64, 65, 77, 130, 143]);
    });

    test('the licence refusal has its own code, never the usage code', () {
      // R-P6-4: a paid verb that is refused fails the job with a named
      // outcome, so a pipeline can tell it from a wrong command line.
      expect(FlowExitCode.licenseRequired, 77);
      expect(FlowExitCode.licenseRequired, isNot(FlowExitCode.usage));
      expect(
        FlowExitCode.labelFor(FlowExitCode.licenseRequired),
        'license_required',
      );
    });
  });

  group('flow run', () {
    test('runs the entries through the drivers and exits by verdict', () async {
      final project = _flowProject(tmp, 'p');
      for (final (verdict, code) in [
        ('met', 0),
        ('violated', 1),
        ('stopped', 2),
      ]) {
        out.clear();
        final driver = _ScriptedFlowDriver(verdict: verdict);
        expect(
          await cli(
            registry: SimulatorDriverRegistry({'nextpnr': driver}),
          ).run(['run', project]),
          code,
          reason: verdict,
        );
        expect(out.first, startsWith('flow/blinky: $verdict'));
      }
    });

    test('--entry selects; an unknown entry is a usage error', () async {
      final project = _flowProject(tmp, 'q');
      final driver = _ScriptedFlowDriver();
      final registry = SimulatorDriverRegistry({'nextpnr': driver});
      expect(
        await cli(
          registry: registry,
        ).run(['run', '--entry', 'blinky', project]),
        0,
      );
      expect(
        await cli(registry: registry).run(['run', '--entry', 'nope', project]),
        64,
      );
    });

    test('a project that does not load is 65; a missing one is 64', () async {
      final bad = File(p.join(tmp.path, 'bad.yaml'))
        ..writeAsStringSync('version: "1"\nflow: {entries: [{name: x}]}\n');
      expect(await cli().run(['run', bad.path]), 65);
      expect(await cli().run(['run', p.join(tmp.path, 'none.yaml')]), 64);
    });

    test('a LibreLane entry under a path with a space is refused before '
        'launching: exit 2, the cause on stderr and in the result', () async {
      final root = Directory(p.join(tmp.path, 'Getting Started', 'proj'))
        ..createSync(recursive: true);
      Directory(p.join(root.path, 'librelane')).createSync();
      File(
        p.join(root.path, 'librelane', 'config.yaml'),
      ).writeAsStringSync('DESIGN_NAME: c\n');
      final project = File(p.join(root.path, 'simcrux.yaml'))
        ..writeAsStringSync('''
version: "1"
flow:
  entries:
    - name: counter
      kind: librelane
      config: librelane/config.yaml
      pdk: sky130A
''');
      final recorder = FlowSpawnRecorder();
      final registry = SimulatorDriverRegistry({
        'librelane': LibreLaneFlowDriver(
          launcher: recorder.launch,
          hostEnvironment: const <String, String>{},
          dockerUser: () => null,
        ),
      });
      final design = p.join(root.resolveSymbolicLinksSync(), 'librelane');

      final code = await cli(registry: registry).run(['run', project.path]);

      expect(code, FlowExitCode.couldNotEvaluate);
      expect(recorder.spawns, isEmpty);
      expect(
        err,
        contains(
          allOf(
            startsWith('simcrux flow run: counter: '),
            contains('contains a space'),
            contains('run it from a path without spaces'),
            contains(design),
          ),
        ),
      );
      expect(out.first, startsWith('flow/counter: not_run'));
      expect(
        out,
        contains(allOf(contains('contains a space'), contains(design))),
      );
      expect(out.last, 'simcrux flow: could_not_evaluate');
    });

    test('--json carries the verdict and the exit label', () async {
      final project = _flowProject(tmp, 'j');
      await cli(
        registry: SimulatorDriverRegistry({
          'nextpnr': _ScriptedFlowDriver(verdict: 'violated'),
        }),
      ).run(['run', '--json', project]);
      final json = jsonDecode(out.join('\n')) as Map<String, dynamic>;
      expect(json['exit_label'], 'violated');
      final entry = (json['entries'] as List).single as Map<String, dynamic>;
      expect((entry['metrics'] as Map)['flow.verdict'], 'violated');
      expect(json['note'], 'Findings, not signoff.');
    });
  });

  group('gate --json, SARIF and JUnit', () {
    test('names the WNS derivation for a nextpnr run', () async {
      await cli().run(['gate', runOf('path_ice40_violated'), '--json']);
      final json = jsonDecode(out.join('\n')) as Map<String, dynamic>;
      expect(json['wns_derivation'], kNextpnrWnsDerivation);
      expect(json['wns_ns'], lessThan(0));
      expect((json['gate'] as Map)['exit_label'], 'violated');
    });

    test(
      '--fail-on-wns 0 fails a negative WNS and passes a positive one',
      () async {
        expect(
          await cli().run([
            'gate',
            runOf('path_ice40_violated'),
            '--fail-on-wns',
            '0',
          ]),
          1,
        );
        expect(
          await cli().run([
            'gate',
            runOf('path_ice40_met'),
            '--fail-on-wns',
            '0',
          ]),
          0,
        );
      },
    );

    test('writes SARIF and JUnit beside the decision', () async {
      final sarif = p.join(tmp.path, 'out.sarif');
      final junit = p.join(tmp.path, 'out.xml');
      await cli().run([
        'gate',
        runOf('path_ice40_violated'),
        '--sarif',
        sarif,
        '--junit',
        junit,
      ]);
      final log = jsonDecode(File(sarif).readAsStringSync()) as Map;
      expect(log['version'], '2.1.0');
      expect(File(junit).readAsStringSync(), contains('<failure'));
    });

    test(
      'a baseline whose critical metric was better fails the gate',
      () async {
        // The met run's WNS is positive; as a baseline it is better than the
        // violated run's negative WNS.
        await cli().run([
          'export',
          runOf('path_ice40_met'),
          '--format',
          'json',
          '--out',
          p.join(tmp.path, 'base.json'),
        ]);
        expect(
          await cli().run([
            'gate',
            runOf('path_ice40_violated'),
            '--baseline',
            p.join(tmp.path, 'base.json'),
          ]),
          1,
        );
        final json = <String>[];
        await FlowCli(
          stdoutSink: json.add,
          stderrSink: err.add,
          driverRegistry: SimulatorDriverRegistry(const {}),
        ).run([
          'gate',
          runOf('path_ecp5_violated'),
          '--baseline',
          p.join(tmp.path, 'base.json'),
          '--json',
        ]);
        final gate =
            (jsonDecode(json.join('\n')) as Map<String, dynamic>)['gate']
                as Map;
        expect(
          (gate['baseline_worse'] as List).map((w) => (w as Map)['metric']),
          contains('timing__setup__wns'),
        );
      },
    );
  });

  group('export', () {
    for (final format in ['json', 'junit', 'sarif', 'html']) {
      test('--format $format writes the file', () async {
        final target = p.join(tmp.path, 'run.$format');
        expect(
          await cli().run([
            'export',
            runOf('path_ecp5_met'),
            '--format',
            format,
            '--out',
            target,
          ]),
          0,
        );
        final text = File(target).readAsStringSync();
        expect(text, isNotEmpty);
        if (format == 'html') {
          expect(text, contains('Findings, not signoff.'));
          expect(text, isNot(contains('sign-off')));
        }
      });
    }
  });

  // Only launching LibreLane is refused under a path with a space: a run
  // finished elsewhere (CI, another machine) is read wherever it lies.
  test('ingest reads a finished LibreLane run under a path with a '
      'space', () async {
    final design = Directory(p.join(tmp.path, 'Getting Started', 'counter'))
      ..createSync(recursive: true);
    final run = LibreLaneRunBuilder(design.path)
      ..step('yosys-synthesis')
      ..finalMetrics(cleanMetrics);
    expect(await cli().run(['ingest', run.root]), FlowExitCode.met);
    expect(out.single, contains('librelane'));
    expect(out.single, contains(': met'));
    expect(err.where((l) => l.contains('contains a space')), isEmpty);
  });

  test('ingest lists every run under a directory of runs', () async {
    for (final name in ['path_ice40_met', 'path_ice40_violated']) {
      final dir = Directory(p.join(tmp.path, 'runs', 'adder', name))
        ..createSync(recursive: true);
      File('$fixtures/$name/report.json').copySync(
        p.join(dir.path, 'report.json'),
      );
    }
    expect(await cli().run(['ingest', p.join(tmp.path, 'runs')]), 1);
    expect(out, hasLength(2));
  });
}

/// A project with one nextpnr entry, `blinky`.
String _flowProject(Directory tmp, String name) {
  final dir = Directory(p.join(tmp.path, name))..createSync();
  File(p.join(dir.path, 'top.v')).writeAsStringSync('module top; endmodule\n');
  final file = File(p.join(dir.path, 'simcrux.yaml'))
    ..writeAsStringSync('''
version: "1"
flow:
  entries:
    - name: blinky
      kind: nextpnr
      family: ice40
      device: up5k
      package: sg48
      top: top
      sources: [top.v]
''');
  return file.path;
}

/// A flow driver that answers with a scripted verdict, or runs until
/// cancelled.
class _ScriptedFlowDriver implements SimulatorDriver {
  _ScriptedFlowDriver({this.verdict = 'met', this.hang = false});

  final String verdict;
  final bool hang;
  bool started = false;
  bool cancelled = false;
  final Completer<void> _cancel = Completer<void>();

  @override
  String get id => 'nextpnr';

  @override
  String get displayName => 'scripted';

  @override
  SimulatorCapabilities get capabilities => SimulatorCapabilities(
    supportedLanguages: const <HdlLanguage>{},
    supportsVcd: false,
    supportsFst: false,
    supportsCocotb: false,
    requiresSeparateCompileStep: false,
    emitsStructuredOutput: true,
  );

  @override
  Future<String?> detectVersion(SimulatorBinaryConfig config) async => null;

  @override
  Future<CompileResult> compile(CompileRequest request) async =>
      const CompileResult(
        success: true,
        artifactPath: null,
        stdout: '',
        stderr: '',
      );

  @override
  Stream<TestExecutionEvent> execute(ExecuteRequest request) async* {
    started = true;
    final now = DateTime.now().toUtc();
    if (hang) await _cancel.future;
    yield TestExecutionFinished(
      status: verdict == 'met' ? TestStatus.pass : TestStatus.fail,
      exitCode: 0,
      startedAt: now,
      finishedAt: DateTime.now().toUtc(),
      metrics: <String, String>{
        FlowMetricKeys.kind: 'nextpnr',
        FlowMetricKeys.verdict: hang ? 'stopped' : verdict,
        FlowMetricKeys.runDir: '/runs/blinky/t',
      },
    );
  }

  @override
  void cancel(String testId) {
    cancelled = true;
    if (!_cancel.isCompleted) _cancel.complete();
  }
}
