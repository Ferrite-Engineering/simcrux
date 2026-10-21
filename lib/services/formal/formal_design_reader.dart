// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';
import 'dart:isolate';

import 'package:crux_netlist/crux_netlist.dart';
import 'package:crux_yosys/crux_yosys.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/services/formal/formal_containment.dart';
import 'package:simcrux/services/formal/pretrace_detector.dart';

/// Reads the design `sby` elaborated for a task (`<task>/model/design.il`,
/// after the job's own `[script]` and `prep`, whatever the frontend) into
/// [FormalDesignFacts].
///
/// Yosys converts the RTLIL to its JSON netlist (`read_rtlil; write_json`,
/// spawned through `crux_yosys`'s bounded, killable process seam) and
/// `crux_netlist` parses it. The design is the one `sby` proved, not a
/// second elaboration that could disagree with it, so the frontend, the
/// defines and the `[script]` are all already applied.
///
/// Never throws: a missing model, a Yosys that does not answer, a file too
/// large to read or JSON that does not parse yields null and a [note] for
/// the run log, and the run's verdict is unaffected.
class FormalDesignReader {
  /// Creates a reader.
  const FormalDesignReader({
    this._processRunner = const DefaultProcessRunner(),
    this.timeout = const Duration(seconds: 60),
    this.maxDesignBytes = 16 * 1024 * 1024,
  });

  final ProcessRunner _processRunner;

  /// How long the conversion may take.
  final Duration timeout;

  /// The largest `design.il` analysed. A bigger design is skipped rather
  /// than read whole into memory.
  final int maxDesignBytes;

  /// The JSON file written beside `design.il`. Inside the task directory,
  /// which `sby -f` clears before the next run.
  static const String kJsonName = 'simcrux_design.json';

  /// The facts of [taskDirectory]'s elaborated design, or null.
  ///
  /// [yosys] is the Yosys to convert with (the one beside `sby`, or the
  /// job's `formal.tools.yosys`); [environment] is the run's environment.
  Future<({FormalDesignFacts? facts, String? note})> read({
    required String taskDirectory,
    required String yosys,
    Map<String, String>? environment,
  }) async {
    final model = FormalContainment.containedPath(
      taskDirectory,
      p.join(taskDirectory, 'model'),
    );
    if (model == null) return (facts: null, note: null);
    final il = File(p.join(model, 'design.il'));
    if (!il.existsSync()) return (facts: null, note: null);
    if (il.lengthSync() > maxDesignBytes) {
      return (
        facts: null,
        note:
            'the elaborated design is larger than '
            '${maxDesignBytes ~/ (1024 * 1024)} MiB; the pre-trace and '
            'dropped-property checks were skipped.',
      );
    }
    final json = File(p.join(model, kJsonName));
    try {
      final result = await _processRunner.run(
        yosys,
        <String>['-q', '-p', 'read_rtlil design.il; write_json $kJsonName'],
        workingDirectory: model,
        environment: environment,
        timeout: timeout,
      );
      if (result.termination != ProcessTermination.exited ||
          result.exitCode != 0 ||
          !json.existsSync()) {
        return (
          facts: null,
          note:
              'Yosys could not read the elaborated design (exit '
              '${result.exitCode}); the pre-trace and dropped-property '
              'checks were skipped.',
        );
      }
      if (json.lengthSync() > maxDesignBytes * 4) {
        return (
          facts: null,
          note:
              'the elaborated design is too large to analyse; the pre-trace '
              'and dropped-property checks were skipped.',
        );
      }
      // Read, parsed and analysed off the calling isolate: the GUI runs
      // drivers on the UI isolate, and a design is megabytes of JSON.
      final path = json.path;
      final facts = await Isolate.run(
        () => const PretraceDetector().analyse(
          const YosysJsonParser().parse(File(path).readAsStringSync()),
        ),
      );
      return (facts: facts, note: null);
    } on ProcessException catch (e) {
      return (
        facts: null,
        note:
            'Yosys (`${e.executable}`) could not be started; the pre-trace '
            'and dropped-property checks were skipped.',
      );
    } on Object catch (e) {
      return (
        facts: null,
        note:
            'the elaborated design could not be read ($e); the pre-trace '
            'and dropped-property checks were skipped.',
      );
    } finally {
      try {
        if (json.existsSync()) json.deleteSync();
      } on FileSystemException {
        // A leftover file inside the task directory is cleared by the next
        // `sby -f`.
      }
    }
  }
}
