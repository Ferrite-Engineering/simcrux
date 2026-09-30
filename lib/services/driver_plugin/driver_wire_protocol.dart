// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:simcrux/domain/enums/driver_capability.dart';

/// Wire-protocol envelope kind. Each request/response is a JSON
/// object on its own line; the `kind` field discriminates the
/// envelope variant.
///
/// Driver plugin SDK — v1 vocabulary. Future ABI
/// revisions may add kinds; consumers must silently ignore unknown
/// kinds for forward compatibility (the loader logs but does not
/// crash).
enum DriverWireMessageKind {
  // ---- Requests (host → driver subprocess) ----

  /// Initialization handshake. Sent immediately after the subprocess
  /// is spawned; the driver responds with [initialized] echoing back
  /// its declared capabilities so the host can validate the contract
  /// at runtime.
  initialize,

  /// Compile a test (drivers with a distinct compile phase).
  compile,

  /// Execute a previously-compiled test, or compile-and-run for
  /// drivers without a separate compile step.
  run,

  /// Cancel an in-flight compile / run by [requestId].
  cancel,

  /// Graceful shutdown — driver should flush any in-flight state and
  /// exit zero. The host follows up with SIGTERM / SIGKILL on the
  /// short-delay-escalation policy if the driver does not exit
  /// promptly.
  shutdown,

  /// Capability probe — asks whether the driver still supports a
  /// capability after initialization. Reserved: ABI 1 hosts never send
  /// it, but a driver should answer with [capabilityQueried] so a later
  /// host can.
  queryCapability,

  // ---- Responses (driver subprocess → host) ----

  /// Handshake acknowledgment.
  initialized,

  /// Incremental progress event during a long compile.
  compileProgress,

  /// Terminal compile event with the artifact path / failure reason.
  compileComplete,

  /// Incremental progress event during a long run.
  runProgress,

  /// Terminal run event with the run outcome.
  runComplete,

  /// Captured stdout / stderr line from the simulator.
  log,

  /// Driver-side error envelope (decoder failures, simulator-binary
  /// not found, internal exceptions). Host surfaces these alongside
  /// the host-side `PluginCrashed` / `PluginUnresponsive` events in
  /// the plugin events log.
  error,

  /// Answer to [queryCapability]: `{capability, supported}`, echoing the
  /// probe's requestId.
  capabilityQueried;

  /// Stable wire-protocol id used in JSONL envelopes. Kept identical
  /// to the Dart enum name (camelCase) so JSON round-tripping is
  /// trivial.
  String get wireId => name;

  /// Decodes a wire id into a [DriverWireMessageKind]. Returns
  /// `null` for unknown kinds; callers ignore unknown variants for
  /// forward compatibility.
  static DriverWireMessageKind? fromWireId(String wireId) {
    for (final value in DriverWireMessageKind.values) {
      if (value.wireId == wireId) {
        return value;
      }
    }
    return null;
  }
}

/// Common envelope shape — every wire message carries a kind, a
/// monotonically increasing requestId (the host's responsibility on
/// outbound; echoed on every correlated response), and a free-form
/// payload map.
///
/// Subclasses ([DriverRequest] / [DriverResponse]) tag the direction
/// for type safety; the on-wire JSON is identical for both directions
/// except for the [kind] vocabulary used.
@immutable
abstract class DriverWireMessage {
  /// Creates a [DriverWireMessage].
  const DriverWireMessage({
    required this.kind,
    required this.requestId,
    required this.payload,
  });

  /// Envelope kind discriminator.
  final DriverWireMessageKind kind;

  /// Correlator id. Host-side: monotonically increasing. Driver
  /// echoes the originating requestId on every correlated response
  /// (initialized echoes initialize's id; runComplete echoes run's
  /// id; logs may carry the originating run/compile id; standalone
  /// driver-initiated envelopes use id `0`).
  final int requestId;

  /// Payload fields specific to the envelope kind. Encoded as JSON
  /// scalars / lists / maps.
  final Map<String, Object?> payload;

  /// JSON-natural envelope used by [encode].
  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind.wireId,
    'requestId': requestId,
    'payload': payload,
  };

  /// Encodes this message as a single JSONL line, terminator
  /// included. Always emits one line that ends with `\n`.
  String encode() => '${jsonEncode(toJson())}\n';
}

/// Host → driver envelope.
@immutable
class DriverRequest extends DriverWireMessage {
  /// Creates a [DriverRequest].
  const DriverRequest({
    required super.kind,
    required super.requestId,
    super.payload = const <String, Object?>{},
  });
}

/// Driver → host envelope.
@immutable
class DriverResponse extends DriverWireMessage {
  /// Creates a [DriverResponse].
  const DriverResponse({
    required super.kind,
    required super.requestId,
    super.payload = const <String, Object?>{},
  });
}

/// Wire-protocol parsing utilities. Both directions decode the same
/// shape; the request/response distinction is enforced by the
/// envelope kind on the calling side.
class DriverWireCodec {
  /// Parses a single JSONL line into a [DriverRequest] (host-bound
  /// envelopes received by a plugin subprocess).
  static DriverRequest decodeRequest(String line) {
    final raw = _decodeShared(line);
    return DriverRequest(
      kind: raw.kind,
      requestId: raw.requestId,
      payload: raw.payload,
    );
  }

