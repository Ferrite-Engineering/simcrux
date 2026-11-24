// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// `simcrux mcp`: its definitions and their budget, the protocol through a
// scripted client, path confinement (a refused call runs and reads nothing,
// and a simcrux.yaml is expanded first), cancellation and progress of a
// run, a closed licence source said in the document, and the tool-call
// counter.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crux_mcp/crux_mcp.dart' hide HeadlessTelemetry;
import 'package:crux_mcp/crux_mcp_testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/core/cli/simcrux_cli.dart';
import 'package:simcrux/headless/simcrux_mcp.dart';

import 'support/spec_scheduler.dart';

void main() {
  late String tmp;
  late String root;
  late String outside;
  late SpecScheduler scheduler;
  late SimcruxCli cli;

  SimcruxCli cliOver(SpecScheduler s) => SimcruxCli(
    runSchedulerFactory: (_) => s,
    runRoot: p.join(tmp, 'scratch'),
    now: () => DateTime.utc(2026, 11, 23, 12),
    mcpTelemetry: () => null,
  );

  Future<Map<String, Object?>> call(
    String tool,
    Map<String, Object?> arguments, {
    McpServer? server,
  }) async {
    final line = await (server ?? cli.server(root: root, log: (_) {}))
        .handleLine(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'id': 1,
            'method': 'tools/call',
            'params': <String, Object?>{'name': tool, 'arguments': arguments},
          }),
        );
    final result =
        (jsonDecode(line!) as Map<String, Object?>)['result']!
            as Map<String, Object?>;
    return jsonDecode(
          ((result['content']! as List<Object?>).single!
                  as Map<String, Object?>)['text']!
              as String,
        )
        as Map<String, Object?>;
  }

  void write(String path, String text) => File(path)
    ..createSync(recursive: true)
    ..writeAsStringSync(text);

  String project({
    String sources = '      - rtl/alu.v',
    String extra = '',
    String tests = '      - name: a\n        top: alu',
  }) =>
      "version: '1'\n$extra"
      'defaults:\n  simulator: scripted\n  pass_fail:\n    type: exit_code\n'
      'suites:\n  smoke:\n    sources:\n$sources\n    tests:\n$tests\n';

  setUp(() {
    tmp = Directory.systemTemp
        .createTempSync('simcrux_mcp_')
        .resolveSymbolicLinksSync();
    root = p.join(tmp, 'root');
    outside = p.join(tmp, 'outside');
    write(p.join(root, 'rtl', 'alu.v'), 'module alu; endmodule\n');
    write(p.join(root, 'simcrux.yaml'), project());
    write(p.join(outside, 'alu.v'), 'module alu; endmodule\n');
    write(p.join(outside, 'simcrux.yaml'), project());
    write(p.join(outside, 'more.yaml'), "version: '1'\nsuites: {}\n");
    write(p.join(outside, 'list.f'), 'alu.v\n');
    scheduler = SpecScheduler(root: root);
    cli = cliOver(scheduler);
  });

  tearDown(() {
    if (Directory(tmp).existsSync()) Directory(tmp).deleteSync(recursive: true);
  });

  group('definitions', () {
    test("are the contracts' definitions, generated from one table", () {
      // `spec/mcp/definitions.json` holds the definitions of contracts 6.1 to
      // 6.4 as shipped (trend's fields in command-line order, test's
      // description says what it returns).
      final contract =
          jsonDecode(
                File(
                  p.join('spec', 'mcp', 'definitions.json'),
                ).readAsStringSync(),
              )
              as List<Object?>;
      expect(
        <String>[
          for (final t in kSimcruxMcpTools) mcpRenderJsonLine(t.definition()),
        ],
        <String>[for (final d in contract) mcpRenderJsonLine(d)],
      );
    });

    test('stay inside the budget, and the budget test fails when crossed', () {
      final server = cli.server(root: root);
      expectDefinitionBudget(server);
      // Contracts 7 measured run at 521 characters and the four free tools
      // with compare at 1,935, instructions counted at their 600 ceiling.
      expect(
        kSimcruxMcpTools
            .map((t) => t.definitionLength)
            .reduce((a, b) => a > b ? a : b),
        lessThan(560),
      );
      expect(mcpServerDefinitionLength(server), lessThan(2200));
      expect(
        () => expectDefinitionBudget(server, perTool: 400),
        throwsA(isA<McpBudgetExceeded>()),
      );
      expect(
        () => expectDefinitionBudget(server, perServer: 1000),
        throwsA(isA<McpBudgetExceeded>()),
      );
    });

    test('the instructions say when to call and how to cite, and no more', () {
      expect(kSimcruxMcpInstructions.length, lessThanOrEqualTo(600));
      expect(kSimcruxMcpInstructions, contains('file:line'));
      expect(kSimcruxMcpInstructions, contains('engine_error'));
      expect(kSimcruxMcpInstructions, contains('unknown test is a failed'));
      for (final banned in <String>['\u2014', 'better', 'faster', 'honest']) {
        expect(kSimcruxMcpInstructions, isNot(contains(banned)));
      }
    });

    test('nothing that runs what a project names, writes, or moves the gate '
        'is offered', () {
      final flags = <String>{
        for (final t in kSimcruxMcpTools)
          for (final f in t.fields) f.flag,
      };
      for (final flag in const <String>{
        '--allow-project-tooling',
        '--export',
        '--keep-failures',
        '--fail-threshold',
        '--fail-on-vacuous',
        '--fail-on-regression',
        '--baseline',
        '--license-file',
        '--root',
      }) {
        expect(flags, isNot(contains(flag)));
      }
      final names = <String>{
        for (final t in kSimcruxMcpTools)
          for (final f in t.fields) f.name,
      };
      expect(names, isNot(contains('allow_project_tooling')));
    });
  });

  group('protocol', () {
    test(
      'initialize, tools/list and a call through a scripted client',
      () async {
        final client = McpScriptedClient.inProcess(cli.server(root: root))
          ..send(
            '{"jsonrpc":"2.0","id":1,"method":"initialize","params":'
            '{"protocolVersion":"2025-06-18"}}',
          );
        final init = jsonDecode((await client.next())!) as Map<String, Object?>;
        final result = init['result']! as Map<String, Object?>;
        expect(result['protocolVersion'], '2025-06-18');
        expect(result['instructions'], kSimcruxMcpInstructions);
        expect(
          (result['serverInfo']! as Map<String, Object?>)['name'],
          'simcrux',
        );
        client.send('{"jsonrpc":"2.0","id":2,"method":"tools/list"}');
        final list = jsonDecode((await client.next())!) as Map<String, Object?>;
        final tools =
            (list['result']! as Map<String, Object?>)['tools']!
                as List<Object?>;
        expect(
          tools.map((t) => (t! as Map<String, Object?>)['name']),
          <String>['run', 'results', 'test', 'trend'],
        );
        client.send(
          '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":'
          '"run","arguments":{"config":"simcrux.yaml"}}}',
        );
        final answer =
            jsonDecode((await client.next())!) as Map<String, Object?>;
        expect(
          (answer['result']! as Map<String, Object?>)['isError'],
          isFalse,
        );
        await client.close();
      },
    );

    test('simcrux mcp refuses a root that is not a directory', () async {
      final err = <String>[];
      final code = await cli.run(
        <String>['mcp', '--root', p.join(tmp, 'missing')],
        stdoutSink: (_) {},
        stderrSink: err.add,
      );
      expect(code, 64);
      expect(err.join('\n'), contains('is not a directory'));
    });

    test('simcrux mcp --help answers without serving', () async {
      final out = <String>[];
      final code = await cli.run(
        <String>['mcp', '--help'],
        stdoutSink: out.add,
        stderrSink: (_) {},
      );
      expect(code, 0);
      expect(out.join('\n'), contains('simcrux mcp [--root <dir>]'));
    });

    test('serves stdin until it ends, from the command line', () async {
      final input = Stream<List<int>>.fromIterable(<List<int>>[
        utf8.encode('{"jsonrpc":"2.0","id":1,"method":"ping"}\n'),
      ]);
      final output = _Collect();
      final code = await cli.run(
        <String>['mcp', '--root', root],
        stdoutSink: (_) {},
        stderrSink: (_) {},
        input: input,
        output: output,
      );
      expect(code, 0);
      expect(output.text, '{"jsonrpc":"2.0","id":1,"result":{}}\n');
    });
  });

  group('confinement: a refused call runs and reads nothing', () {
    Future<void> expectRefused(
      String tool,
      Map<String, Object?> arguments,
    ) async {
      final doc = await call(tool, arguments);
      expect(doc['outcome'], 'usage_error', reason: '$arguments');
      expect(scheduler.submitted.isCompleted, isFalse, reason: 'a run began');
    }

    test('the check would see a run: a config inside is run', () async {
      final doc = await call('run', <String, Object?>{
        'config': 'simcrux.yaml',
      });
      expect(doc['outcome'], 'completed');
      expect(scheduler.submitted.isCompleted, isTrue);
    });

    test('a config outside the root', () async {
      await expectRefused('run', <String, Object?>{
        'config': p.join(outside, 'simcrux.yaml'),
      });
      await expectRefused('run', <String, Object?>{
        'config': '../outside/simcrux.yaml',
      });
    });

    test('a symbolic link out of the root', () async {
      Link(
        p.join(root, 'link.yaml'),
      ).createSync(p.join(outside, 'simcrux.yaml'));
      Link(p.join(root, 'linked')).createSync(outside);
      await expectRefused('run', <String, Object?>{'config': 'link.yaml'});
      write(
        p.join(root, 'via_link.yaml'),
        project(sources: '      - linked/alu.v'),
      );
      await expectRefused('run', <String, Object?>{
        'config': 'via_link.yaml',
      });
    }, testOn: '!windows');

    test('a simcrux.yaml inside that names a file outside', () async {
      for (final text in <String>[
        project(sources: '      - ${p.join(outside, 'alu.v')}'),
        project(sources: '      - ../outside/alu.v'),
        project(sources: '      - ../outside/list.f'),
        project(extra: 'includes:\n  - ../outside/more.yaml\n'),
        project(
          sources: '      - rtl/alu.v\n    include_dirs:\n      - $outside',
        ),
        project(
          tests:
              '      - name: a\n        top: alu\n        formal:\n'
              '          sby_file: ${p.join(outside, 'x.sby')}',
        ),
      ]) {
        write(p.join(root, 'named.yaml'), text);
        final doc = await call('run', <String, Object?>{
          'config': 'named.yaml',
        });
        expect(doc['outcome'], 'usage_error', reason: text);
        expect(scheduler.submitted.isCompleted, isFalse, reason: text);
      }
    });

    test('results written outside the project are refused by the load, and '
        'nothing runs', () async {
      // The loader's own rule, without --allow-project-tooling (which is
      // never offered): an `output:` path leading out of the project fails
      // the load, an input_error naming the flag.
      write(
        p.join(root, 'named.yaml'),
        project(
          extra:
              'output:\n  streaming: true\n'
              '  results_path: ../outside/results.ndjson\n',
        ),
      );
      final doc = await call('run', <String, Object?>{'config': 'named.yaml'});
      expect(doc['outcome'], 'input_error');
      expect(jsonEncode(doc), contains('allow-project-tooling'));
      expect(scheduler.submitted.isCompleted, isFalse);
      expect(File(p.join(outside, 'results.ndjson')).existsSync(), isFalse);
    });

    test('an outside filelist is refused without being read', () async {
      // A filelist outside names a source inside: refusing it on what it
      // names would mean reading it. It is refused on its own path.
      write(p.join(outside, 'inside.f'), '${p.join(root, 'rtl', 'alu.v')}\n');
      write(
        p.join(root, 'named.yaml'),
        project(sources: '      - ${p.join(outside, 'inside.f')}'),
      );
      final doc = await call('run', <String, Object?>{'config': 'named.yaml'});
      expect(doc['outcome'], 'usage_error');
      final message =
          ((doc['diagnostics']! as List<Object?>).single!
                  as Map<String, Object?>)['message']!
              as String;
      expect(message, contains('inside.f'));
      expect(scheduler.submitted.isCompleted, isFalse);
    });

    test('a network or device path', () async {
      for (final path in <String>[
        r'\\server\share\simcrux.yaml',
        '//server/share/simcrux.yaml',
        r'\\?\C:\simcrux.yaml',
      ]) {
        await expectRefused('run', <String, Object?>{'config': path});
        expect(
          (await call('results', <String, Object?>{
            'results': path,
          }))['outcome'],
          'usage_error',
        );
      }
    });

    test('a results file, or one run of a trend, outside the root', () async {
      write(p.join(outside, 'r.ndjson'), '');
      for (final (tool, arguments) in <(String, Map<String, Object?>)>[
        ('results', <String, Object?>{'results': '../outside/r.ndjson'}),
        (
          'test',
          <String, Object?>{'results': '../outside/r.ndjson', 'id': 'a/b'},
        ),
        (
          'trend',
          <String, Object?>{
            'id': 'a/b',
            'runs': <String>['r.ndjson', '../outside/r.ndjson'],
          },
        ),
      ]) {
        expect((await call(tool, arguments))['outcome'], 'usage_error');
      }
    });

    test('a log outside the root and SimCrux scratch is never read', () async {
      // The results file is inside; the log it names is not. The row keeps
      // the path, but no line is looked for in it and `test` reads none.
      write(
        p.join(outside, 'secret.txt'),
        'line one\nERROR: boom\n',
      );
      write(
        p.join(root, 'r.ndjson'),
        '${<Object?>[
          <String, Object?>{'type': 'meta', 'version': 1, 'run_id': '1', 'started_at': '2026-11-20T09:00:00.000Z'},
          <String, Object?>{'type': 'result', 'id': 's/t', 'name': 't', 'suite': 's', 'simulator': 'x', 'status': 'fail', 'runtime_ms': 1, 'started_at': '2026-11-20T09:00:00.000Z', 'finished_at': '2026-11-20T09:00:00.001Z', 'stdout_path': p.join(outside, 'secret.txt'), 'failure_message': 'ERROR: boom', 'did_execute': true},
        ].map(jsonEncode).join('\n')}\n',
      );
      final results = await call('results', <String, Object?>{
        'results': 'r.ndjson',
      });
      final row =
          ((results['body']! as Map<String, Object?>)['tests']!
                      as List<Object?>)
                  .single!
              as Map<String, Object?>;
      expect((row['location']! as Map<String, Object?>)['line'], isNull);
      final test = await call('test', <String, Object?>{
        'results': 'r.ndjson',
        'id': 's/t',
      });
      expect((test['body']! as Map<String, Object?>)['log'], isNull);
      expect(
        (test['diagnostics']! as List<Object?>).map(
          (d) => (d! as Map<String, Object?>)['code'],
        ),
        contains('log.outside'),
      );
      // The command line, with no root, reads it: the same row finds the
      // line, which is what shows the check above saw the read.
      final out = <String>[];
      await cli.run(
        <String>['results', p.join(root, 'r.ndjson'), '--json'],
        stdoutSink: out.add,
        stderrSink: (_) {},
      );
      expect(out.join('\n'), contains('"line": 2'));
    });
  });

  group('a run in flight', () {
    test('notifications/cancelled stops it through the scheduler, which '
        'kills its process trees, and nothing answers the call', () async {
      final held = SpecScheduler(root: root, hold: true);
      final client =
          McpScriptedClient.inProcess(
            cliOver(held).server(root: root, log: (_) {}),
          )..send(
            '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":'
            '"run","arguments":{"config":"simcrux.yaml"}}}',
          );
      await held.submitted.future;
      client
        ..send(
          '{"jsonrpc":"2.0","method":"notifications/cancelled","params":'
          '{"requestId":5}}',
        )
        ..send('{"jsonrpc":"2.0","id":6,"method":"ping"}');
      final next = jsonDecode((await client.next())!) as Map<String, Object?>;
      expect(next['id'], 6, reason: 'the cancelled call was answered');
      expect(held.cancelled, hasLength(1));
      await client.close();
    });

    test('a signal to the server cancels every run in flight', () async {
      final held = SpecScheduler(root: root, hold: true);
      final stop = Completer<void>();
      final server = cliOver(
        held,
      ).server(root: root, log: (_) {}, stop: stop.future);
      final answer = server.handleLine(
        '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":'
        '"run","arguments":{"config":"simcrux.yaml"}}}',
      );
      await held.submitted.future;
      stop.complete();
      final doc =
          jsonDecode(
                (((jsonDecode((await answer)!)
                                    as Map<String, Object?>)['result']!
                                as Map<String, Object?>)['content']!
                            as List<Object?>)
                        .cast<Map<String, Object?>>()
                        .single['text']!
                    as String,
              )
              as Map<String, Object?>;
      expect(held.cancelled, hasLength(1));
      expect(doc['outcome'], 'engine_error');
      expect(
        (doc['diagnostics']! as List<Object?>).map(
          (d) => (d! as Map<String, Object?>)['code'],
        ),
        contains('run.cancelled'),
      );
    });

    test('progress is reported when the call asks for it', () async {
      write(
        p.join(root, 'three.yaml'),
        project(
          tests:
              '      - name: a\n        top: alu\n      - name: b\n'
              '        top: alu\n      - name: c\n        top: alu',
        ),
      );
      final client = McpScriptedClient.inProcess(cli.server(root: root))
        ..send(
          '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":'
          '"run","arguments":{"config":"three.yaml"},"_meta":'
          '{"progressToken":"t"}}}',
        );
      final seen = <Map<String, Object?>>[];
      while (true) {
        final line = jsonDecode((await client.next())!) as Map<String, Object?>;
        if (line['id'] == 7) break;
        seen.add(line['params']! as Map<String, Object?>);
      }
      expect(seen, <Map<String, Object?>>[
        <String, Object?>{'progressToken': 't', 'progress': 1, 'total': 3},
        <String, Object?>{'progressToken': 't', 'progress': 2, 'total': 3},
        <String, Object?>{'progressToken': 't', 'progress': 3, 'total': 3},
      ]);
      await client.close();
    });
  });

  test('a licence file the server was given that cannot be read is '
      'licence_error, and nothing runs', () async {
    final server = cli.server(
      root: root,
      licenseFile: p.join(tmp, 'no-such.license'),
      log: (_) {},
    );
    final doc = await call('run', <String, Object?>{
      'config': 'simcrux.yaml',
    }, server: server);
    expect(doc['outcome'], 'licence_error');
    expect(
      ((doc['diagnostics']! as List<Object?>).single!
          as Map<String, Object?>)['code'],
      'licence.unreadable',
    );
    expect(scheduler.submitted.isCompleted, isFalse);
  });

  group('telemetry', () {
    test(
      'one mcp.tool_call per call: tool, outcome, duration and no more',
      () async {
        final events = <(String, Map<String, Object?>)>[];
        final server = cli.server(
          root: root,
          log: (_) {},
          telemetry: McpTelemetry(
            consented: () => true,
            sink: (name, properties) => events.add((name, properties)),
            environment: const <String, String>{},
          ),
        );
        await call('run', <String, Object?>{
          'config': 'simcrux.yaml',
        }, server: server);
        await call('results', <String, Object?>{
          'results': '../nowhere.ndjson',
        }, server: server);
        expect(events, hasLength(2));
        expect(events.first.$1, 'mcp.tool_call');
        expect(events.first.$2, <String, Object?>{
          'tool': 'run',
          'outcome': 'completed',
          'duration': 'lt_1s',
        });
        expect(events.last.$2['outcome'], 'usage_error');
      },
    );

    test('nothing is counted under CI', () async {
      final events = <String>[];
      final server = cli.server(
        root: root,
        log: (_) {},
        telemetry: McpTelemetry(
          consented: () => true,
          sink: (name, _) => events.add(name),
          environment: const <String, String>{'CI': 'true'},
        ),
      );
      await call('run', <String, Object?>{
        'config': 'simcrux.yaml',
      }, server: server);
      expect(events, isEmpty);
    });
  });
}

/// A sink that keeps what the server writes.
class _Collect implements StreamSink<List<int>> {
  final List<int> _bytes = <int>[];

  String get text => utf8.decode(_bytes);

  @override
  void add(List<int> data) => _bytes.addAll(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.forEach(add);

  @override
  Future<void> close() async {}

  @override
  Future<void> get done => Future<void>.value();
}
