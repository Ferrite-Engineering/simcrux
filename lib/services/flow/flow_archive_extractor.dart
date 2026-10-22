// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// Why a zipped run was not extracted.
enum FlowArchiveRefusal {
  /// The file is not a zip archive SimCrux can read.
  unreadable,

  /// More entries than [FlowArchiveLimits.maxEntries].
  tooManyEntries,

  /// One entry is larger than [FlowArchiveLimits.maxEntryBytes], declared or
  /// as it decompresses.
  entryTooLarge,

  /// The entries together are larger than [FlowArchiveLimits.maxTotalBytes],
  /// declared or as they decompress.
  totalTooLarge,

  /// An entry names an absolute path (`/etc/x`, `C:\x`, `\\host\x`).
  absolutePath,

  /// An entry's path has a `..` segment.
  parentSegment,

  /// An entry is a symbolic link.
  symlink,

  /// An entry's name is empty, holds a NUL, or nests deeper than
  /// [FlowArchiveLimits.maxDepth].
  unsafeName,
}

/// The bounds one extraction stays within.
@immutable
class FlowArchiveLimits {
  /// Creates the limits.
  const FlowArchiveLimits({
    this.maxArchiveBytes = 4 << 30,
    this.maxEntries = 50000,
    this.maxEntryBytes = 1 << 30,
    this.maxTotalBytes = 4 << 30,
    this.maxDepth = 64,
  });

  /// The defaults: a Tiny Tapeout `GDS_logs` artifact is a few hundred
  /// megabytes and a few thousand entries.
  static const FlowArchiveLimits defaults = FlowArchiveLimits();

  /// The largest zip file opened at all.
  final int maxArchiveBytes;

  /// The most entries one archive may hold.
  final int maxEntries;

  /// The largest one entry may be once decompressed.
  final int maxEntryBytes;

  /// The largest every entry together may be once decompressed.
  final int maxTotalBytes;

  /// The most path segments one entry's name may have.
  final int maxDepth;
}

/// One extraction: the directory the archive's runs were written to, or why
/// nothing was.
@immutable
class FlowArchiveExtraction {
  /// Creates the result.
  const FlowArchiveExtraction({this.directory, this.refusal, this.message});

  /// The directory holding the extracted entries, when extraction finished.
  final String? directory;

  /// Why the archive was refused, when it was.
  final FlowArchiveRefusal? refusal;

  /// The reason in words, naming the entry at fault.
  final String? message;

  /// Whether the archive was extracted.
  bool get ok => directory != null;
}

/// Extracts a zipped CI artifact (the Tiny Tapeout `GDS_logs` case) into
/// SimCrux's own scratch, so the run inside can be ingested.
///
/// **Contained and bounded.** The archive is checked whole before anything
/// is written: an entry with an absolute path, a `..` segment, a NUL, or a
/// symbolic link refuses the archive, as do more entries than the limit or
/// declared sizes over it. Decompression is then counted as it happens, so
/// an entry that lies about its size stops at the cap rather than filling the
/// disk. Nothing is ever written outside the extraction directory, and the
/// project is never written to at all.
///
/// **Stable and never deleting.** The directory is named by the archive's
/// path, size and modification time, so extracting the same artifact twice
/// reuses the first extraction (and ingest files it under the same run id).
/// A finished extraction carries a marker; a directory without one (an
/// extraction that was refused part way) is left alone and a new sibling is
/// used.
class FlowArchiveExtractor {
  /// Creates the extractor. [scratch] is the directory extractions go under;
  /// the system temporary directory's `simcrux/ingest/` when null.
  const FlowArchiveExtractor({
    this.scratch,
    this.limits = FlowArchiveLimits.defaults,
  });

  /// Where extractions go.
  final String? scratch;

  /// The bounds every extraction stays within.
  final FlowArchiveLimits limits;

  /// The file a finished extraction writes last.
  static const String kCompleteMarker = '.simcrux-extracted';

