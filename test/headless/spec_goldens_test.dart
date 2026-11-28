// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// `spec/mcp/`: every tool's golden documents, one per outcome it can produce,
// against both doors.
//
// - The `simcrux mcp` tool's `content[0]` text, with this machine's root
//   written as the goldens write it, is the golden byte for byte. The
//   goldens were checked by hand against `spec/fixtures/` and the spec's
//   scheduler (`support/spec_scheduler.dart`): each count, order, outcome,
//   log line and history entry read off the fixtures, the outcome rule of
//   contracts 2.4 and 6.1 applied by hand.
// - The same text is byte for byte what `simcrux <command> ... --json`
//   writes for the same arguments, and the command exits with the suite's
//   code for the outcome (contracts 2.4).
// - Every golden keeps `spec/mcp/schemas/`: the envelope and its body.

@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:crux_mcp/crux_mcp.dart' hide HeadlessTelemetry;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/json_schema_check.dart';
import 'support/spec_cases.dart';

Map<String, Object?> _schema(String name) =>
    jsonDecode(File(p.join('spec', 'mcp', 'schemas', name)).readAsStringSync())
        as Map<String, Object?>;

String _bodySchemaOf(String tool) =>
    tool == 'results' ? 'run.body.schema.json' : '$tool.body.schema.json';

