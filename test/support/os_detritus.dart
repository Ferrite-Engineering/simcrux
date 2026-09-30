// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// Filenames the operating system drops into a directory as a side effect
/// of a human *looking* at it, which no fixture guard should ever fail on.
///
/// macOS writes `.DS_Store` the moment a folder is opened in Finder, so
/// browsing the committed fixture corpus — the single most ordinary thing
/// a contributor does with it — turned the suite red. Windows Explorer
/// does the same with `Thumbs.db` and `desktop.ini`.
///
/// **Named individually on purpose, rather than skipping every dotfile.**
/// A blanket `startsWith('.')` would also wave through the strays a
/// fixture guard exists to catch: a stale `.simcrux/` runtime cache, an
/// editor's `.swp`, or a config accidentally written as `.simcrux.yaml`
/// (the dotfile spelling this project explicitly forbids — see
/// `CLAUDE.md` and crux-shared ADR 0001). Those must still fail. Only the
/// files the OS writes behind the user's back are exempt, and adding to
/// this list should require the same justification.
const Set<String> kOsDetritusFilenames = <String>{
  '.DS_Store',
  'Thumbs.db',
  'desktop.ini',
};

/// Whether [basename] is an OS-generated file rather than project content.
///
/// Takes a bare filename, not a path — callers pass `p.basename(...)`.
bool isOsDetritus(String basename) => kOsDetritusFilenames.contains(basename);
