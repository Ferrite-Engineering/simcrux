// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// What a `project_id:` may look like: letters, digits, `.`, `_` and `-`,
/// 1 to 64 characters.
///
/// The one string the shared team database pools runs under, written into
/// a primary key on every machine that pushes, so it is held to a set that
/// needs no quoting anywhere (a URL, a SQL literal, a file name, a CI
/// variable). The loader applies it to the file's `project_id:` and the
/// headless `push-results --project` applies the same rule, which is why it
/// lives here, in the Flutter-free domain layer both can reach.
final RegExp kProjectIdPattern = RegExp(r'^[A-Za-z0-9._-]{1,64}$');

/// The sentence a rejected `project_id` (file or `--project`) ends with.
const String kProjectIdRule =
    'Use 1 to 64 letters, digits, ".", "_" or "-", the same value in '
    '`simcrux.yaml` and in `push-results --project`.';
