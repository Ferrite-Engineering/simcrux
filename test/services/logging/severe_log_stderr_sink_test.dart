// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:simcrux/services/logging/severe_log_stderr_sink.dart';

/// Collects everything written to it, as text.
class _Capture implements StreamConsumer<List<int>> {
  final buffer = StringBuffer();

  @override
  Future<void> addStream(Stream<List<int>> stream) =>
      stream.forEach((bytes) => buffer.write(utf8.decode(bytes)));

  @override
  Future<void> close() async {}
}

/// Fails every write, the way stderr does in a process with no console.
class _Broken implements StreamConsumer<List<int>> {
  int attempts = 0;

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final _ in stream) {
      attempts++;
      throw const FileSystemException('writeFrom failed', '', OSError('', 6));
    }
  }

  @override
  Future<void> close() async {}
}

void main() {
  late Level originalLevel;

  setUp(() {
    originalLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
  });

  tearDown(() => Logger.root.level = originalLevel);

  Future<void> drain() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  test('writes SEVERE and SHOUT records, with error and stack, and nothing '
      'below', () async {
    final capture = _Capture();
    final sink = SevereLogStderrSink(sink: IOSink(capture))..attach();
    addTearDown(sink.detach);

    Logger('simcrux.test')
      ..warning('a warning')
      ..severe('uncaught failure', StateError('boom'), StackTrace.current)
      ..shout('shouted');
    await drain();

    final text = capture.buffer.toString();
    expect(text, isNot(contains('a warning')));
    expect(text, contains('SEVERE simcrux.test: uncaught failure'));
    expect(text, contains('\n  Bad state: boom'));
    expect(text, contains('severe_log_stderr_sink_test.dart'));
    expect(text, contains('SHOUT simcrux.test: shouted'));
  });

  test('a stderr that cannot be written stops the sink without an uncaught '
      'error, and it never writes again', () async {
    final broken = _Broken();
    final sink = SevereLogStderrSink(sink: IOSink(broken))..attach();
    addTearDown(sink.detach);

    Logger('simcrux.test').severe('first');
    await drain();
    expect(sink.isAttached, isFalse);

    Logger('simcrux.test').severe('second');
    await drain();
    expect(broken.attempts, 1);
  });

  test('attach is idempotent', () async {
    final capture = _Capture();
    final sink = SevereLogStderrSink(sink: IOSink(capture))
      ..attach()
      ..attach();
    addTearDown(sink.detach);

    Logger('simcrux.test').severe('once');
    await drain();

    expect('once'.allMatches(capture.buffer.toString()), hasLength(1));
  });

  test('format does not repeat an error the message already names', () {
    final error = StateError('boom');
    final line = SevereLogStderrSink.format(
      LogRecord(Level.SEVERE, 'Uncaught: $error', 'flutter', error),
    );
    expect('Bad state: boom'.allMatches(line), hasLength(1));
  });
}
