// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/services/simulator/python_traceback_reducer.dart';

// "Never surface a raw Python traceback." RISCOF failures arrive as
// ten to forty lines of interpreter frames whose only user-relevant content
// is the final `SomeError: message` line. That line — and only that line —
// becomes `TestExecutionFinished.failureMessage`, which is documented as a
// *short human-readable failure summary*. The full trace is never discarded:
// every line still reaches the stream as a TestLogLine and lands in the
// retained stderr log.
//
// MUTATION: return the whole buffer from `summary` and the "one line, not
// forty" assertions below fail.

const _riscofTraceback = '''
INFO | ****** RISCOF: RISC-V Architectural Test Framework 1.25.3 *******
INFO | Reading configuration from: /work/config.ini
Traceback (most recent call last):
  File "/venv/bin/riscof", line 8, in <module>
    sys.exit(cli())
  File "/venv/lib/python3.11/site-packages/click/core.py", line 1157, in __call__
    return self.main(*args, **kwargs)
  File "/venv/lib/python3.11/site-packages/riscof/main.py", line 210, in run
    plugin = importlib.import_module(module)
FileNotFoundError: [Errno 2] No such file or directory: '/opt/riscv/bin/spike'
''';

void main() {
  group('reduce', () {
    test('keeps only the terminal exception line', () {
      final summary = PythonTracebackReducer.reduce(_riscofTraceback);
      expect(
        summary,
        'FileNotFoundError: [Errno 2] No such file or directory: '
        "'/opt/riscv/bin/spike'",
      );
    });

    test('the summary is one line, not the whole trace', () {
      final summary = PythonTracebackReducer.reduce(_riscofTraceback)!;
      expect(summary, isNot(contains('\n')));
      expect(summary, isNot(contains('Traceback')));
      expect(summary, isNot(contains('site-packages')));
      // A dashboard row has to hold this.
      expect(summary.length, lessThan(120));
    });

    test('returns null when there is no traceback at all', () {
      expect(
        PythonTracebackReducer.reduce('INFO | all tests passed\n'),
        isNull,
      );
    });

    test('handles a dotted exception type', () {
      expect(
        PythonTracebackReducer.reduce(
          'Traceback (most recent call last):\n'
          '  File "x.py", line 1, in <module>\n'
          'riscof.utils.ValidationError: isa string is malformed\n',
        ),
        'riscof.utils.ValidationError: isa string is malformed',
      );
    });

    test('handles an exception with no message', () {
      expect(
        PythonTracebackReducer.reduce(
          'Traceback (most recent call last):\n'
          '  File "x.py", line 1, in <module>\n'
          'KeyboardInterrupt\n',
        ),
        'KeyboardInterrupt',
      );
    });

    test('a chained traceback reports the exception that escaped', () {
      final summary = PythonTracebackReducer.reduce(
        'Traceback (most recent call last):\n'
        '  File "a.py", line 1, in <module>\n'
        'KeyError: plugin\n'
        '\n'
        'During handling of the above exception, another exception occurred:\n'
        '\n'
        'Traceback (most recent call last):\n'
        '  File "b.py", line 9, in run\n'
        'RuntimeError: target plugin could not be loaded\n',
      );
      expect(summary, 'RuntimeError: target plugin could not be loaded');
    });

    test('a non-exception line after the frames ends the trace cleanly', () {
      // RISCOF prints its own summary after the interpreter's trace. That
      // line must not be mistaken for the exception.
      final summary = PythonTracebackReducer.reduce(
        'Traceback (most recent call last):\n'
        '  File "a.py", line 1, in <module>\n'
        'ERROR | riscof aborted\n',
      );
      expect(summary, isNull);
    });

    test('a bare error line outside a traceback is not picked up', () {
      // Without the header the reducer stays disarmed — a testbench that
      // legitimately prints "MyError: foo" is not a Python traceback.
      expect(
        PythonTracebackReducer.reduce('ValueError: not a traceback\n'),
        isNull,
      );
    });
  });

  group('incremental feed', () {
    test('matches the batch reduction line by line', () {
      final reducer = PythonTracebackReducer();
      expect(reducer.sawTraceback, isFalse);
      _riscofTraceback.split('\n').forEach(reducer.addLine);
      expect(reducer.sawTraceback, isTrue);
      expect(reducer.summary, PythonTracebackReducer.reduce(_riscofTraceback));
    });

    test('tolerates CRLF-style trailing whitespace', () {
      final reducer = PythonTracebackReducer()
        ..addLine('Traceback (most recent call last):\r')
        ..addLine('  File "a.py", line 1, in <module>\r')
        ..addLine('OSError: broken pipe\r');
      expect(reducer.summary, 'OSError: broken pipe');
    });
  });
}
