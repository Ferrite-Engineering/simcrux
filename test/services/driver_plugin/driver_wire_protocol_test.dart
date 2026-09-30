// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/driver_capability.dart';
import 'package:simcrux/services/driver_plugin/driver_wire_protocol.dart';

void main() {
  group('DriverWireCodec', () {
    test('encode → decodeRequest round-trip preserves every field', () {
      final original = DriverRequests.compile(
        requestId: 42,
        testId: 'suite-a/test-1',
        simulatorId: 'verilator-reference',
        workingDirectory: '/tmp/work',
        spec: const <String, Object?>{'top': 'tb_top'},
      );
      final wire = original.encode();
      expect(wire, endsWith('\n'));
      final decoded = DriverWireCodec.decodeRequest(wire);
      expect(decoded.kind, DriverWireMessageKind.compile);
      expect(decoded.requestId, 42);
      expect(decoded.payload['testId'], 'suite-a/test-1');
      expect(decoded.payload['simulatorId'], 'verilator-reference');
      expect(decoded.payload['workingDirectory'], '/tmp/work');
      expect(decoded.payload['spec'], <String, Object?>{'top': 'tb_top'});
    });

    test('decodeResponse handles compileComplete success path', () {
      final response = DriverResponses.compileComplete(
        requestId: 7,
        success: true,
        artifactPath: '/tmp/build/sim',
      );
      final decoded = DriverWireCodec.decodeResponse(response.encode());
      expect(decoded.kind, DriverWireMessageKind.compileComplete);
      expect(decoded.payload['success'], true);
      expect(decoded.payload['artifactPath'], '/tmp/build/sim');
      expect(decoded.payload['failureMessage'], isNull);
    });

    test('decodeResponse handles runComplete with metrics', () {
      final response = DriverResponses.runComplete(
        requestId: 11,
        status: 'pass',
        exitCode: 0,
        waveformPath: '/tmp/out.vcd',
        metrics: const {'sim_time_ns': '12345', 'uvm_errors': '0'},
      );
      final decoded = DriverWireCodec.decodeResponse(response.encode());
      expect(decoded.kind, DriverWireMessageKind.runComplete);
      expect(decoded.payload['status'], 'pass');
      expect(decoded.payload['exitCode'], 0);
      expect(decoded.payload['waveformPath'], '/tmp/out.vcd');
      expect(decoded.payload['metrics'], isA<Map<dynamic, dynamic>>());
      final metrics = decoded.payload['metrics']! as Map;
      expect(metrics['sim_time_ns'], '12345');
      expect(metrics['uvm_errors'], '0');
    });

    test('initialized response declares capabilities sorted by wire id', () {
      final response = DriverResponses.initialized(
        requestId: 1,
        abiVersion: 1,
        declaredCapabilities: {
          DriverCapability.run,
          DriverCapability.compile,
          DriverCapability.waveformDump,
        },
      );
      final decoded = DriverWireCodec.decodeResponse(response.encode());
      final caps = decoded.payload['declaredCapabilities']! as List;
      expect(caps, ['compile', 'run', 'waveformDump']);
      expect(decoded.payload['abiVersion'], 1);
    });

    test('log envelope carries originating requestId for routing', () {
      final response = DriverResponses.log(
        requestId: 100,
        line: 'INFO: simulation started',
        fromStderr: false,
      );
      final decoded = DriverWireCodec.decodeResponse(response.encode());
      expect(decoded.requestId, 100);
      expect(decoded.payload['line'], 'INFO: simulation started');
      expect(decoded.payload['fromStderr'], false);
    });

    test('error envelope round-trips message + optional code', () {
      final response = DriverResponses.error(
        requestId: 0,
        message: 'verilator binary not on PATH',
        code: 'EBINMISSING',
      );
      final decoded = DriverWireCodec.decodeResponse(response.encode());
      expect(decoded.kind, DriverWireMessageKind.error);
      expect(decoded.payload['message'], 'verilator binary not on PATH');
      expect(decoded.payload['code'], 'EBINMISSING');
    });

    test('queryCapability is answered by a capabilityQueried response', () {
      final probe = DriverWireCodec.decodeRequest(
        DriverRequests.queryCapability(
          requestId: 9,
          capability: DriverCapability.compile,
        ).encode(),
      );
      expect(probe.kind, DriverWireMessageKind.queryCapability);
      final answer = DriverWireCodec.decodeResponse(
        DriverResponses.capabilityQueried(
          requestId: 9,
          capability: DriverCapability.compile,
          supported: true,
        ).encode(),
      );
      expect(answer.kind, DriverWireMessageKind.capabilityQueried);
      expect(answer.kind.wireId, 'capabilityQueried');
      expect(answer.requestId, 9);
      expect(answer.payload['capability'], DriverCapability.compile.wireId);
      expect(answer.payload['supported'], isTrue);
    });

    test('cancel request encodes the target requestId', () {
      final request = DriverRequests.cancel(requestId: 50, targetRequestId: 42);
      final decoded = DriverWireCodec.decodeRequest(request.encode());
      expect(decoded.kind, DriverWireMessageKind.cancel);
      expect(decoded.payload['targetRequestId'], 42);
    });

    test('encode terminator is exactly one newline', () {
      final request = DriverRequests.shutdown(requestId: 1).encode();
      expect(request.endsWith('\n'), isTrue);
      expect(request.substring(0, request.length - 1), isNot(contains('\n')));
    });
  });

  group('DriverProtocolError', () {
    test('raises malformedJson for invalid JSON', () {
      Object? caught;
      try {
        DriverWireCodec.decodeRequest('not json {{{');
      } on DriverProtocolError catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);
      expect(
        (caught! as DriverProtocolError).kind,
        DriverProtocolErrorKind.malformedJson,
      );
    });

    test('raises malformedJson for empty input', () {
      expect(
        () => DriverWireCodec.decodeRequest(''),
        throwsA(
          isA<DriverProtocolError>().having(
            (e) => e.kind,
            'kind',
            DriverProtocolErrorKind.malformedJson,
          ),
        ),
      );
    });

    test('raises malformedJson when envelope is not an object', () {
      expect(
        () => DriverWireCodec.decodeRequest('[1, 2, 3]'),
        throwsA(
          isA<DriverProtocolError>().having(
            (e) => e.kind,
            'kind',
            DriverProtocolErrorKind.malformedJson,
          ),
        ),
      );
    });

    test('raises missingField when kind is absent', () {
      expect(
        () => DriverWireCodec.decodeRequest('{"requestId": 1}'),
        throwsA(
          isA<DriverProtocolError>().having(
            (e) => e.kind,
            'kind',
            DriverProtocolErrorKind.missingField,
          ),
        ),
      );
    });

    test('raises missingField when requestId is absent', () {
      expect(
        () => DriverWireCodec.decodeRequest('{"kind": "shutdown"}'),
        throwsA(
          isA<DriverProtocolError>().having(
            (e) => e.kind,
            'kind',
            DriverProtocolErrorKind.missingField,
          ),
        ),
      );
    });

    test('raises unknownKind for unrecognized envelope kind', () {
      expect(
        () => DriverWireCodec.decodeRequest(
          '{"kind": "warp-drive-engage", "requestId": 1}',
        ),
        throwsA(
          isA<DriverProtocolError>().having(
            (e) => e.kind,
            'kind',
            DriverProtocolErrorKind.unknownKind,
          ),
        ),
      );
    });
  });

  group('DriverWireMessageKind', () {
    test('every kind round-trips through wireId / fromWireId', () {
      for (final kind in DriverWireMessageKind.values) {
        expect(DriverWireMessageKind.fromWireId(kind.wireId), kind);
      }
    });
  });
}