void main() {
  final spec = SpecCases.load();
  tearDownAll(spec.dispose);
  final documentSchema = _schema('document.schema.json');

  group('each golden is what the tool answers', () {
    for (final c in spec.cases) {
      test(c.golden, () async {
        final result = await spec.callTool(spec.cli(), c);
        final content = result['content']! as List<Object?>;
        expect(content, hasLength(1));
        final item = content.single! as Map<String, Object?>;
        expect(item['type'], 'text');
        final text = spec.normalize(item['text']! as String);
        expect(text, spec.golden(c, actual: text));
        final outcome = McpOutcome.fromWireName(
          (jsonDecode(text) as Map<String, Object?>)['outcome']! as String,
        );
        expect(result['isError'], outcome!.isError);
      });
    }
  });

  group('the tool and the command line write the same bytes', () {
    for (final c in spec.cases.where((c) => c.door == 'both')) {
      test(c.golden, () async {
        // One program for both doors, the real one, so nothing is normalized.
        const program = McpProgram(name: 'simcrux', version: '9.9.9');
        final result = await spec.callTool(spec.cli(program: program), c);
        final toolText = SpecCases.text(result);
        final (stdoutText, code) = await spec.runCommandLine(
          spec.cli(program: program),
          spec.argv(c),
        );
        expect(stdoutText, toolText);
        expect(code, c.exit, reason: "the contracts' exit code");
        final outcome = McpOutcome.fromWireName(
          (jsonDecode(toolText) as Map<String, Object?>)['outcome']! as String,
        );
        expect(code, McpExitCodes.suite.exitCodeFor(outcome!));
      });
    }
  });

  group('each golden keeps the schemas', () {
    for (final c in spec.cases) {
      test(c.golden, () {
        final doc = jsonDecode(spec.golden(c)) as Map<String, Object?>;
        expect(jsonSchemaProblems(doc, documentSchema), isEmpty);
        expect(doc['command'], c.tool);
        final body = doc['body'];
        if (body != null) {
          expect(
            jsonSchemaProblems(body, _schema(_bodySchemaOf(c.tool))),
            isEmpty,
          );
        }
        final errors = (doc['diagnostics']! as List<Object?>)
            .cast<Map<String, Object?>>()
            .where((d) => d['severity'] == 'error');
        if (doc['outcome'] == 'completed') {
          expect(body, isNotNull);
          expect(errors, isEmpty);
        } else {
          expect(errors, isNotEmpty);
        }
      });
    }
  });

  test('the schema checker rejects what the schemas forbid', () {
    final good = jsonDecode(spec.golden(spec.cases.first));
    expect(jsonSchemaProblems(good, documentSchema), isEmpty);
    final extra = <String, Object?>{
      ...good as Map<String, Object?>,
      'extra': 1,
    };
    expect(jsonSchemaProblems(extra, documentSchema), isNotEmpty);
    final missing = Map<String, Object?>.of(good)..remove('engines');
    expect(jsonSchemaProblems(missing, documentSchema), isNotEmpty);
    final badOutcome = Map<String, Object?>.of(good)..['outcome'] = 'fine';
    expect(jsonSchemaProblems(badOutcome, documentSchema), isNotEmpty);
    final body = Map<String, Object?>.of(good['body']! as Map<String, Object?>)
      ..remove('totals');
    expect(
      jsonSchemaProblems(body, _schema('run.body.schema.json')),
      isNotEmpty,
    );
    final tests =
        (good['body']! as Map<String, Object?>)['tests']! as List<Object?>;
    final row = Map<String, Object?>.of(tests.first! as Map<String, Object?>)
      ..['status'] = 'running';
    expect(
      jsonSchemaProblems(<String, Object?>{
        ...good['body']! as Map<String, Object?>,
        'tests': <Object?>[row],
      }, _schema('run.body.schema.json')),
      isNotEmpty,
    );
  });

  test('a Windows root is put into the fixtures as JSON, and read back from '
      'a document as the goldens write it', () {
    // `Directory.systemTemp` on a Windows runner, and the root in it.
    const tmp = r'C:\Users\runneradmin\AppData\Local\Temp\simcrux_spec_1';
    const root =
        r'C:\Users\runneradmin\AppData\Local\Temp\simcrux_spec_1'
        r'\root';
    const line =
        '{"type":"meta","config_path":"@ROOT@/design/simcrux.yaml",'
        '"stdout_path":"@ROOT@/logs/alu_sub_fail.txt","root":"@ROOT@"}';
    // Put in raw, the backslashes are escapes and the line is not JSON.
    expect(
      () => jsonDecode(line.replaceAll('@ROOT@', root)),
      throwsFormatException,
    );
    final installed = installSpecFixture(
      line,
      placeholder: '@ROOT@',
      root: root,
      context: p.windows,
    );
    expect(jsonDecode(installed), <String, Object?>{
      'type': 'meta',
      'config_path':
          r'C:\Users\runneradmin\AppData\Local\Temp\simcrux_spec_1\root'
          r'\design\simcrux.yaml',
      'stdout_path':
          r'C:\Users\runneradmin\AppData\Local\Temp\simcrux_spec_1\root'
          r'\logs\alu_sub_fail.txt',
      'root': root,
    });
    // On a POSIX host the fixture is the committed bytes with the root in.
    expect(
      installSpecFixture(
        line,
        placeholder: '@ROOT@',
        root: '/tmp/simcrux_spec_1/root',
        context: p.posix,
      ),
      line.replaceAll('@ROOT@', '/tmp/simcrux_spec_1/root'),
    );

    // A document a Windows run writes: JSON escapes each `\`.
    final document = jsonEncode(<String, Object?>{
      'file':
          r'C:\Users\runneradmin\AppData\Local\Temp\simcrux_spec_1\root'
          r'\logs\alu_sub_fail.txt',
      'outside':
          r'C:\Users\runneradmin\AppData\Local\Temp\simcrux_spec_1'
          r'\outside\simcrux.yaml',
      'mixed':
          'C:/Users/runneradmin/AppData/Local/Temp/simcrux_spec_1/root/runs/'
          'run_a.ndjson',
      'message': 'not "5000".\nkept as is',
    });
    expect(
      normalizeSpecRoot(
        document,
        root: root,
        tmp: tmp,
        goldenRoot: '/spec/fixtures',
        windows: true,
      ),
      jsonEncode(<String, Object?>{
        'file': '/spec/fixtures/logs/alu_sub_fail.txt',
        'outside': '/spec/outside/simcrux.yaml',
        'mixed': '/spec/fixtures/runs/run_a.ndjson',
        'message': 'not "5000".\nkept as is',
      }),
    );

    // A path outside the root: `/x` is root-relative on Windows, not
    // absolute, so the cases give it the temporary directory's drive there;
    // it is still outside the root, and reads back as the golden writes it.
    const outside = '/nonexistent-simcrux-spec/results.ndjson';
    final prefix = specOutsidePrefix(tmp, windows: true);
    expect(prefix, 'C:');
    expect(specOutsidePrefix('/tmp/s', windows: false), '');
    expect(p.windows.isRootRelative(outside), isTrue);
    expect(p.windows.isAbsolute('$prefix$outside'), isTrue);
    expect(p.windows.isRootRelative('$prefix$outside'), isFalse);
    expect(p.windows.isWithin(root, '$prefix$outside'), isFalse);
    expect(
      hostOutsidePaths(<String, Object?>{
        'results': outside,
        'runs': <Object?>[outside, 'runs/run_a.ndjson'],
        'lines': 5,
      }, prefix),
      <String, Object?>{
        'results': '$prefix$outside',
        'runs': <Object?>['$prefix$outside', 'runs/run_a.ndjson'],
        'lines': 5,
      },
    );
    expect(hostOutsidePaths(outside, ''), outside);
    for (final given in <String>[
      'C:/nonexistent-simcrux-spec/results.ndjson',
      r'C:\\nonexistent-simcrux-spec\\results.ndjson',
    ]) {
      expect(
        normalizeSpecRoot(
          '"message": "`$given` is outside the root '
          r'C:\\Users\\runneradmin\\AppData\\Local\\Temp\\simcrux_spec_1'
          r'\\root;"',
          root: root,
          tmp: tmp,
          goldenRoot: '/spec/fixtures',
          windows: true,
        ),
        '"message": "`/nonexistent-simcrux-spec/results.ndjson` is outside '
        'the root /spec/fixtures;"',
      );
    }

    expect(
      normalizeSpecRoot(
        '{"file":"/tmp/s/root/logs/x.txt","outside":"/tmp/s/outside/y"}',
        root: '/tmp/s/root',
        tmp: '/tmp/s',
        goldenRoot: '/spec/fixtures',
        windows: false,
      ),
      '{"file":"/spec/fixtures/logs/x.txt","outside":"/spec/outside/y"}',
    );
  });

  test('every tool has a golden for each outcome it can produce', () {
    final byTool = <String, Set<String>>{};
    for (final c in spec.cases) {
      final doc = jsonDecode(spec.golden(c)) as Map<String, Object?>;
      byTool
          .putIfAbsent(c.tool, () => <String>{})
          .add(doc['outcome']! as String);
    }
    // run's licence_error (an unreadable --license-file given to the
    // server) is held by mcp_server_test.dart; no tool of the open-core
    // binary has a tier gate.
    expect(byTool, <String, Set<String>>{
      'run': <String>{
        'completed',
        'failed_gate',
        'usage_error',
        'input_error',
        'engine_error',
      },
      'results': <String>{
        'completed',
        'failed_gate',
        'usage_error',
        'input_error',
        'engine_error',
      },
      'test': <String>{'completed', 'usage_error', 'input_error'},
      'trend': <String>{'completed', 'usage_error', 'input_error'},
    });
  });

  test('every location names an absolute file, and no link that would not '
      'open', () {
    // A test's citation is `file:line` of its log; its waveform is a place
    // (file and time) with no link member (contracts 2.10; the link
    // convention, section 8), which a person opens with the link the
    // WaveCrux builder writes for that file and time.
    var lines = 0;
    var places = 0;
    void walk(Object? json) {
      if (json is Map<String, Object?>) {
        expect(json.containsKey('link'), isFalse);
        if (json.containsKey('test') && json.containsKey('run')) {
          McpLocation.fromJson(json);
          if (json['line'] != null) {
            lines++;
            expect(p.posix.isAbsolute(json['file']! as String), isTrue);
            expect(json['line'], greaterThanOrEqualTo(1));
          }
        }
        if (json.containsKey('time') && json.containsKey('file')) {
          places++;
          final place = McpLocation.fromJson(json) as McpPlaceLocation;
          expect(place.time, McpTime.ticks(0));
          expect(
            waveCruxLink(place.file, time: place.time),
            startsWith('${kWaveCruxLinkPrefix}file=%2Fspec%2Ffixtures%2F'),
          );
        }
        json.values.forEach(walk);
      } else if (json is List<Object?>) {
        json.forEach(walk);
      }
    }

    for (final c in spec.cases) {
      walk(jsonDecode(spec.golden(c)));
    }
    expect(lines, greaterThanOrEqualTo(3));
    expect(places, greaterThanOrEqualTo(3));
  });
}
