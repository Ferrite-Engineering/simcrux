// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/services/flow/gate_level/pdk_cell_models.dart';

const _hash = '8afc8346a57fe1ab7934ba5a6056ea8b43078e71';
const _fixtureRun =
    'verification/fixtures/flow/librelane/3.0.16/sky130A_met/run';

/// Lays out a ciel-style PDK tree under [base]: `ciel/sky130/versions/<hash>`
/// holding the two sky130 model files, and returns the versioned directory.
String _ciel(String base, {String manager = 'ciel'}) {
  final root = p.join(base, manager, 'sky130', 'versions', _hash);
  final dir = p.join(root, 'sky130A', 'libs.ref', 'sky130_fd_sc_hd', 'verilog');
  Directory(dir).createSync(recursive: true);
  File(p.join(dir, 'primitives.v')).writeAsStringSync('// udp\n');
  File(p.join(dir, 'sky130_fd_sc_hd.v')).writeAsStringSync('// cells\n');
  return root;
}

Map<String, Object?> _resolved(String pdkRoot) => <String, Object?>{
  'PDK': 'sky130A',
  'STD_CELL_LIBRARY': 'sky130_fd_sc_hd',
  'PDK_ROOT': pdkRoot,
  'VERILOG_POWER_DEFINE': 'USE_POWER_PINS',
  'CELL_VERILOG_MODELS': <String>[
    p.join(
      pdkRoot,
      'sky130A',
      'libs.ref',
      'sky130_fd_sc_hd',
      'verilog',
      'primitives.v',
    ),
    p.join(
      pdkRoot,
      'sky130A',
      'libs.ref',
      'sky130_fd_sc_hd',
      'verilog',
      'sky130_fd_sc_hd.v',
    ),
  ],
};

