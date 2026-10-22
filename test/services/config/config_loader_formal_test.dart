// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/config_loader_error.dart';
import 'package:simcrux/domain/models/formal_config.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/config/config_loader.dart';
import 'package:simcrux/services/simulator/eqy_driver.dart';
import 'package:simcrux/services/simulator/sby_driver.dart';

import '../../support/posix_keyed_files.dart';

// The general `formal:` block: four inheritance levels, completeness, the
// single-segment task rule, and the project-tooling gate with one test per
// key that chooses what SimCrux executes (VERIFICATION_GUIDE.md §26.8).

void main() {
  final denied = ConfigLoader();
  final allowed = ConfigLoader(allowProjectDefinedTooling: true);

  String testYaml(String formalBody, {String simulator = 'sby'}) =>
      '''
version: "1"
defaults:
  simulator: $simulator
suites:
  s:
    tests:
      - name: t
        top: t
        formal:
$formalBody
''';

  FormalConfig onlyFormal(RegressionConfig config) =>
      config.suites.single.tests.single.formal!;

  ConfigLoaderException capture(void Function() body) {
    try {
      body();
    } on ConfigLoaderException catch (e) {
      return e;
    }
    fail('Expected ConfigLoaderException');
  }

  group('reading', () {
    test('every key lands on the test', () {
      final formal = onlyFormal(
        allowed.parse(
          testYaml('''
          sby_file: proofs/fifo.sby
          task: prove
          sby_binary: /opt/sby
          command: ["{sby_file}"]
          extra_args: ["-j", 2]
          tools: { yosys: /opt/yosys }
          mode: demo
          demo_outputs: captures
          demo_case: fifo
'''),
          '/p/simcrux.yaml',
        ),
      );
      expect(formal.sbyFile, 'proofs/fifo.sby');
      expect(formal.task, 'prove');
      expect(formal.sbyBinary, '/opt/sby');
      expect(formal.command, ['{sby_file}']);
      expect(formal.extraArgs, ['-j', '2']);
      expect(formal.tools, {'yosys': '/opt/yosys'});
      expect(formal.mode, FormalRunMode.demo);
      expect(formal.demoOutputs, 'captures');
      expect(formal.demoCase, 'fifo');
    });

    test('four levels merge field by field', () async {
      final files = <String, String>{
        '/p/simcrux.yaml': '''
version: "1"
includes: [more.yaml]
defaults:
  simulator: sby
  formal: { sby_file: a.sby, mode: normal }
suites:
  s:
    formal: { task: prove }
    tests:
      - name: t
        top: t
        formal: { sby_file: b.sby }
''',
        '/p/more.yaml': '''
version: "1"
defaults:
  formal: { task: cover }
suites:
  inc:
    tests:
      - name: u
        top: u
''',
      };
      final config = await ConfigLoader(
        readFile: readFromPosixKeyed(files),
      ).load('/p/simcrux.yaml');
      final t = config.suites.firstWhere((s) => s.name == 's').tests.single;
      // The loader absolutises through package:path (`D:\p\b.sby` on
      // Windows); compare the posix form.
      expect(posixKey(t.formal!.sbyFile!), '/p/b.sby');
      expect(t.formal!.task, 'prove');
      expect(t.formal!.mode, FormalRunMode.normal);
      expect(posixKey(t.formal!.projectRoot!), '/p');
      final u = config.suites.firstWhere((s) => s.name == 'inc').tests.single;
      expect(posixKey(u.formal!.sbyFile!), '/p/a.sby', reason: 'inherited');
      expect(u.formal!.task, 'cover', reason: "the included file's own");
    });

    test('an sby test without sby_file does not load', () {
      final ex = capture(
        () => denied.parse(testYaml('          task: prove'), '/p.yaml'),
      );
      expect(
        ex.errors.map((e) => e.message),
        anyElement(contains('`formal.sby_file` is required')),
      );
    });

    test('a formal block on another simulator is inert', () {
      final config = denied.parse(
        testYaml('          task: prove', simulator: 'icarus'),
        '/p.yaml',
      );
      expect(onlyFormal(config).task, 'prove');
    });

    test('an unknown key is an error, not a silent fallback', () {
      final ex = capture(
        () => denied.parse(
          testYaml('          sby_file: a.sby\n          sby_bianry: /x'),
          '/p.yaml',
        ),
      );
      expect(
        ex.errors.map((e) => e.message),
        anyElement(contains('`formal.sby_bianry` is not a formal key')),
      );
    });

    test('an unknown tool is an error', () {
      final ex = capture(
        () => allowed.parse(
          testYaml(
            '          sby_file: a.sby\n          tools: { sh: /bin/sh }',
          ),
          '/p.yaml',
        ),
      );
      expect(
        ex.errors.map((e) => e.message),
        anyElement(contains('is not an sby tool option')),
      );
    });
  });

  group('the task names a directory sby -f deletes', () {
    for (final task in ['..', 'a/b', 'C:x', '-rf', 'a b']) {
      test('"$task" is refused at load, gate open or closed', () {
        for (final loader in [denied, allowed]) {
          final ex = capture(
            () => loader.parse(
              testYaml('          sby_file: a.sby\n          task: "$task"'),
              '/p.yaml',
            ),
          );
          expect(ex.errors.map((e) => e.message), anyElement(contains('task')));
        }
      });
    }

    for (final name in ['../x', 'a/b', '..']) {
      test('demo_case "$name" is refused', () {
        final ex = capture(
          () => denied.parse(
            testYaml(
              '          mode: demo\n          demo_outputs: d\n'
              '          demo_case: "$name"',
            ),
            '/p.yaml',
          ),
        );
        expect(
          ex.errors.map((e) => e.message),
          anyElement(contains('single directory name')),
        );
      });
    }

    test('an sby_file that reads as a flag is refused', () {
      final ex = capture(
        () => denied.parse(testYaml('          sby_file: "-d/tmp"'), '/p.yaml'),
      );
      expect(ex.errors.map((e) => e.message), anyElement(contains('flag')));
    });
  });

  group('the project-tooling gate, one test per key', () {
    test('formal.sby_binary is dropped with an advisory', () {
      final config = denied.parse(
        testYaml('          sby_file: a.sby\n          sby_binary: /tmp/pwn'),
        '/p.yaml',
      );
      expect(onlyFormal(config).sbyBinary, isNull);
      final warning = config.loadWarnings.single;
      expect(warning.severity, ConfigLoaderErrorSeverity.warning);
      expect(warning.message, contains('`formal.sby_binary`'));
      expect(warning.message, contains(kAllowProjectToolingControlLabel));
      expect(warning.message, contains('--allow-project-tooling'));
      expect(
        onlyFormal(
          allowed.parse(
            testYaml(
              '          sby_file: a.sby\n          sby_binary: /tmp/pwn',
            ),
            '/p.yaml',
          ),
        ).sbyBinary,
        '/tmp/pwn',
      );
    });

    for (final key in ['command', 'extra_args']) {
      test('formal.$key refuses the load', () {
        final body = '          sby_file: a.sby\n          $key: ["/tmp/pwn"]';
        final ex = capture(() => denied.parse(testYaml(body), '/p.yaml'));
        expect(
          ex.errors.map((e) => e.message),
          anyElement(
            allOf(
              contains('`formal.$key`'),
              contains('--allow-project-tooling'),
            ),
          ),
        );
        expect(allowed.parse(testYaml(body), '/p.yaml').loadWarnings, isEmpty);
      });
    }

    for (final tool in FormalConfig.kToolKeys) {
      test('formal.tools.$tool is dropped with an advisory', () {
        final body =
            '          sby_file: a.sby\n          tools: { $tool: /tmp/pwn }';
        final config = denied.parse(testYaml(body), '/p.yaml');
        expect(onlyFormal(config).tools, isNull);
        expect(
          config.loadWarnings.single.message,
          contains('`formal.tools.$tool`'),
        );
        expect(
          onlyFormal(allowed.parse(testYaml(body), '/p.yaml')).tools,
          {tool: '/tmp/pwn'},
        );
      });
    }

    test('every key dropped from one block is named in one advisory', () {
      final config = denied.parse(
        testYaml(
          '          sby_file: a.sby\n          sby_binary: /a\n'
          '          tools: { yosys: /b, abc: /c }',
        ),
        '/p.yaml',
      );
      expect(config.loadWarnings, hasLength(1));
      expect(
        config.loadWarnings.single.message,
        allOf(
          contains('`formal.sby_binary`'),
          contains('`formal.tools.yosys`'),
          contains('`formal.tools.abc`'),
        ),
      );
    });

    test('the gate fires at the suite and defaults levels too', () {
      const yaml = '''
version: "1"
defaults:
  simulator: sby
  formal: { sby_binary: /tmp/a }
suites:
  s:
    formal: { tools: { yosys: /tmp/b } }
    tests:
      - name: t
        top: t
        formal: { sby_file: a.sby }
''';
      final config = denied.parse(yaml, '/p.yaml');
      final formal = onlyFormal(config);
      expect(formal.sbyBinary, isNull);
      expect(formal.tools, isNull);
      final messages = config.loadWarnings.map((w) => w.message).join('\n');
      expect(messages, contains('`defaults.formal.sby_binary`'));
      expect(messages, contains('`formal.tools.yosys`'));
    });

    group('what the sby driver would spawn', () {
      List<String> argvOf(RegressionConfig config) {
        final test = config.suites.single.tests.single;
        // The command line, through a launcher that never runs anything.
        final job = _ArgvProbe().job(test);
        return job;
      }

      const body =
          '          sby_file: /p/a.sby\n          task: prove\n'
          '          sby_binary: /tmp/pwn\n          tools: { yosys: /tmp/pwn }';

      test('gate closed: the conventional sby, no tool override', () {
        final argv = argvOf(denied.parse(testYaml(body), '/p.yaml'));
        expect(argv.first, FormalConfig.kDefaultSbyBinary);
        expect(argv, isNot(contains('/tmp/pwn')));
      });

      test('gate open: the project binary and tool', () {
        final argv = argvOf(allowed.parse(testYaml(body), '/p.yaml'));
        expect(argv.first, '/tmp/pwn');
        expect(argv, containsAllInOrder(['--yosys', '/tmp/pwn']));
      });
    });
  });

  group('the eqy driver', () {
    String eqyYaml(String body) => testYaml(body, simulator: 'eqy');

    test('eqy_file and eqy_binary land on the test', () {
      final formal = onlyFormal(
        allowed.parse(
          eqyYaml('          eqy_file: eq/alu.eqy\n          eqy_binary: /e'),
          '/p/simcrux.yaml',
        ),
      );
      expect(formal.eqyFile, 'eq/alu.eqy');
      expect(formal.eqyBinary, '/e');
    });

    test('an eqy test without eqy_file does not load', () {
      final ex = capture(
        () => denied.parse(eqyYaml('          sby_file: a.sby'), '/p.yaml'),
      );
      expect(
        ex.errors.map((e) => e.message),
        anyElement(contains('`formal.eqy_file` is required')),
      );
    });

    test('demo mode is refused for eqy', () {
      final ex = capture(
        () => denied.parse(
          eqyYaml('          eqy_file: a.eqy\n          mode: demo'),
          '/p.yaml',
        ),
      );
      expect(
        ex.errors.map((e) => e.message),
        anyElement(contains('not available for the eqy driver')),
      );
    });

    for (final value in ['-d/tmp', 'dir/bad:name.eqy']) {
      test('eqy_file "$value" is refused, gate open or closed', () {
        for (final loader in [denied, allowed]) {
          final ex = capture(
            () => loader.parse(
              eqyYaml('          eqy_file: "$value"'),
              '/p.yaml',
            ),
          );
          expect(
            ex.errors.map((e) => e.message),
            anyElement(contains('`formal.eqy_file`')),
          );
        }
      });
    }

    test('formal.eqy_binary is dropped with an advisory', () {
      final config = denied.parse(
        eqyYaml('          eqy_file: a.eqy\n          eqy_binary: /tmp/pwn'),
        '/p.yaml',
      );
      expect(onlyFormal(config).eqyBinary, isNull);
      expect(
        config.loadWarnings.single.message,
        contains('`formal.eqy_binary`'),
      );
      final argv = _EqyArgvProbe().job(config.suites.single.tests.single);
      expect(argv.first, FormalConfig.kDefaultEqyBinary);
      expect(argv, isNot(contains('/tmp/pwn')));
      final open = allowed.parse(
        eqyYaml('          eqy_file: a.eqy\n          eqy_binary: /tmp/pwn'),
        '/p.yaml',
      );
      expect(
        _EqyArgvProbe().job(open.suites.single.tests.single).first,
        '/tmp/pwn',
      );
    });

    for (final key in ['command', 'extra_args']) {
      test('formal.$key refuses the load for eqy too', () {
        final body = '          eqy_file: a.eqy\n          $key: ["/tmp/pwn"]';
        final ex = capture(() => denied.parse(eqyYaml(body), '/p.yaml'));
        expect(
          ex.errors.map((e) => e.message),
          anyElement(contains('`formal.$key`')),
        );
      });
    }

    test('formal.tools reach eqy only through the gate', () {
      const body =
          '          eqy_file: a.eqy\n          tools: { yosys: /tmp/y }';
      final closed = _EqyArgvProbe().job(
        denied.parse(eqyYaml(body), '/p.yaml').suites.single.tests.single,
      );
      expect(closed, isNot(contains('--yosys')));
      final open = _EqyArgvProbe().job(
        allowed.parse(eqyYaml(body), '/p.yaml').suites.single.tests.single,
      );
      expect(open, containsAllInOrder(['--yosys', '/tmp/y']));
    });
  });
}

/// The eqy driver's command line for a spec, without spawning.
class _EqyArgvProbe extends EqyDriver {
  List<String> job(TestSpec test) => prepareJob(
    ExecuteRequest(
      test: test,
      workingDirectory: '/wd',
      compileResult: null,
      binaryConfig: const SimulatorBinaryConfig(simulatorId: EqyDriver.kId),
    ),
  ).argv;
}

/// Exposes the driver's command line for a spec without spawning.
class _ArgvProbe extends SbyDriver {
  List<String> job(TestSpec test) => prepareJob(
    ExecuteRequest(
      test: test,
      workingDirectory: '/wd',
      compileResult: null,
      binaryConfig: const SimulatorBinaryConfig(simulatorId: SbyDriver.kId),
    ),
  ).argv;
}
