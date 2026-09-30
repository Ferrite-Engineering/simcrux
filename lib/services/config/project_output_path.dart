// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// Where a project file may send the files a `--ci` run creates.
///
/// `output.results_path` and `output.summary_path` name files that a `--ci`
/// run creates, and truncates if they exist. A project file is untrusted
/// input: `.yaml` and `.yml` are registered SimCrux document types, so one
/// arrives by double-click, by clone or by download. Without a rule,
/// `results_path: ../../.zshrc` or an absolute path would have a run
/// overwrite any file the user can write, with the project-tooling gate
/// closed.
///
/// The rule: the path, resolved against the directory holding the project
/// file, stays strictly inside that directory, both as written and once
/// symbolic links are followed. Writing anywhere else is a trust decision,
/// so it sits behind the same project-tooling gate as the keys that choose
/// an executable (`--allow-project-tooling` on the CLI).
///
/// It is applied twice: by the loader, which refuses the project with the
/// value's line and column, and by the writer, on the path it is about to
/// open, for a config built in code or a directory that changed between
/// the load and the run.
library;

import 'package:crux_cxp/crux_cxp.dart' show CxpPathContainment;
import 'package:path/path.dart' as p;

/// [configured] resolved against [projectDir]: an absolute path as it is, a
/// relative one joined onto the project directory, both normalised.
///
/// The result is the exact string a writer opens and the checks judge.
/// Normalising here, before the check, is what makes that true: a writer
/// handed `link/../x` would let the operating system follow `link` before
/// the `..`, which is not the path a textual check approved.
String resolveProjectOutputPath(String configured, String projectDir) {
  final root = p.normalize(p.absolute(projectDir));
  return p.normalize(
    p.isAbsolute(configured) ? configured : p.join(root, configured),
  );
}

/// Why [configured] may not be written for the project in [projectDir], or
/// null when it may.
///
/// [configured] is a value from the project file (relative to the project
/// directory, or absolute) or an already resolved path.
String? projectOutputPathProblem(String configured, String projectDir) {
  final root = p.normalize(p.absolute(projectDir));
  final lexical = _lexicalProblem(configured, root);
  if (lexical != null) return lexical;
  final resolved = resolveProjectOutputPath(configured, root);
  // The filesystem's reading of the path, not the text's: every existing
  // prefix has its links followed, and a path that cannot be resolved (a
  // dangling link, which a write would create wherever it points) is
  // refused. CXP receivers apply the same "inside these directories, as the
  // filesystem would reach it" rule to paths a peer asks them to open, so it
  // is borrowed rather than written a second time.
  final containment = CxpPathContainment(roots: () => <String>[root]);
  if (!containment.allows(resolved)) {
    return 'following its symbolic links leads outside the project '
        'directory, or it cannot be resolved';
  }
  return null;
}

/// The textual half of [projectOutputPathProblem].
///
/// A relative value is judged under both separator conventions, so that a
/// project file that loads on macOS or Linux cannot climb out of the
/// project on Windows, where `..\` is a parent directory.
String? _lexicalProblem(String configured, String root) {
  if (configured.trim().isEmpty) return 'it is empty';
  if (configured.contains('\u0000')) return 'it contains a NUL byte';
  if (p.posix.isAbsolute(configured) || p.windows.isAbsolute(configured)) {
    if (!p.isAbsolute(configured)) {
      return 'it is an absolute path on another operating system';
    }
    final normalized = p.normalize(configured);
    if (p.equals(root, normalized)) return _namesTheProjectDirectory;
    if (!p.isWithin(root, normalized)) {
      return 'it is an absolute path outside the project directory';
    }
    return null;
  }
  const posixBase = '/project';
  const windowsBase = r'C:\project';
  final posixResolved = p.posix.normalize(p.posix.join(posixBase, configured));
  final windowsResolved = p.windows.normalize(
    p.windows.join(windowsBase, configured),
  );
  if (posixResolved == posixBase ||
      p.windows.equals(windowsResolved, windowsBase)) {
    return _namesTheProjectDirectory;
  }
  if (!p.posix.isWithin(posixBase, posixResolved) ||
      !p.windows.isWithin(windowsBase, windowsResolved)) {
    return 'it climbs out of the project directory';
  }
  return null;
}

const String _namesTheProjectDirectory =
    'it names the project directory itself, not a file inside it';

/// Thrown by a writer asked to create a project output file outside the
/// project directory.
class ProjectOutputPathException implements Exception {
  /// Creates a [ProjectOutputPathException].
  const ProjectOutputPathException({
    required this.path,
    required this.projectDir,
    required this.problem,
  });

  /// The path the writer refused to open.
  final String path;

  /// The directory it had to stay inside.
  final String projectDir;

  /// Why it may not be written, from [projectOutputPathProblem].
  final String problem;

  @override
  String toString() =>
      'refused to write $path: $problem. A project output file must stay '
      'inside the project directory $projectDir; pass '
      '`--allow-project-tooling` to write elsewhere.';
}