  /// Parses a single JSONL line into a [DriverResponse] (driver-bound
  /// envelopes received by the SimCrux host).
  static DriverResponse decodeResponse(String line) {
    final raw = _decodeShared(line);
    return DriverResponse(
      kind: raw.kind,
      requestId: raw.requestId,
      payload: raw.payload,
    );
  }

  static _DecodedEnvelope _decodeShared(String line) {
    final trimmed = line.trimRight();
    if (trimmed.isEmpty) {
      throw DriverProtocolError(
        'wire envelope cannot be empty',
        kind: DriverProtocolErrorKind.malformedJson,
      );
    }
    Object? parsed;
    try {
      parsed = jsonDecode(trimmed);
    } on FormatException catch (e) {
      throw DriverProtocolError(
        'wire envelope is not valid JSON: ${e.message}',
        kind: DriverProtocolErrorKind.malformedJson,
      );
    }
    if (parsed is! Map) {
      throw DriverProtocolError(
        'wire envelope must be a JSON object',
        kind: DriverProtocolErrorKind.malformedJson,
      );
    }
    final raw = parsed;
    final wireKind = raw['kind'];
    if (wireKind is! String) {
      throw DriverProtocolError(
        'wire envelope must carry a string `kind` field',
        kind: DriverProtocolErrorKind.missingField,
      );
    }
    final kind = DriverWireMessageKind.fromWireId(wireKind);
    if (kind == null) {
      throw DriverProtocolError(
        'wire envelope `kind` `$wireKind` is not recognized',
        kind: DriverProtocolErrorKind.unknownKind,
      );
    }
    final requestId = raw['requestId'];
    if (requestId is! int) {
      throw DriverProtocolError(
        'wire envelope must carry an integer `requestId` field',
        kind: DriverProtocolErrorKind.missingField,
      );
    }
    final payloadRaw = raw['payload'];
    final payload = payloadRaw is Map
        ? Map<String, Object?>.from(
            payloadRaw.map(
              (key, value) => MapEntry('$key', value),
            ),
          )
        : <String, Object?>{};
    return _DecodedEnvelope(
      kind: kind,
      requestId: requestId,
      payload: payload,
    );
  }
}

class _DecodedEnvelope {
  _DecodedEnvelope({
    required this.kind,
    required this.requestId,
    required this.payload,
  });

  final DriverWireMessageKind kind;
  final int requestId;
  final Map<String, Object?> payload;
}

/// Reason a [DriverProtocolError] was raised. Distinct from a
/// driver-side `error` envelope: protocol errors mean the host or
/// driver violated the wire contract itself, not that the simulator
/// failed to run.
enum DriverProtocolErrorKind {
  /// Envelope was not valid JSON.
  malformedJson,

  /// Envelope was valid JSON but missing a required field
  /// (`kind` / `requestId` / etc.).
  missingField,

  /// Envelope's `kind` is not a recognized [DriverWireMessageKind].
  unknownKind,

  /// Handshake did not complete within the configured timeout.
  handshakeTimeout,

  /// Driver-declared ABI version does not match
  /// `kSimcruxDriverPluginAbiVersion`.
  abiMismatch,
}

/// Raised by the host when an inbound envelope violates the wire
/// contract or the handshake fails. Distinct from a driver-side
/// `error` envelope (which represents a successful protocol exchange
/// reporting a simulator-level failure).
class DriverProtocolError implements Exception {
  /// Creates a [DriverProtocolError].
  DriverProtocolError(
    this.message, {
    required this.kind,
  });

  /// Reason the protocol contract was violated.
  final DriverProtocolErrorKind kind;

  /// Human-readable reason. Surfaced in the plugin events log and in
  /// per-test diagnostic output.
  final String message;

  @override
  String toString() => 'DriverProtocolError(${kind.name}): $message';
}

/// Convenience constructors for canonical request envelopes. Keeping
/// these as factories avoids spreading payload-shape knowledge across
/// the host codebase — every initialize / compile / run / cancel /
/// shutdown / queryCapability request is built from one of these.
class DriverRequests {
  /// Initialization handshake. The driver responds with
  /// [DriverResponses.initialized] echoing its declared capabilities.
  static DriverRequest initialize({
    required int requestId,
    required String hostVersion,
    required int hostAbiVersion,
  }) {
    return DriverRequest(
      kind: DriverWireMessageKind.initialize,
      requestId: requestId,
      payload: <String, Object?>{
        'hostVersion': hostVersion,
        'hostAbiVersion': hostAbiVersion,
      },
    );
  }

  /// Compile request. [testId] keys log / progress / completion
  /// envelopes back to the originating test.
  static DriverRequest compile({
    required int requestId,
    required String testId,
    required String simulatorId,
    required String workingDirectory,
    required Map<String, Object?> spec,
  }) {
    return DriverRequest(
      kind: DriverWireMessageKind.compile,
      requestId: requestId,
      payload: <String, Object?>{
        'testId': testId,
        'simulatorId': simulatorId,
        'workingDirectory': workingDirectory,
        'spec': spec,
      },
    );
  }

