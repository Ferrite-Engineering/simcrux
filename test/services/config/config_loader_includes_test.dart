// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/models/config_loader_error.dart';
import 'package:simcrux/services/config/config_loader.dart';
import 'package:simcrux/services/config/filelist_expander.dart';

Future<String> Function(String) _reader(Map<String, String> files) {
  // Key fixtures the same way ConfigLoader normalizes paths before reading
  // (`p.normalize(p.absolute(...))`, config_loader.dart). The fixtures are
  // written with POSIX-absolute keys (`/proj/...`); on Windows the loader
  // resolves those to drive-rooted absolute paths (`D:\proj\...`), so a raw
  // string lookup would miss. Normalizing both sides keeps the fake FS
  // OS-agnostic.
  String key(String path) => p.normalize(p.absolute(path));
  final byPath = {for (final e in files.entries) key(e.key): e.value};
  return (path) async {
    final norm = key(path);
    final body = byPath[norm];
    if (body == null) {
      throw StateError(
        'no fake entry for `$norm`. '
        'known: ${byPath.keys.join(", ")}',
      );
    }
    return body;
  };
}

/// Normalizes a POSIX-absolute fixture path the way ConfigLoader resolves
/// sources/includes, so expectations match on Windows (`/proj/...` →
/// `D:\proj\...`) as well as POSIX.
String _abs(String path) => p.normalize(p.absolute(path));

