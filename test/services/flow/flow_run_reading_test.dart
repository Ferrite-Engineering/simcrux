// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:crux_flow/crux_flow.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/models/flow_config.dart';
import 'package:simcrux/services/flow/flow_metric_keys.dart';
import 'package:simcrux/services/flow/flow_run_reading.dart';

import 'librelane_run_builder.dart';

/// The run readers: nextpnr's report and log against the committed
/// fixtures (expectations from the fixtures' own hand-written
/// `verdict.expected.json`), and crux_flow's versioned LibreLane readers on
/// hand-built directories (the captured runs are read in
/// `flow_librelane_reading_test.dart`).
void main() {
  const fixtures = 'verification/fixtures/flow/nextpnr';

  test('the fixture directory exists', () {
    expect(Directory(fixtures).existsSync(), isTrue);
  });

  group('nextpnr report', () {
    for (final name in const [
      'path_ice40_met',
      'path_ice40_violated',
      'path_ecp5_met',
      'path_ecp5_violated',
      'path_gowin_met',
      'path_gowin_violated',
      'path_gatemate_met',
      'path_gatemate_violated',
      'rescreen_ice40',
      'rescreen_ecp5',
    ]) {
      test("$name: the verdict is the report's", () async {
        final expected =
            jsonDecode(
                  File(
                    '$fixtures/$name/verdict.expected.json',
                  ).readAsStringSync(),
                )
                as Map<String, dynamic>;
        final dir = p.absolute('$fixtures/$name');
        final reading = await const NextpnrRunReader().readRunDir(dir);
        expect(reading.verdict.wireName, expected['verdict']);
        expect(reading.run.ref.kind, FlowKind.nextpnr);
        expect(reading.reader, FlowReaderIds.nextpnrReport);
        expect(reading.run.ref.verified, isTrue);
        // WNS is the period slack of the worst clock: negative iff violated.
        expect(reading.wnsNs, isNotNull);
        expect(reading.wnsNs! < 0, expected['verdict'] == 'violated');
        expect(reading.wnsDerivation, kNextpnrWnsDerivation);
        expect(reading.fmaxMhz, greaterThan(0));
      });
    }

    test('the WNS derivation is 1000/constraint - 1000/achieved', () async {
      final reading = await const NextpnrRunReader().readRunDir(
        p.absolute('$fixtures/path_ice40_violated'),
      );
      final clock = reading.nextpnrReport!.clocks.single;
      expect(
        reading.wnsNs,
        closeTo(1000 / clock.constraintMhz - 1000 / clock.achievedMhz, 1e-9),
      );
      expect(reading.wnsPs, (reading.wnsNs! * 1000).round());
      expect(reading.run.metrics['timing__setup__wns'], reading.wnsNs);
    });

    test('a run directory without a report is notRun', () async {
      final dir = Directory.systemTemp.createTempSync('flow_noreport_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final reading = await const NextpnrRunReader().readRunDir(dir.path);
      expect(reading.verdict, FlowVerdict.notRun);
    });

    test('a malformed report is unrecognised, never met', () async {
      final dir = Directory.systemTemp.createTempSync('flow_badreport_');
      addTearDown(() => dir.deleteSync(recursive: true));
      File(p.join(dir.path, 'report.json')).writeAsStringSync('{"fmax": [');
      final reading = await const NextpnrRunReader().readRunDir(dir.path);
      expect(reading.verdict, FlowVerdict.unrecognised);
      expect(reading.problem, isNotNull);
    });

    test('a report that is a link out of the run is refused', () async {
      final dir = Directory.systemTemp.createTempSync('flow_linkreport_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final outside = Directory(p.join(dir.path, 'outside'))..createSync();
      final run = Directory(p.join(dir.path, 'run'))..createSync();
      File(p.join(outside.path, 'report.json')).writeAsStringSync(
        File('$fixtures/path_ice40_met/report.json').readAsStringSync(),
      );
      Link(
        p.join(run.path, 'report.json'),
      ).createSync(p.join(outside.path, 'report.json'));
      final reading = await const NextpnrRunReader().readRunDir(run.path);
      expect(reading.verdict, FlowVerdict.notRun);
      expect(reading.problem, contains('outside'));
    }, testOn: '!windows');

    test('the family names the target; without one the BELs do', () async {
      final ice40 = await const NextpnrRunReader().readRunDir(
        p.absolute('$fixtures/path_ice40_met'),
      );
      expect(ice40.target, 'ice40');
      final gowin = await const NextpnrRunReader().readRunDir(
        p.absolute('$fixtures/path_gowin_met'),
        family: NextpnrFamily.gowin,
      );
      expect(gowin.target, 'gowin');
    });
  });

  test(
    'the FuseSoC log, without a report, is read by the log reader',
    () async {
      final expected =
          jsonDecode(
                File(
                  'verification/fixtures/flow/fusesoc/verdict.expected.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final reading = await const NextpnrRunReader().readRunDir(
        p.absolute('verification/fixtures/flow/fusesoc/build'),
        logFallback: true,
      );
      expect(reading.reader, FlowReaderIds.nextpnrLog);
      expect(reading.verdict.wireName, expected['verdict']);
    },
  );

  group('LibreLane, crux_flow versioned readers (hand-built runs)', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('flow_ll_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    Future<FlowReading> read(LibreLaneRunBuilder run) =>
        const LibreLaneVersionedReader().read(run.root);

    test('complete metrics inside every check are met', () async {
      final run = LibreLaneRunBuilder(tmp.path)
        ..step('yosys-synthesis')
        ..step('openroad-stapostpnr')
        ..finalMetrics(cleanMetrics);
      final reading = await read(run);
      expect(reading.verdict, FlowVerdict.met);
      // 3.0.16 is a release the 3.0 reader is verified for.
      expect(reading.run.ref.verified, isTrue);
      expect(reading.reader, FlowReaderIds.librelane);
      expect(reading.run.ref.readerVersion, '3.0');
      expect(reading.run.toolVersions['librelane'], '3.0.16');
      expect(reading.target, 'sky130');
      expect(reading.run.steps.map((s) => s.id), [
        'yosys-synthesis',
        'openroad-stapostpnr',
      ]);
      expect(
        reading.run.steps.every((s) => s.status == FlowStepStatus.completed),
        isTrue,
      );
      expect(reading.unsupported, isNull);
      expect(reading.librelane, isNotNull);
    });

    for (final (key, value) in <(String, num)>[
      ('timing__setup_vio__count', 3),
      ('timing__hold_vio__count', 1),
      ('route__drc_errors', 1),
      ('magic__drc_error__count', 2),
      ('design__lvs_error__count', 1),
      ('route__antenna_violation__count', 4),
      ('antenna__violating__nets', 1),
      ('design__xor_difference__count', 1),
    ]) {
      test('$key past its limit is violated', () async {
        final run = LibreLaneRunBuilder(tmp.path)
          ..step('yosys-synthesis')
          ..finalMetrics(<String, Object?>{...cleanMetrics, key: value});
        expect((await read(run)).verdict, FlowVerdict.violated);
      });
    }

    test('a negative slack alone is not a violation: LibreLane checks the '
        'violation counts', () async {
      final run = LibreLaneRunBuilder(tmp.path)
        ..step('yosys-synthesis')
        ..finalMetrics(<String, Object?>{
          ...cleanMetrics,
          'timing__setup__ws': -0.12,
        });
      expect((await read(run)).verdict, FlowVerdict.met);
    });

    test('a per-corner violation folds into its base and violates', () async {
      final run = LibreLaneRunBuilder(tmp.path)
        ..step('yosys-synthesis')
        ..finalMetrics(
          <String, Object?>{
            ...cleanMetrics,
            'timing__setup__ws__corner:nom_tt_025C_1v80': 0.4,
            'timing__setup__ws__corner:max_ss_100C_1v60': -0.3,
            'timing__hold_vio__count__corner:nom_tt_025C_1v80': 0,
            'timing__hold_vio__count__corner:max_ss_100C_1v60': 2,
          }..remove('timing__setup__ws'),
        );
      final reading = await read(run);
      expect(reading.verdict, FlowVerdict.violated);
      expect(reading.run.metrics['timing__setup__ws'], -0.3);
      expect(reading.aggregatedKeys, contains('timing__setup__ws'));
    });

    test(
      'no final metrics is stopped, at the newest incomplete step',
      () async {
        final run = LibreLaneRunBuilder(tmp.path)
          ..step('yosys-synthesis')
          ..step('openroad-floorplan')
          ..step('openroad-globalplacement', complete: false);
        final reading = await read(run);
        expect(reading.verdict, FlowVerdict.stopped);
        expect(reading.stoppedStep, 'openroad-globalplacement');
        expect(reading.run.steps.last.status, FlowStepStatus.failed);
      },
    );

    test(
      'a checker without output state before later steps violates',
      () async {
        final run = LibreLaneRunBuilder(tmp.path)
          ..step('yosys-synthesis')
          ..step('checker-magicdrc', complete: false)
          ..step('misc-reportmanufacturability')
          ..finalMetrics(cleanMetrics);
        expect((await read(run)).verdict, FlowVerdict.violated);
      },
    );

    test('metrics with none of the checked metrics are unrecognised', () async {
      final run = LibreLaneRunBuilder(tmp.path)
        ..step('yosys-synthesis')
        ..finalMetrics(<String, Object?>{'design__instance__count': 100});
      expect((await read(run)).verdict, FlowVerdict.unrecognised);
    });

    test(
      'a run that states no version reads best-effort and says so',
      () async {
        final run = LibreLaneRunBuilder(tmp.path, version: null)
          ..step('yosys-synthesis')
          ..finalMetrics(cleanMetrics);
        final reading = await read(run);
        expect(reading.verdict, FlowVerdict.met);
        expect(reading.run.ref.verified, isFalse);
        expect(reading.unsupported, FlowReaderUnsupported.versionUnknown);
        expect(
          reading.toMetrics()[FlowMetricKeys.readerUnsupported],
          'version_unknown',
        );
        expect(reading.toMetrics()[FlowMetricKeys.readerVerified], 'false');
      },
    );

    test('a release outside the verified range is never verified', () async {
      for (final version in ['3.0.14', '3.0.17', '3.1.0']) {
        final run = LibreLaneRunBuilder(
          Directory(p.join(tmp.path, version)).path,
          version: version,
        )..finalMetrics(cleanMetrics);
        final reading = await read(run);
        expect(reading.run.ref.verified, isFalse, reason: version);
        expect(reading.unsupported, FlowReaderUnsupported.versionUnknown);
        expect(reading.run.toolVersions['librelane'], version);
      }
    });

    test('openlane_version is the fallback version field', () async {
      final run = LibreLaneRunBuilder(
        tmp.path,
        version: null,
        openlaneVersion: '2.2.9',
      )..finalMetrics(cleanMetrics);
      final reading = await read(run);
      expect(reading.run.toolVersions['librelane'], '2.2.9');
      expect(reading.run.ref.verified, isFalse);
    });

    test('directories that are not NN-name steps are ignored', () async {
      final run = LibreLaneRunBuilder(tmp.path)
        ..step('yosys-synthesis')
        ..finalMetrics(cleanMetrics);
      Directory(p.join(run.root, 'tmp')).createSync();
      Directory(p.join(run.root, '99 bad name')).createSync();
      final reading = await read(run);
      expect(reading.run.steps.map((s) => s.id), ['yosys-synthesis']);
    });

    test('final metrics that are a link out of the run are not read', () async {
      final outside = File(p.join(tmp.path, 'outside.json'))
        ..writeAsStringSync(jsonEncode(cleanMetrics));
      final run = LibreLaneRunBuilder(tmp.path)..step('yosys-synthesis');
      Directory(p.join(run.root, 'final')).createSync();
      Link(p.join(run.root, 'final', 'metrics.json')).createSync(outside.path);
      final reading = await read(run);
      expect(reading.verdict, isNot(FlowVerdict.met));
    }, testOn: '!windows');

    test('the target token folds PDK variants', () {
      expect(librelaneTargetToken('sky130B'), 'sky130');
      expect(librelaneTargetToken('gf180mcuD'), 'gf180mcu');
      expect(librelaneTargetToken('ihp-sg13g2'), 'ihp_sg13g2');
      expect(librelaneTargetToken('asap7'), 'other');
    });
  });
}