  /// Run request.
  static DriverRequest run({
    required int requestId,
    required String testId,
    required String simulatorId,
    required String workingDirectory,
    required Map<String, Object?> spec,
    String? compileArtifactPath,
  }) {
    final payload = <String, Object?>{
      'testId': testId,
      'simulatorId': simulatorId,
      'workingDirectory': workingDirectory,
      'spec': spec,
    };
    if (compileArtifactPath != null) {
      payload['compileArtifactPath'] = compileArtifactPath;
    }
    return DriverRequest(
      kind: DriverWireMessageKind.run,
      requestId: requestId,
      payload: payload,
    );
  }

  /// Cancel an in-flight compile / run identified by [targetRequestId].
  static DriverRequest cancel({
    required int requestId,
    required int targetRequestId,
  }) {
    return DriverRequest(
      kind: DriverWireMessageKind.cancel,
      requestId: requestId,
      payload: <String, Object?>{
        'targetRequestId': targetRequestId,
      },
    );
  }

  /// Graceful shutdown.
  static DriverRequest shutdown({required int requestId}) {
    return DriverRequest(
      kind: DriverWireMessageKind.shutdown,
      requestId: requestId,
    );
  }

  /// Runtime capability probe.
  static DriverRequest queryCapability({
    required int requestId,
    required DriverCapability capability,
  }) {
    return DriverRequest(
      kind: DriverWireMessageKind.queryCapability,
      requestId: requestId,
      payload: <String, Object?>{
        'capability': capability.wireId,
      },
    );
  }
}

/// Convenience constructors for canonical response envelopes.
class DriverResponses {
  /// Driver's response to [DriverRequests.initialize].
  static DriverResponse initialized({
    required int requestId,
    required int abiVersion,
    required Set<DriverCapability> declaredCapabilities,
  }) {
    final caps = declaredCapabilities.map((c) => c.wireId).toList()..sort();
    return DriverResponse(
      kind: DriverWireMessageKind.initialized,
      requestId: requestId,
      payload: <String, Object?>{
        'abiVersion': abiVersion,
        'declaredCapabilities': caps,
      },
    );
  }

  /// Terminal compile result. [success] true means [artifactPath] is
  /// populated; false means the compile failed and the driver should
  /// have emitted preceding [log] envelopes describing the failure.
  static DriverResponse compileComplete({
    required int requestId,
    required bool success,
    String? artifactPath,
    String? failureMessage,
  }) {
    final payload = <String, Object?>{
      'success': success,
    };
    if (artifactPath != null) payload['artifactPath'] = artifactPath;
    if (failureMessage != null) payload['failureMessage'] = failureMessage;
    return DriverResponse(
      kind: DriverWireMessageKind.compileComplete,
      requestId: requestId,
      payload: payload,
    );
  }

  /// Terminal run result.
  static DriverResponse runComplete({
    required int requestId,
    required String status,
    int? exitCode,
    String? failureMessage,
    String? waveformPath,
    Map<String, String> metrics = const <String, String>{},
  }) {
    final payload = <String, Object?>{
      'status': status,
      'metrics': Map<String, String>.from(metrics),
    };
    if (exitCode != null) payload['exitCode'] = exitCode;
    if (failureMessage != null) payload['failureMessage'] = failureMessage;
    if (waveformPath != null) payload['waveformPath'] = waveformPath;
    return DriverResponse(
      kind: DriverWireMessageKind.runComplete,
      requestId: requestId,
      payload: payload,
    );
  }

  /// Driver-emitted stdout / stderr line. The originating
  /// compile / run requestId is carried in [requestId] so the host
  /// can route the log line to the right per-test buffer.
  static DriverResponse log({
    required int requestId,
    required String line,
    required bool fromStderr,
  }) {
    return DriverResponse(
      kind: DriverWireMessageKind.log,
      requestId: requestId,
      payload: <String, Object?>{
        'line': line,
        'fromStderr': fromStderr,
      },
    );
  }

  /// Driver's answer to [DriverRequests.queryCapability].
  static DriverResponse capabilityQueried({
    required int requestId,
    required DriverCapability capability,
    required bool supported,
  }) {
    return DriverResponse(
      kind: DriverWireMessageKind.capabilityQueried,
      requestId: requestId,
      payload: <String, Object?>{
        'capability': capability.wireId,
        'supported': supported,
      },
    );
  }

  /// Driver-side protocol-level error envelope (e.g. simulator binary
  /// not on `$PATH`, internal exception). Distinct from a host-side
  /// [DriverProtocolError], which represents the host detecting that
  /// the driver violated the wire contract.
  static DriverResponse error({
    required int requestId,
    required String message,
    String? code,
  }) {
    final payload = <String, Object?>{
      'message': message,
    };
    if (code != null) payload['code'] = code;
    return DriverResponse(
      kind: DriverWireMessageKind.error,
      requestId: requestId,
      payload: payload,
    );
  }
}