  /// Extracts the zip at [zipPath], which the caller has already contained.
  Future<FlowArchiveExtraction> extract(String zipPath) async {
    final zip = File(zipPath);
    final int length;
    final DateTime modified;
    try {
      length = zip.lengthSync();
      modified = zip.lastModifiedSync();
    } on FileSystemException catch (e) {
      return _refuse(FlowArchiveRefusal.unreadable, e.message);
    }
    if (length > limits.maxArchiveBytes) {
      return _refuse(
        FlowArchiveRefusal.totalTooLarge,
        'the archive is ${_mib(length)} MiB, over the '
        '${_mib(limits.maxArchiveBytes)} MiB limit',
      );
    }

    final InputFileStream input;
    try {
      input = InputFileStream(zipPath);
    } on Object catch (e) {
      return _refuse(FlowArchiveRefusal.unreadable, '$e');
    }
    try {
      final Archive archive;
      try {
        archive = ZipDecoder().decodeStream(input);
      } on Object {
        return _refuse(
          FlowArchiveRefusal.unreadable,
          'the file is not a zip archive SimCrux can read',
        );
      }
      // A file that is not a zip decodes to no entries rather than failing.
      if (archive.files.isEmpty) {
        return _refuse(
          FlowArchiveRefusal.unreadable,
          'the file is not a zip archive, or holds no entries',
        );
      }
      final planned = plan(archive);
      if (planned.refusal != null) return planned.refusal!;

      final dest = _destination(zipPath, length, modified);
      if (dest == null) {
        return _refuse(
          FlowArchiveRefusal.unreadable,
          'no extraction directory could be made',
        );
      }
      if (File(p.join(dest, kCompleteMarker)).existsSync()) {
        return FlowArchiveExtraction(directory: dest);
      }
      return _write(archive, planned.entries, dest);
    } finally {
      await input.close();
    }
  }

  /// Checks every entry of [archive] before anything is written: the names,
  /// the types, the count and the declared sizes. Returns the files to write
  /// (directory entries are implied by them), or the refusal.
  @visibleForTesting
  ({List<(ArchiveFile, List<String>)> entries, FlowArchiveExtraction? refusal})
  plan(Archive archive) {
    final entries = <(ArchiveFile, List<String>)>[];
    if (archive.files.length > limits.maxEntries) {
      return (
        entries: entries,
        refusal: _refuse(
          FlowArchiveRefusal.tooManyEntries,
          'the archive holds ${archive.files.length} entries, over the '
          '${limits.maxEntries} limit',
        ),
      );
    }
    var declared = 0;
    for (final entry in archive.files) {
      final segments = entrySegments(entry.name);
      if (segments.refusal != null) {
        return (
          entries: entries,
          refusal: _refuse(
            segments.refusal!,
            '"${_printable(entry.name)}": ${_why(segments.refusal!)}',
          ),
        );
      }
      if (entry.isSymbolicLink || (entry.mode & 0xf000) == 0xa000) {
        return (
          entries: entries,
          refusal: _refuse(
            FlowArchiveRefusal.symlink,
            '"${_printable(entry.name)}" is a symbolic link',
          ),
        );
      }
      if (!entry.isFile) continue;
      if (entry.size > limits.maxEntryBytes) {
        return (
          entries: entries,
          refusal: _refuse(
            FlowArchiveRefusal.entryTooLarge,
            '"${_printable(entry.name)}" is ${_mib(entry.size)} MiB, over '
            'the ${_mib(limits.maxEntryBytes)} MiB limit',
          ),
        );
      }
      declared += entry.size;
      if (declared > limits.maxTotalBytes) {
        return (
          entries: entries,
          refusal: _refuse(
            FlowArchiveRefusal.totalTooLarge,
            'the entries come to more than '
            '${_mib(limits.maxTotalBytes)} MiB',
          ),
        );
      }
      entries.add((entry, segments.segments));
    }
    return (entries: entries, refusal: null);
  }

