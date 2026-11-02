// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/services/formal/vcd_top_scopes.dart';

// A SymbiYosys trace is rooted at the design the job script elaborated, with
// the solver's own signals above it. `vcdTopLevelScopes` finds that scope
// from the header alone.

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('simcrux_vcd_'));

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<List<String>> scopesOf(String vcd) {
    final file = File(p.join(dir.path, 'trace.vcd'))..writeAsStringSync(vcd);
    return vcdTopLevelScopes(file.path);
  }

  test('a formal trace: the design scope, not the signals above it', () async {
    expect(
      await scopesOf(r'''
$date today $end
$timescale 1ns $end
$var integer 32 ! smt_step $end
$var event 1 " smt_clock $end
$scope module handshake_slang $end
$var wire 1 # clk $end
$var wire 1 $ ack $end
$scope module u_core $end
$var wire 1 % busy $end
$upscope $end
$upscope $end
$enddefinitions $end
#0
1#
'''),
      <String>['handshake_slang'],
    );
  });

  test('a sibling scope at the top is kept, a nested one is not', () async {
    expect(
      await scopesOf(r'''
$scope module gold $end
$scope module inner $end
$upscope $end
$upscope $end
$scope module gate $end
$upscope $end
$enddefinitions $end
'''),
      <String>['gold', 'gate'],
    );
  });

  test(r'a variable called $procmux$12 or a comment naming a scope is not '
      'a scope', () async {
    expect(
      await scopesOf(r'''
$comment generated; see $scope module bogus $end
$scope module design $end
$var wire 1 ! $procmux$12 $end
$var wire 1 " $scope $end
$upscope $end
$enddefinitions $end
'''),
      <String>['design'],
    );
  });

  test(r'scopes declared after $enddefinitions are not read', () async {
    expect(
      await scopesOf(r'''
$scope module top $end
$upscope $end
$enddefinitions $end
$scope module late $end
'''),
      <String>['top'],
    );
  });

  test('a header split across read chunks still parses', () async {
    final vars = StringBuffer();
    for (var i = 0; i < 20000; i++) {
      vars.writeln('\$var wire 1 id$i signal_$i \$end');
    }
    expect(
      await scopesOf(
        '\$scope module big \$end\n$vars\$upscope \$end\n'
        '\$scope module second \$end\n\$upscope \$end\n'
        '\$enddefinitions \$end\n',
      ),
      <String>['big', 'second'],
    );
  });

  test(
    'a trace with no scope, an empty file and a missing file give none',
    () async {
      expect(
        await scopesOf('\$var wire 1 ! a \$end\n\$enddefinitions \$end\n'),
        isEmpty,
      );
      expect(await scopesOf(''), isEmpty);
      expect(await vcdTopLevelScopes(p.join(dir.path, 'absent.vcd')), isEmpty);
    },
  );
}