void main() {
  late Directory tmp;
  late String run;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('pdk_cell_models_');
    run = p.join(tmp.path, 'run');
    Directory(run).createSync();
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  group('resolution from the run record', () {
    test('uses the recorded models, in the recorded order', () {
      final root = _ciel(p.join(tmp.path, 'here'));
      final got = PdkCellModels.resolve(
        resolved: _resolved(root),
        runRoot: run,
        pdkRootFallback: p.join(tmp.path, 'here'),
      );
      expect(got.ok, isTrue);
      expect(got.warnings, isEmpty);
      expect(got.recordedVersion, _hash);
      expect(got.models.map(p.basename), <String>[
        'primitives.v',
        'sky130_fd_sc_hd.v',
      ]);
      expect(got.pdk, 'sky130A');
      expect(got.stdCellLibrary, 'sky130_fd_sc_hd');
      expect(got.powerDefine, 'USE_POWER_PINS');
    });

    test(
      'rebases a recorded ciel path onto this machine, without a warning',
      () {
        final elsewhere = p.join(tmp.path, 'other-machine', 'ciel', 'sky130');
        final recorded = p.join(elsewhere, 'versions', _hash);
        _ciel(p.join(tmp.path, 'mine'));
        final got = PdkCellModels.resolve(
          resolved: _resolved(recorded),
          runRoot: run,
          pdkRootFallback: p.join(tmp.path, 'mine'),
        );
        expect(got.ok, isTrue);
        expect(got.warnings, isEmpty);
        expect(
          p.isWithin(p.join(tmp.path, 'mine'), got.models.first) ||
              p.isWithin(
                File(p.join(tmp.path, 'mine')).resolveSymbolicLinksSync(),
                got.models.first,
              ),
          isTrue,
        );
      },
    );

    test('finds the same version under a volare root', () {
      final recorded = p.join(
        tmp.path,
        'gone',
        'ciel',
        'sky130',
        'versions',
        _hash,
      );
      _ciel(p.join(tmp.path, 'vol'), manager: 'volare');
      final got = PdkCellModels.resolve(
        resolved: _resolved(recorded),
        runRoot: run,
        pdkRootFallback: p.join(tmp.path, 'vol'),
      );
      expect(got.ok, isTrue);
      expect(got.warnings, isEmpty);
    });

    test('reads the home .ciel when no fallback is given', () {
      final recorded = p.join(
        tmp.path,
        'gone',
        'ciel',
        'sky130',
        'versions',
        _hash,
      );
      _ciel(p.join(tmp.path, 'home', '.ciel'));
      final got = PdkCellModels.resolve(
        resolved: _resolved(recorded),
        runRoot: run,
        home: p.join(tmp.path, 'home'),
      );
      expect(got.ok, isTrue);
    });

    test(
      'a PDK version that differs from the run is a warning, never silent',
      () {
        final recorded = p.join(
          tmp.path,
          'gone',
          'ciel',
          'sky130',
          'versions',
          _hash,
        );
        // Only the enabled PDK is installed here: `<root>/sky130A/libs.ref/...`.
        final enabled = p.join(
          tmp.path,
          'classic',
          'sky130A',
          'libs.ref',
          'sky130_fd_sc_hd',
          'verilog',
        );
        Directory(enabled).createSync(recursive: true);
        File(p.join(enabled, 'primitives.v')).writeAsStringSync('// udp\n');
        File(p.join(enabled, 'sky130_fd_sc_hd.v')).writeAsStringSync('// c\n');
        final got = PdkCellModels.resolve(
          resolved: _resolved(recorded),
          runRoot: run,
          pdkRootFallback: p.join(tmp.path, 'classic'),
        );
        expect(got.ok, isTrue);
        expect(got.warnings, <PdkModelsWarning>[
          PdkModelsWarning.versionDiffers,
        ]);
        expect(got.recordedVersion, _hash);
      },
    );

    test('missing models say which file, by base name only', () {
      final recorded = p.join(
        tmp.path,
        'gone',
        'ciel',
        'sky130',
        'versions',
        _hash,
      );
      final got = PdkCellModels.resolve(
        resolved: _resolved(recorded),
        runRoot: run,
        pdkRootFallback: p.join(tmp.path, 'empty'),
      );
      expect(got.ok, isFalse);
      expect(got.problem, PdkModelsProblem.notFound);
      expect(got.problemDetail, 'primitives.v');
      expect(got.models, isEmpty);
    });

    test('a run that records no models is not resolved from a guess', () {
      final got = PdkCellModels.resolve(
        resolved: <String, Object?>{'PDK': 'sky130A'},
        runRoot: run,
        pdkRootFallback: _ciel(p.join(tmp.path, 'here')),
      );
      expect(got.problem, PdkModelsProblem.notRecorded);
    });

    test(
      'a model that resolves outside the PDK root and the run is refused',
      () {
        final root = _ciel(p.join(tmp.path, 'here'));
        final verilog = p.join(
          root,
          'sky130A',
          'libs.ref',
          'sky130_fd_sc_hd',
          'verilog',
        );
        final outside = File(p.join(tmp.path, 'elsewhere.v'))
          ..writeAsStringSync('// not a model\n');
        final link = p.join(verilog, 'sky130_fd_sc_hd.v');
        File(link).deleteSync();
        try {
          Link(link).createSync(outside.path);
        } on FileSystemException {
          markTestSkipped('symbolic links are not available here');
          return;
        }
        final got = PdkCellModels.resolve(
          resolved: _resolved(root),
          runRoot: run,
          pdkRootFallback: p.join(tmp.path, 'here'),
        );
        expect(got.problem, PdkModelsProblem.outside);
        expect(got.problemDetail, 'sky130_fd_sc_hd.v');
      },
    );

    test('a run that names / as its PDK root cannot pull in any file', () {
      _ciel(p.join(tmp.path, 'mine'));
      final secret = File(p.join(tmp.path, 'secret', 'machine.v'))
        ..createSync(recursive: true)
        ..writeAsStringSync('// not a cell model\n');
      final got = PdkCellModels.resolve(
        resolved: <String, Object?>{
          'PDK': 'sky130A',
          'PDK_ROOT': p.rootPrefix(tmp.path),
          'CELL_VERILOG_MODELS': <String>[secret.path],
        },
        runRoot: run,
        pdkRootFallback: p.join(tmp.path, 'mine'),
      );
      expect(got.ok, isFalse);
      expect(got.models, isEmpty);
      expect(got.pdkRoot, isNull);
    });

    test('a recorded PDK root outside the user roots is never a root', () {
      // The run names a directory of its own that holds files at exactly the
      // recorded paths; the models still come from the user's own PDK.
      final theirs = _ciel(p.join(tmp.path, 'theirs'));
      final mine = _ciel(p.join(tmp.path, 'mine'));
      final got = PdkCellModels.resolve(
        resolved: _resolved(theirs),
        runRoot: run,
        pdkRootFallback: p.join(tmp.path, 'mine'),
      );
      expect(got.ok, isTrue, reason: '${got.problem}');
      final mineResolved = Directory(mine).resolveSymbolicLinksSync();
      for (final model in got.models) {
        expect(p.isWithin(mineResolved, model), isTrue, reason: model);
      }
      expect(got.pdkRoot, isNot(theirs));
    });

    test(
      'a recorded PDK root with no user root to hold it is not used',
      () {
        final theirs = _ciel(p.join(tmp.path, 'theirs'));
        final got = PdkCellModels.resolve(
          resolved: _resolved(theirs),
          runRoot: run,
          home: p.join(tmp.path, 'empty-home'),
        );
        expect(got.ok, isFalse);
        expect(got.problem, PdkModelsProblem.notFound);
      },
      skip: Platform.environment.containsKey('PDK_ROOT')
          ? 'PDK_ROOT is set in this environment'
          : false,
    );

    test('the committed LibreLane record names the fields this reads', () {
      final text = File('$_fixtureRun/resolved.json').readAsStringSync();
      final home = p.join(tmp.path, 'home');
      _ciel(p.join(home, '.ciel'));
      // Escaped for JSON: a Windows home holds backslashes.
      final escaped = jsonEncode(home);
      final resolved =
          jsonDecode(
                text.replaceAll(
                  '<home>',
                  escaped.substring(1, escaped.length - 1),
                ),
              )
              as Map<String, Object?>;
      final got = PdkCellModels.resolve(
        resolved: resolved,
        runRoot: run,
        home: home,
      );
      expect(got.ok, isTrue, reason: '${got.problem} ${got.problemDetail}');
      expect(got.recordedVersion, _hash);
      expect(got.models.map(p.basename), <String>[
        'primitives.v',
        'sky130_fd_sc_hd.v',
      ]);
      expect(got.row, same(PdkGlsTable.sky130));
    });
  });

  group('the per-PDK table', () {
    test('sky130 is measured; gf180mcuD and ihp-sg13g2 carry the banner', () {
      expect(PdkGlsTable.rowFor('sky130A').bannered, isFalse);
      expect(PdkGlsTable.rowFor('sky130B').bannered, isFalse);
      expect(PdkGlsTable.rowFor('gf180mcuD').bannered, isTrue);
      expect(PdkGlsTable.rowFor('ihp-sg13g2').bannered, isTrue);
      expect(PdkGlsTable.rowFor('ihp_sg13g2').family, 'ihp_sg13g2');
    });

    test('an unlisted PDK is simulated from its recorded models, bannered', () {
      final row = PdkGlsTable.rowFor('someother');
      expect(row.family, 'other');
      expect(row.bannered, isTrue);
      expect(PdkGlsTable.rowFor(null).family, 'other');
    });

    test('every row states where its status comes from', () {
      for (final row in PdkGlsTable.rows) {
        expect(row.provenance, contains('LibreLane'));
      }
    });
  });

  group('defines', () {
    const resolution = PdkCellModelResolution(row: PdkGlsTable.sky130);

    test('the functional netlist gets FUNCTIONAL and UNIT_DELAY=#1', () {
      expect(PdkCellModels.definesFor(resolution, powerAware: false), {
        'FUNCTIONAL': '1',
        'UNIT_DELAY': '#1',
      });
    });

    test("the power-aware netlist also gets the run's power define", () {
      expect(
        PdkCellModels.definesFor(resolution, powerAware: true).keys,
        containsAll(<String>['FUNCTIONAL', 'UNIT_DELAY', 'USE_POWER_PINS']),
      );
    });
  });
}