  /// The path segments [name] extracts to, or why it may not be extracted.
  ///
  /// Both separators count (a zip written on Windows uses `\`); empty and
  /// `.` segments are dropped.
  @visibleForTesting
  ({List<String> segments, FlowArchiveRefusal? refusal}) entrySegments(
    String name,
  ) {
    const none = <String>[];
    if (name.isEmpty || name.contains('\u0000')) {
      return (segments: none, refusal: FlowArchiveRefusal.unsafeName);
    }
    final slashed = name.replaceAll(r'\', '/');
    if (slashed.startsWith('/') ||
        RegExp('^[A-Za-z]:').hasMatch(slashed) ||
        slashed.startsWith('~')) {
      return (segments: none, refusal: FlowArchiveRefusal.absolutePath);
    }
    final segments = <String>[];
    for (final segment in slashed.split('/')) {
      if (segment.isEmpty || segment == '.') continue;
      if (segment == '..') {
        return (segments: none, refusal: FlowArchiveRefusal.parentSegment);
      }
      segments.add(segment);
    }
    if (segments.isEmpty || segments.length > limits.maxDepth) {
      return (segments: none, refusal: FlowArchiveRefusal.unsafeName);
    }
    return (segments: segments, refusal: null);
  }

  FlowArchiveExtraction _write(
    Archive archive,
    List<(ArchiveFile, List<String>)> entries,
    String dest,
  ) {
    final root = p.normalize(Directory(dest).absolute.path);
    var written = 0;
    for (final (entry, segments) in entries) {
      final target = p.normalize(p.joinAll(<String>[root, ...segments]));
      // Belt and braces: the names were checked, and this is where a check
      // that missed something would let a write escape.
      if (!p.isWithin(root, target)) {
        return _refuse(
          FlowArchiveRefusal.parentSegment,
          '"${_printable(entry.name)}" resolves outside the extraction',
        );
      }
      final remaining = limits.maxTotalBytes - written;
      final cap = remaining < limits.maxEntryBytes
          ? remaining
          : limits.maxEntryBytes;
      try {
        Directory(p.dirname(target)).createSync(recursive: true);
        final out = _BoundedFileOutput(target, cap);
        try {
          entry.decompress(out);
        } finally {
          out.closeSync();
        }
        written += out.length;
      } on _OverCap {
        return remaining < limits.maxEntryBytes
            ? _refuse(
                FlowArchiveRefusal.totalTooLarge,
                'the entries decompress to more than '
                '${_mib(limits.maxTotalBytes)} MiB',
              )
            : _refuse(
                FlowArchiveRefusal.entryTooLarge,
                '"${_printable(entry.name)}" decompresses to more than '
                '${_mib(limits.maxEntryBytes)} MiB',
              );
      } on Object catch (e) {
        return _refuse(
          FlowArchiveRefusal.unreadable,
          '"${_printable(entry.name)}": $e',
        );
      }
    }
    try {
      File(p.join(root, kCompleteMarker)).writeAsStringSync('');
    } on FileSystemException catch (e) {
      return _refuse(FlowArchiveRefusal.unreadable, e.message);
    }
    return FlowArchiveExtraction(directory: root);
  }

  /// The directory this archive extracts to: a finished extraction of the
  /// same file when there is one, else a fresh one.
  String? _destination(String zipPath, int length, DateTime modified) {
    final base =
        scratch ?? p.join(Directory.systemTemp.path, 'simcrux', 'ingest');
    final String resolved;
    try {
      resolved = File(zipPath).resolveSymbolicLinksSync();
    } on FileSystemException {
      return null;
    }
    final key = _fnv64('$resolved|$length|${modified.millisecondsSinceEpoch}');
    final stem = '${_safeStem(p.basenameWithoutExtension(resolved))}-$key';
    for (var n = 1; n <= 100; n++) {
      final candidate = p.join(base, n == 1 ? stem : '$stem-$n');
      final dir = Directory(candidate);
      if (!dir.existsSync()) {
        try {
          dir.createSync(recursive: true);
        } on FileSystemException {
          return null;
        }
        return candidate;
      }
      if (File(p.join(candidate, kCompleteMarker)).existsSync()) {
        return candidate;
      }
    }
    return null;
  }

  static FlowArchiveExtraction _refuse(
    FlowArchiveRefusal refusal,
    String message,
  ) => FlowArchiveExtraction(refusal: refusal, message: message);

  static String _why(FlowArchiveRefusal refusal) => switch (refusal) {
    FlowArchiveRefusal.absolutePath => 'an absolute path',
    FlowArchiveRefusal.parentSegment => 'a path with a ".." segment',
    FlowArchiveRefusal.symlink => 'a symbolic link',
    _ => 'a name SimCrux will not write',
  };

  static int _mib(int bytes) => (bytes / (1 << 20)).ceil();

  static String _printable(String name) {
    final clean = name.replaceAll(RegExp(r'[\u0000-\u001f]'), '?');
    return clean.length <= 120 ? clean : '${clean.substring(0, 120)}...';
  }

  static String _safeStem(String stem) {
    final safe = stem.replaceAll(RegExp('[^A-Za-z0-9._-]'), '_');
    if (safe.isEmpty) return 'artifact';
    return safe.length <= 40 ? safe : safe.substring(0, 40);
  }

  static String _fnv64(String text) {
    // Two 32-bit FNV-1a passes (forwards and backwards) for 64 bits of key.
    String pass(Iterable<int> units) {
      var hash = 0x811c9dc5;
      for (final unit in units) {
        hash ^= unit;
        hash = (hash * 0x01000193) & 0xffffffff;
      }
      return hash.toRadixString(16).padLeft(8, '0');
    }

    return '${pass(text.codeUnits)}${pass(text.codeUnits.reversed)}';
  }
}

/// Thrown by [_BoundedFileOutput] when a write would pass its cap.
class _OverCap implements Exception {
  const _OverCap();
}

/// A file output that stops at [cap] bytes: every write path the inflater
/// uses goes through [writeByte] or [writeBytes].
class _BoundedFileOutput extends OutputFileStream {
  _BoundedFileOutput(String path, this.cap)
    : super.withFileHandle(FileHandle(path, mode: FileAccess.write));

  final int cap;

  void _check(int more) {
    if (length + more > cap) throw const _OverCap();
  }

  @override
  void writeByte(int value) {
    _check(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _check(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    _check(stream.length);
    super.writeStream(stream);
  }
}
