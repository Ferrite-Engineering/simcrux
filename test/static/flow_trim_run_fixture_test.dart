// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// tool/flow/trim_run_fixture.py on a synthetic LibreLane run directory: what
// it keeps, what becomes a placeholder, what it drops, what it scrubs, and
// what it refuses.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _tool = 'tool/flow/trim_run_fixture.py';

String get _python => Platform.isWindows ? 'python' : 'python3';

void main() {
  late Directory work;
  late Directory run;

  void put(String rel, String content) {
    final f = File('${run.path}/$rel');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  ProcessResult trim(String out, [List<String> extra = const []]) =>
      Process.runSync(_python, [
        '-I',
        _tool,
        run.path,
        out,
        '--scrub',
        '${work.path}=<work>',
        ...extra,
      ]);

  setUp(() {
    work = Directory.systemTemp.createTempSync('trim_run_fixture_');
    run = Directory('${work.path}/runs/tag')..createSync(recursive: true);
    put('resolved.json', '{"DESIGN_DIR": "${work.path}/design"}');
    put(
      'flow.log',
      "Running 'Yosys.Synthesis' at 'runs/tag/06-yosys-synthesis'\n",
    );
    put('error.log', '');
    put('06-yosys-synthesis/top.nl.v', 'module top(); endmodule\n');
    put('06-yosys-synthesis/top.nl.v.json', '{"modules": {}}');
    put('06-yosys-synthesis/state_out.json', '{}');
    put('13-openroad-floorplan/top.odb', 'binary-ish');
    put('13-openroad-floorplan/top.nl.v', 'module top(); endmodule\n');
    put('13-openroad-floorplan/_env.tcl', 'set ::env(X) 1\n');
    put('31-openroad-stamidpnr/nom_tt/max.rpt', 'Startpoint: a\n');
    put('31-openroad-stamidpnr/nom_tt/wns.max.rpt', 'wns 0\n');
    put('55-openroad-stapostpnr/nom_tt/max.rpt', 'Startpoint: a\n');
    put('55-openroad-stapostpnr/max_ss/max.rpt', 'Startpoint: b\n');
    put('55-openroad-stapostpnr/max_ss/wns.max.rpt', 'wns 0\n');
    put('final/metrics.json', '{"timing__setup__ws": 1}');
    put('final/gds/top.gds', 'gds');
    put('final/nl/top.nl.v', 'module top(); endmodule\n');
    put('tmp/scratch.lib', 'library');
    File(
      '${run.path}/13-openroad-floorplan/blob.bin',
    ).writeAsBytesSync([0, 1, 2, 0]);
  });

  tearDown(() => work.deleteSync(recursive: true));

  test('keeps records, empties views, drops tmp, scrubs paths', () {
    final out = '${work.path}/out';
    final result = trim(out);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    String read(String rel) => File('$out/$rel').readAsStringSync();
    int size(String rel) => File('$out/$rel').lengthSync();

    expect(read('06-yosys-synthesis/top.nl.v.json'), '{"modules": {}}');
    expect(size('06-yosys-synthesis/top.nl.v'), greaterThan(0));
    expect(size('final/nl/top.nl.v'), greaterThan(0));
    expect(read('final/metrics.json'), contains('timing__setup__ws'));
    expect(read('31-openroad-stamidpnr/nom_tt/wns.max.rpt'), 'wns 0\n');
    expect(size('55-openroad-stapostpnr/max_ss/max.rpt'), greaterThan(0));

    for (final placeholder in [
      '13-openroad-floorplan/top.odb',
      '13-openroad-floorplan/top.nl.v',
      '13-openroad-floorplan/_env.tcl',
      '13-openroad-floorplan/blob.bin',
      '31-openroad-stamidpnr/nom_tt/max.rpt',
      'final/gds/top.gds',
    ]) {
      expect(size(placeholder), 0, reason: placeholder);
    }
    expect(Directory('$out/tmp').existsSync(), isFalse);
    expect(read('resolved.json'), isNot(contains(work.path)));
    expect(read('resolved.json'), contains('"DESIGN_DIR"'));

    final manifest = jsonDecode(read('TRIMMED.json')) as Map<String, dynamic>;
    final removed = (manifest['removed'] as List<dynamic>)
        .cast<Map<String, dynamic>>();
    expect(
      removed.map((r) => r['path']),
      containsAll(['tmp/scratch.lib', 'final/gds/top.gds']),
    );
    final gds = removed.firstWhere((r) => r['path'] == 'final/gds/top.gds');
    expect(gds['action'], 'placeholder');
    expect(gds['bytes'], 3);
    expect(gds['sha256'], matches(RegExp(r'^[0-9a-f]{64}$')));
    // The run directory itself is untouched.
    expect(File('${run.path}/final/gds/top.gds').lengthSync(), 3);
    expect(File('${run.path}/tmp/scratch.lib').existsSync(), isTrue);
  });

  test('--keep-corner keeps only the listings of the matching corners', () {
    final out = '${work.path}/out';
    final result = trim(out, ['--keep-corner', 'nom_t*']);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(
      File('$out/55-openroad-stapostpnr/nom_tt/max.rpt').lengthSync(),
      greaterThan(0),
    );
    expect(File('$out/55-openroad-stapostpnr/max_ss/max.rpt').lengthSync(), 0);
    expect(
      File('$out/55-openroad-stapostpnr/max_ss/wns.max.rpt').lengthSync(),
      greaterThan(0),
    );
  });

  test('--no-final-views empties the text views under final/', () {
    final out = '${work.path}/out';
    final result = trim(out, ['--no-final-views']);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(File('$out/final/nl/top.nl.v').lengthSync(), 0);
    expect(File('$out/final/metrics.json').lengthSync(), greaterThan(0));
  });

  test('fails on a kept file over the size limit', () {
    put('flow.log', 'x' * 2048);
    final result = trim('${work.path}/out', ['--max-bytes', '1024']);
    expect(result.exitCode, 1);
    expect('${result.stderr}', contains('flow.log'));
  });

  test('refuses an existing output and an output inside the run', () {
    Directory('${work.path}/exists').createSync();
    expect(trim('${work.path}/exists').exitCode, 64);
    expect(trim('${run.path}/inside').exitCode, 64);
  });
}
