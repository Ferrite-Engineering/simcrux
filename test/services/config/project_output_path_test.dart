// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/services/config/project_output_path.dart';

/// The containment rule for the files a `--ci` run creates and truncates.
///
/// The textual shapes run on any host. The symbolic-link shapes run against
/// real links in a real temp directory, because the rule's whole point is to
/// read the path the way the filesystem will; Windows is skipped for those,
/// where creating a link needs a privilege CI runners do not have.
void main() {
  late Directory tmp;
  late String project;

  setUp(() {
    // Resolved, so a platform temp directory that is itself reached
    // through a link (macOS `/var` → `/private/var`) does not make every
    // expectation below depend on which spelling a path happens to use.
    tmp = Directory(
      Directory.systemTemp
          .createTempSync('simcrux_output_path_')
          .resolveSymbolicLinksSync(),
    );
    project = p.join(tmp.path, 'project');
    Directory(project).createSync();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('resolveProjectOutputPath', () {
    test('joins a relative path onto the project directory', () {
      expect(
        resolveProjectOutputPath('build/results.ndjson', project),
        p.join(project, 'build', 'results.ndjson'),
      );
    });

    test('keeps an absolute path, normalised', () {
      final abs = p.join(project, 'out', '..', 'results.ndjson');
      expect(
        resolveProjectOutputPath(abs, project),
        p.join(project, 'results.ndjson'),
      );
    });
  });

  group('projectOutputPathProblem allows', () {
    for (final ok in const [
      'results.ndjson',
      'build/results.ndjson',
      'build/nested/deeper/results.summary.json',
      'build/../results.ndjson',
    ]) {
      test('"$ok"', () {
        expect(projectOutputPathProblem(ok, project), isNull);
      });
    }

    test('an absolute path inside the project directory', () {
      expect(
        projectOutputPathProblem(
          p.join(project, 'build', 'results.ndjson'),
          project,
        ),
        isNull,
      );
    });
  });

  group('projectOutputPathProblem refuses', () {
    test('a path that climbs out with ../', () {
      expect(
        projectOutputPathProblem('../../.zshrc', project),
        contains('climbs out'),
      );
      expect(
        projectOutputPathProblem('build/../../victim.txt', project),
        contains('climbs out'),
      );
    });

    test(r'a path that climbs out with ..\ on any host', () {
      // On Windows `..\` is a parent directory. Refusing it everywhere
      // keeps a project that loads on macOS from escaping on Windows.
      expect(
        projectOutputPathProblem(r'..\..\victim.txt', project),
        contains('climbs out'),
      );
    });

    test('an absolute path outside the project directory', () {
      expect(
        projectOutputPathProblem(p.join(tmp.path, 'victim.txt'), project),
        contains('absolute path outside'),
      );
    });

    test(
      'an absolute path written for another operating system',
      () {
        expect(
          projectOutputPathProblem(r'C:\Users\me\victim.txt', project),
          contains('another operating system'),
        );
      },
      skip: Platform.isWindows ? 'absolute on this host' : false,
    );

    test('the project directory itself', () {
      expect(projectOutputPathProblem('.', project), contains('itself'));
      expect(projectOutputPathProblem(project, project), contains('itself'));
    });

    test('an empty value and a NUL byte', () {
      expect(projectOutputPathProblem('', project), contains('empty'));
      expect(projectOutputPathProblem('  ', project), contains('empty'));
      expect(
        projectOutputPathProblem('a\u0000b', project),
        contains('NUL'),
      );
    });
  });

  group(
    'symbolic links',
    () {
      late String outside;

      setUp(() {
        outside = p.join(tmp.path, 'outside');
        Directory(outside).createSync();
      });

      test('a directory link that leads out is refused', () {
        Link(p.join(project, 'build')).createSync(outside);
        expect(
          projectOutputPathProblem('build/results.ndjson', project),
          contains('symbolic links'),
        );
      });

      test('a file link that leads out is refused', () {
        final victim = File(p.join(outside, 'victim.txt'))
          ..writeAsStringSync('keep me');
        Link(p.join(project, 'results.ndjson')).createSync(victim.path);
        expect(
          projectOutputPathProblem('results.ndjson', project),
          contains('symbolic links'),
        );
      });

      test('a dangling link is refused: a write would create its target', () {
        Link(
          p.join(project, 'results.ndjson'),
        ).createSync(p.join(outside, 'not-yet.txt'));
        expect(
          projectOutputPathProblem('results.ndjson', project),
          isNotNull,
        );
      });

      test('a link that stays inside the project is allowed', () {
        final real = Directory(p.join(project, 'real'))..createSync();
        Link(p.join(project, 'build')).createSync(real.path);
        expect(
          projectOutputPathProblem('build/results.ndjson', project),
          isNull,
        );
      });

      test('a project reached through a link is judged by its target', () {
        final alias = p.join(tmp.path, 'alias');
        Link(alias).createSync(project);
        expect(
          projectOutputPathProblem('build/results.ndjson', alias),
          isNull,
        );
      });
    },
    skip: Platform.isWindows ? 'creating links needs a privilege' : false,
  );

  test('the exception names the path, the project and the remedy', () {
    const e = ProjectOutputPathException(
      path: '/elsewhere/victim.txt',
      projectDir: '/work/project',
      problem: 'it is an absolute path outside the project directory',
    );
    expect(
      e.toString(),
      allOf(
        contains('/elsewhere/victim.txt'),
        contains('/work/project'),
        contains('--allow-project-tooling'),
      ),
    );
  });
}
