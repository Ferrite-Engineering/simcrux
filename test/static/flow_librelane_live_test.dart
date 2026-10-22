// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Live assertions: re-run LibreLane through the regenerator and check the
// hand-written expectations against what it produces now.
//
// Gated on the toolchain. Set LIBRELANE_NIX_SHELL to a LibreLane checkout's
// shell.nix (the regenerator then runs inside `nix-shell <it> --run`), or put
// `librelane` on PATH. Without either the group is skipped, unless
// FLOW_LIVE_REQUIRED=1, which turns a missing tool into a failure; the weekly
// workflow sets it so a dead install cannot pass as a skip.
// FLOW_LIVE_LIBRELANE_CASES limits the cases (space-separated names, `g1` for
// the mapping gate); unset, every case of the installed version runs.
//
// Facts are compared, not bytes: exit status, which steps wrote no
// state_out.json, the failing step, the error records, the sign of each
// headline metric, the worst register path's endpoints, and the G1 outcome.
// Slacks and counts move with every tool build and are not pinned.
//
// Tagged `oss-cad-live`: the CI `Test` job runs `flutter test -x oss-cad-live`.
// flow-live.yml runs this file without that exclusion.

@Tags(['oss-cad-live'])
@Timeout(Duration(minutes: 140))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'flow_librelane_facts.dart';

const _root = 'verification/fixtures/flow/librelane';

bool get _required => Platform.environment['FLOW_LIVE_REQUIRED'] == '1';

String? get _nixShell {
  final value = Platform.environment['LIBRELANE_NIX_SHELL'];
  return (value == null || value.isEmpty) ? null : value;
}

bool _onPath(String tool) => Process.runSync('which', [tool]).exitCode == 0;

/// Why the group cannot run, or null when it can.
String? _blocker() {
  final shell = _nixShell;
  if (shell != null) {
    if (!File(shell).existsSync()) return 'LIBRELANE_NIX_SHELL does not exist';
    if (!_onPath('nix-shell')) return 'nix-shell is not on PATH';
    return null;
  }
  if (!_onPath('librelane')) {
    return 'librelane is not on PATH and LIBRELANE_NIX_SHELL is unset';
  }
  return null;
}

/// Runs [command] inside the LibreLane environment.
ProcessResult _inLibreLane(String command) {
  final shell = _nixShell;
  return shell == null
      ? Process.runSync('bash', ['-c', command])
      : Process.runSync('nix-shell', [shell, '--run', command]);
}

void main() {
  final blocker = _blocker();
  if (blocker != null && _required) {
    test('the live toolchain is installed', () {
      fail('FLOW_LIVE_REQUIRED=1 and $blocker');
    });
  }

  group('LibreLane live', () {
    late Directory out;
    late String version;
    final only = (Platform.environment['FLOW_LIVE_LIBRELANE_CASES'] ?? '')
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .toList();

    setUpAll(() {
      final probe = _inLibreLane('librelane --version');
      final m = RegExp(r'LibreLane v(\d+\.\d+\.\d+)').firstMatch(
        '${probe.stdout}',
      );
      if (m == null) fail('cannot read the LibreLane version: ${probe.stderr}');
      version = m[1]!;
      if (!Directory('$_root/$version').existsSync()) {
        fail(
          'LibreLane $version has no committed fixture set: it is an '
          'unverified version until one is added under $_root/$version',
        );
      }
      out = Directory.systemTemp.createTempSync('flow_librelane_live_');
      final args = [
        'bash',
        'tool/flow/regen_librelane_fixtures.sh',
        '--out',
        out.path,
        for (final c in only) ...['--case', c],
      ];
      final result = _inLibreLane(args.map(_quote).join(' '));
      if (result.exitCode != 0) {
        fail(
          'regenerator exited ${result.exitCode}\n'
          '${result.stdout}\n${result.stderr}',
        );
      }
    });

    tearDownAll(() {
      if (out.existsSync()) out.deleteSync(recursive: true);
    });

    test('every committed case of this version was regenerated', () {
      final committed = Directory('$_root/$version')
          .listSync()
          .whereType<Directory>()
          .map(dirName)
          .where((n) => only.isEmpty || only.contains(n))
          .toList();
      expect(committed, isNotEmpty);
      final mapping = readJson('$_root/mapping.expected.json');
      for (final name in committed) {
        final expected = readJson('$_root/$version/$name/case.expected.json');
        final diffs = caseDifferences(
          Directory('${out.path}/$version/$name'),
          expected,
          exactMetrics: false,
          mapping: mapping,
        );
        expect(diffs, isEmpty, reason: name);
      }
    });

    test(
      'G1: the mapping gate outcome is unchanged',
      () {
        final want = readJson('$_root/$version/g1.expected.json');
        final got = readJson('${out.path}/$version/g1.json');
        final flipFlops = (got['flip_flop_census'] as Map)['flip_flops'] as int;
        expect(flipFlops, greaterThanOrEqualTo(want['min_flip_flops'] as int));
        expect(got['endpoints_counted'], want['endpoints']);
        final share = (got['share'] as num).toDouble();
        final outcome = share >= 0.9
            ? '>=90'
            : (share >= 0.6 ? '60-90' : '<60');
        expect(outcome, want['outcome'], reason: 'share $share');
      },
      skip:
          (only.isNotEmpty && !only.contains('g1')) ||
              !File('$_root/3.0.16/g1.expected.json').existsSync()
          ? 'g1 not selected'
          : null,
    );
  }, skip: blocker);
}

String _quote(String s) => RegExp(r'^[A-Za-z0-9_./=-]+$').hasMatch(s)
    ? s
    : "'${s.replaceAll("'", r"'\''")}'";
