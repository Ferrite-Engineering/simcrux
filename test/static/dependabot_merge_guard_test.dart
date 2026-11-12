// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Static guard: the Dependabot merge workflow starts a CI run on main after
// every merge, and does not run on a schedule while a release is being cut.
//
// A pull request merged with `GITHUB_TOKEN` starts no push workflow, so the
// merged tip had no `ci.yml` run and the release workflow, which waits for one,
// refused it. `workflow_dispatch` is the one event that token may start, and
// it needs `actions: write`. None of this shows up in a widget test, so this
// reads the workflow as text, the same way the other static guards do.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _path = '.github/workflows/dependabot-merge.yml';

/// The workflow with its comment lines removed, so a commented-out schedule or
/// a step mentioned only in prose does not count.
String _active() {
  var dir = Directory.current.absolute;
  while (true) {
    final file = File('${dir.path}/$_path');
    if (file.existsSync()) {
      return file
          .readAsLinesSync()
          .where((line) => !line.trimLeft().startsWith('#'))
          .join('\n');
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      fail('$_path was not found in ${Directory.current.path} or above.');
    }
    dir = parent;
  }
}

void main() {
  late String workflow;

  setUpAll(() => workflow = _active());

  // Delete this test when the schedule is restored after EDACrux 1.2 is cut.
  test('the schedule is paused until 1.2 is cut', () {
    expect(
      RegExp(r'^\s*schedule:', multiLine: true).hasMatch(workflow),
      isFalse,
      reason: 'A scheduled merge would move main under the release.',
    );
    expect(workflow, isNot(contains('cron:')));
  });

  test('can still be started by hand', () {
    expect(workflow, contains('workflow_dispatch:'));
  });

  test('may dispatch workflows: actions is write, not read', () {
    expect(workflow, contains('actions: write'));
    expect(workflow, isNot(contains('actions: read')));
  });

  test('dispatches ci.yml on main after each merge', () {
    final mergedAt = workflow.indexOf(r'echo "#$n merged"');
    final dispatchAt = workflow.indexOf('gh workflow run ci.yml --ref main');
    final unmergedAt = workflow.indexOf('could not be merged');
    expect(mergedAt, isNonNegative, reason: 'the merge branch was not found.');
    expect(
      dispatchAt,
      greaterThan(mergedAt),
      reason:
          'A merge made with GITHUB_TOKEN starts no CI run; the dispatch '
          'must follow the merge inside the loop.',
    );
    expect(
      dispatchAt,
      lessThan(unmergedAt),
      reason: 'The dispatch belongs to the merged branch, not the failed one.',
    );
  });

  test('a dispatch that fails fails the job', () {
    expect(
      RegExp(
        r'if ! gh workflow run ci\.yml --ref main; then\s+'
        r'echo [^\n]*\s+failed=1\s+fi',
      ).hasMatch(workflow),
      isTrue,
      reason: 'A merged tip with no CI run must not end as a green job.',
    );
  });
}
