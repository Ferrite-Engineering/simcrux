// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/web/web_results_document.dart';

void main() {
  group('WebResultsDocument', () {
    test('decodes the consolidated simcrux-results.json shape', () {
      const json = '''
{
  "version": 1,
  "config_path": "/p/simcrux.yaml",
  "run": {
    "id": "run-1",
    "started_at": "2026-05-23T17:00:00.000Z",
    "finished_at": "2026-05-23T17:00:42.000Z",
    "total": 2
  },
  "tests": [
    {"id": "axi/burst", "name": "burst", "suite": "axi", "simulator": "icarus", "status": "pass", "runtime_ms": 1500, "exit_code": 0},
    {"id": "axi/wrap", "name": "wrap", "suite": "axi", "simulator": "icarus", "status": "fail", "runtime_ms": 2000, "exit_code": 1, "failure_message": "expected 0x42"}
  ]
}
''';
      final doc = WebResultsDocument.decodeConsolidated(json);
      expect(doc.runId, 'run-1');
      expect(doc.configPath, '/p/simcrux.yaml');
      expect(doc.rows, hasLength(2));
      expect(doc.rows.first.status, TestStatus.pass);
      expect(doc.rows.last.failureMessage, 'expected 0x42');
      expect(doc.totals[TestStatus.pass], 1);
      expect(doc.totals[TestStatus.fail], 1);
      expect(doc.finishedAt, isNotNull);
    });

    test('decodes the streaming NDJSON shape', () {
      const ndjson = '''
{"type":"meta","version":1,"run_id":"run-2","started_at":"2026-05-23T17:00:00.000Z","config_path":"/p.yaml"}
{"type":"result","id":"a","name":"a","suite":"s","simulator":"icarus","status":"pass","runtime_ms":10,"exit_code":0}
{"type":"result","id":"b","name":"b","suite":"s","simulator":"icarus","status":"fail","runtime_ms":15}
{"type":"summary","version":1,"finished_at":"2026-05-23T17:00:01.000Z","total":2,"totals":{"pass":1,"fail":1}}
''';
      final doc = WebResultsDocument.decodeNdjson(ndjson);
      expect(doc.runId, 'run-2');
      expect(doc.rows, hasLength(2));
      expect(doc.totals[TestStatus.pass], 1);
      expect(doc.totals[TestStatus.fail], 1);
      expect(doc.finishedAt, isNotNull);
    });

    test('decode() auto-detects consolidated vs NDJSON', () {
      const consolidated =
          '{"run":{"id":"x","started_at":"2026-01-01T00:00:00.000Z"},"tests":[]}';
      const ndjson =
          '{"type":"meta","run_id":"r"}\n{"type":"result","id":"a","status":"pass"}\n{"type":"summary"}';
      expect(
        WebResultsDocument.decode(consolidated).runId,
        'x',
      );
      expect(WebResultsDocument.decode(ndjson).runId, 'r');
    });

    test('tolerates missing optional fields', () {
      const ndjson = '{"type":"result","id":"only-id","status":"unknown"}';
      final doc = WebResultsDocument.decodeNdjson(ndjson);
      expect(doc.rows, hasLength(1));
      expect(doc.rows.single.testId, 'only-id');
      expect(doc.rows.single.testName, 'only-id');
      expect(doc.rows.single.status, TestStatus.unknown);
    });

    test('streaming totals win over recomputed totals', () {
      const ndjson = '''
{"type":"meta","run_id":"r"}
{"type":"result","id":"a","status":"pass"}
{"type":"summary","totals":{"pass":42}}
''';
      final doc = WebResultsDocument.decodeNdjson(ndjson);
      // Trust the streaming summary's totals even though they
      // disagree with the row count (e.g. NDJSON was truncated).
      expect(doc.totals[TestStatus.pass], 42);
    });
  });

  group('WebResultRow.fromJson', () {
    test('round-trips metrics map', () {
      final row = WebResultRow.fromJson(const <String, Object?>{
        'id': 't',
        'name': 't',
        'suite': 's',
        'simulator': 'icarus',
        'status': 'pass',
        'runtime_ms': 5,
        'metrics': <String, Object?>{'cycles': 42, 'cov': '99'},
      });
      expect(row.metrics, const {'cycles': '42', 'cov': '99'});
    });
  });
}
