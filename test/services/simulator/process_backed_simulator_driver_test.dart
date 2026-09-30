// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/hdl_language.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/simulator/process_backed_simulator_driver.dart';

/// A driver whose command-line construction throws before any process is
/// spawned — the shape of a bad option value.
class _ThrowingDriver extends ProcessBackedSimulatorDriver {
  _ThrowingDriver(this.error);

  final Error error;

  @override
  String get id => 'throwing';

  @override
  String get displayName => 'Throwing';

  @override
  SimulatorCapabilities get capabilities => SimulatorCapabilities(
    supportedLanguages: const {HdlLanguage.verilog},
    supportsVcd: false,
    supportsFst: false,
    supportsCocotb: false,
    requiresSeparateCompileStep: false,
    emitsStructuredOutput: false,
  );

  @override
  Future<String?> detectVersion(SimulatorBinaryConfig config) async => null;

  @override
  Future<CompileResult> compile(CompileRequest request) async =>
      const CompileResult(
        success: true,
        artifactPath: null,
        stdout: '',
        stderr: '',
      );

  @override
  Future<void> runExecute(
    ExecuteRequest request,
    StreamController<TestExecutionEvent> controller,
  ) async {
    throw error;
  }
}

void main() {
  test(
    'an error before spawn ends the stream with one unknown event',
    () async {
      final driver = _ThrowingDriver(ArgumentError('bad option'));
      final events = await driver
          .execute(
            ExecuteRequest(
              test: TestSpec(
                id: 's/t',
                name: 't',
                suiteName: 's',
                simulatorId: 'throwing',
                top: 'tb',
              ),
              workingDirectory: '/tmp',
              compileResult: null,
              binaryConfig: const SimulatorBinaryConfig(
                simulatorId: 'throwing',
              ),
            ),
          )
          .toList()
          .timeout(const Duration(seconds: 5));
      final finished = events.whereType<TestExecutionFinished>().single;
      expect(finished.status, TestStatus.unknown);
      expect(finished.failureMessage, contains('driver error'));
      expect(finished.failureMessage, contains('bad option'));
    },
  );
}