void main() {
  group('ConfigLoader.load — includes', () {
    test('appends suites from included files', () async {
      final files = {
        '/proj/simcrux.yaml': '''
version: "1"
includes:
  - common/extra.yaml

defaults:
  simulator: icarus

suites:
  cpu_unit:
    tests:
      - name: alu
        top: tb_alu
''',
        '/proj/common/extra.yaml': '''
version: "1"

suites:
  cpu_random:
    tests:
      - name: random_smoke
        top: tb_random
''',
      };
      final loader = ConfigLoader(
        readFile: _reader(files),
        filelistExpander: FilelistExpander(readFile: _reader(files)),
      );
      final config = await loader.load('/proj/simcrux.yaml');
      expect(
        config.suites.map((s) => s.name).toList(),
        containsAll(<String>['cpu_unit', 'cpu_random']),
      );
    });

    test('an included file inherits the root defaults.timeout', () async {
      final files = {
        '/proj/simcrux.yaml': '''
version: "1"
includes:
  - blocks/uart.yaml
  - blocks/spi.yaml
defaults:
  simulator: icarus
  timeout: 30s
suites:
  top:
    tests:
      - name: smoke
        top: tb_top
''',
        // No defaults.timeout of its own: inherits the root's 30 s.
        '/proj/blocks/uart.yaml': '''
version: "1"
suites:
  uart:
    tests:
      - name: loopback
        top: tb_uart
''',
        // Its own defaults.timeout wins over the root's.
        '/proj/blocks/spi.yaml': '''
version: "1"
defaults:
  timeout: 2m
suites:
  spi:
    tests:
      - name: modes
        top: tb_spi
''',
      };
      final loader = ConfigLoader(
        readFile: _reader(files),
        filelistExpander: FilelistExpander(readFile: _reader(files)),
      );
      final config = await loader.load('/proj/simcrux.yaml');
      Duration timeoutOf(String suite) =>
          config.suites.firstWhere((s) => s.name == suite).tests.single.timeout;
      expect(timeoutOf('top'), const Duration(seconds: 30));
      expect(timeoutOf('uart'), const Duration(seconds: 30));
      expect(timeoutOf('spi'), const Duration(minutes: 2));
    });

    test(
      'root file suites win over include suites with the same name',
      () async {
        final files = {
          '/proj/simcrux.yaml': '''
version: "1"
includes:
  - extra.yaml
defaults:
  simulator: icarus
suites:
  shared:
    tests:
      - name: from_root
        top: tb_root
''',
          '/proj/extra.yaml': '''
version: "1"
suites:
  shared:
    tests:
      - name: from_include
        top: tb_include
''',
        };
        final loader = ConfigLoader(
          readFile: _reader(files),
          filelistExpander: FilelistExpander(readFile: _reader(files)),
        );
        final config = await loader.load('/proj/simcrux.yaml');
        final shared = config.suites.firstWhere((s) => s.name == 'shared');
        expect(shared.tests.single.name, 'from_root');
      },
    );

    test('detects cycles in includes', () async {
      final files = {
        '/proj/a.yaml': '''
version: "1"
includes:
  - b.yaml
defaults:
  simulator: icarus
suites:
  s_a:
    tests:
      - { name: t, top: tb }
''',
        '/proj/b.yaml': '''
version: "1"
includes:
  - a.yaml
defaults:
  simulator: icarus
suites:
  s_b:
    tests:
      - { name: t, top: tb }
''',
      };
      final loader = ConfigLoader(
        readFile: _reader(files),
        filelistExpander: FilelistExpander(readFile: _reader(files)),
      );
      expect(
        () => loader.load('/proj/a.yaml'),
        throwsA(isA<ConfigLoaderException>()),
      );
    });

    test('rejects malformed includes (non-list)', () async {
      final files = {
        '/proj/simcrux.yaml': '''
version: "1"
includes: oops
defaults:
  simulator: icarus
suites:
  s:
    tests:
      - { name: t, top: tb }
''',
      };
      final loader = ConfigLoader(
        readFile: _reader(files),
        filelistExpander: FilelistExpander(readFile: _reader(files)),
      );
      expect(
        () => loader.load('/proj/simcrux.yaml'),
        throwsA(isA<ConfigLoaderException>()),
      );
    });

    test(
      'includes that pre-define simulator binaries merge into the root',
      () async {
        final files = {
          '/proj/simcrux.yaml': '''
version: "1"
includes:
  - sim.yaml
defaults:
  simulator: icarus
suites:
  s:
    tests:
      - { name: t, top: tb }
''',
          '/proj/sim.yaml': '''
version: "1"
simulators:
  icarus:
    source: system
''',
        };
        final loader = ConfigLoader(
          readFile: _reader(files),
          filelistExpander: FilelistExpander(readFile: _reader(files)),
        );
        final config = await loader.load('/proj/simcrux.yaml');
        expect(config.simulatorBinaries.containsKey('icarus'), isTrue);
        expect(
          config.simulatorBinaries['icarus']!.source.name,
          'system',
        );
      },
    );
  });

  group('ConfigLoader.load — .f filelist expansion', () {
    test('expands .f sources into individual source paths', () async {
      final files = {
        '/proj/simcrux.yaml': '''
version: "1"
defaults:
  simulator: icarus
suites:
  unit:
    tests:
      - name: alu
        top: tb_alu
        sources:
          - filelists/cpu.f
          - tb/alu_tb.v
''',
        '/proj/filelists/cpu.f': '''
rtl/alu.v
+incdir+include
+define+SIM=1
''',
      };
      final loader = ConfigLoader(
        readFile: _reader(files),
        filelistExpander: FilelistExpander(readFile: _reader(files)),
      );
      final config = await loader.load('/proj/simcrux.yaml');
      final test = config.suites.single.tests.single;
      expect(test.sources, contains(_abs('/proj/filelists/rtl/alu.v')));
      expect(test.sources, contains(_abs('/proj/tb/alu_tb.v')));
      expect(test.includeDirs, contains(_abs('/proj/filelists/include')));
      expect(test.defines['SIM'], '1');
    });

    test(
      'resolves relative sources to absolute paths under the project root',
      () async {
        final files = {
          '/proj/simcrux.yaml': '''
version: "1"
defaults:
  simulator: icarus
suites:
  unit:
    tests:
      - name: alu
        top: tb_alu
        sources:
          - rtl/alu.v
          - tb/alu_tb.v
''',
        };
        final loader = ConfigLoader(
          readFile: _reader(files),
          filelistExpander: FilelistExpander(readFile: _reader(files)),
        );
        final config = await loader.load('/proj/simcrux.yaml');
        final test = config.suites.single.tests.single;
        expect(test.sources, [
          _abs('/proj/rtl/alu.v'),
          _abs('/proj/tb/alu_tb.v'),
        ]);
      },
    );

    test('surfaces filelist errors via ConfigLoaderException', () async {
      final files = {
        '/proj/simcrux.yaml': '''
version: "1"
defaults:
  simulator: icarus
suites:
  unit:
    tests:
      - name: alu
        top: tb_alu
        sources:
          - broken.f
''',
        '/proj/broken.f': '+incdir+\n',
      };
      final loader = ConfigLoader(
        readFile: _reader(files),
        filelistExpander: FilelistExpander(readFile: _reader(files)),
      );
      expect(
        () => loader.load('/proj/simcrux.yaml'),
        throwsA(isA<ConfigLoaderException>()),
      );
    });
  });
}
