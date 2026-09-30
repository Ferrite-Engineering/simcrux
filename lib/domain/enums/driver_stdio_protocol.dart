// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// Wire-format protocol the host speaks with a plugin's subprocess.
///
/// v1 of the driver plugin SDK ships line-delimited JSON
/// ([DriverStdioProtocol.jsonLines]) as the only supported format.
/// The enum exists so future ABI revisions can introduce additional
/// formats (e.g. msgpack for high-throughput log streaming) without a
/// breaking change to manifests authored against v1.
enum DriverStdioProtocol {
  /// Line-delimited JSON over stdin/stdout. Every request and
  /// response is exactly one UTF-8 JSON object on its own line
  /// terminated by `\n`. v1's only supported value.
  jsonLines;

  /// Stable wire-protocol id used in JSON manifests.
  String get wireId {
    switch (this) {
      case DriverStdioProtocol.jsonLines:
        return 'json-lines';
    }
  }

  /// Decodes a wire-protocol id into a [DriverStdioProtocol]. Returns
  /// `null` for unknown ids; the manifest parser rejects manifests
  /// whose declared protocol cannot be decoded.
  static DriverStdioProtocol? fromWireId(String wireId) {
    for (final value in DriverStdioProtocol.values) {
      if (value.wireId == wireId) {
        return value;
      }
    }
    return null;
  }
}
