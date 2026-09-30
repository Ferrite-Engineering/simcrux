// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A macOS runner that registers document types must deliver them to Dart.
///
/// `CFBundleDocumentTypes` in `Info.plist` is what makes Finder offer SimCrux
/// for a file and launch it on a double-click. The file then arrives as an
/// Apple Event, and only `application(_:open:)` in the app delegate receives
/// it. Declaring the types without the handler is worse than not declaring
/// them: the file looks openable, the app launches, and the file is dropped
/// with no error, because nothing failed. That shipped, and no test noticed,
/// because every test drives the app from Dart.
///
/// So this pins the three native facts the Dart half
/// (`lib/core/platform/incoming_file_service.dart`) depends on: the delegate
/// overrides the open entry point, the main window registers the channels,
/// and the channel names match the Dart side's. Whether the Swift compiles is
/// proved by the macOS build.
void main() {
  final plist = File('macos/Runner/Info.plist');
  final delegate = File('macos/Runner/AppDelegate.swift');
  final window = File('macos/Runner/MainFlutterWindow.swift');
  final dart = File('lib/core/platform/incoming_file_service.dart');

  test('the runner registers document types, so the rest applies', () {
    expect(
      plist.readAsStringSync(),
      contains('<key>CFBundleDocumentTypes</key>'),
      reason:
          'Info.plist no longer registers document types. If that is '
          'intended, the handler below can go with it; if not, restore them.',
    );
  });

  test('no document type claims a system content type', () {
    // `LSItemContentTypes` naming a `public.*` type makes SimCrux a
    // candidate for every file of that type and every type another app
    // declares as conforming to it: `public.yaml` would offer SimCrux for
    // every YAML-based format on the machine. SimCrux claims its own types
    // (`com.simcrux.*`, the suite's `app.edacrux.project`) by content type,
    // and `.yaml`/`.yml` by extension only.
    expect(
      _contentTypeClaims(plist.readAsStringSync()).where(
        (type) => type.startsWith('public.'),
      ),
      isEmpty,
    );
  });

  test('a shared extension is claimed at Alternate rank, never as its '
      'owner', () {
    // `.yaml` and `.yml` belong to everybody: a repository full of them has
    // one `simcrux.yaml` in it, and a regression manager has no business
    // becoming the default application for the rest. Alternate keeps SimCrux
    // in the Open With list, and a user who wants a double-click to open it
    // can still say so in Get Info. Owner rank (the default when the key is
    // absent) is for SimCrux's own extensions only.
    //
    // `.crux-project` is shared for a different reason — it is the suite's
    // own manifest and all four products register it — and the decision
    // taken for all four is that none of them owns it, so macOS asks the
    // user which to open one with rather than ranking them itself.
    for (final type in _documentTypes(plist.readAsStringSync())) {
      final shared = type.extensions.any(_sharedExtensions.contains);
      final own = type.extensions.any(_ownExtensions.contains);
      if (shared) {
        expect(
          type.rank,
          'Alternate',
          reason:
              '${type.extensions} is a shared extension, so this entry must '
              'set LSHandlerRank to Alternate.',
        );
      }
      if (own) {
        expect(
          type.rank,
          isNot('Alternate'),
          reason:
              "${type.extensions} is SimCrux's own extension; at Alternate "
              'rank a double-click would open whatever else claimed it.',
        );
      }
    }
  });

  test('the app delegate receives the files macOS opens', () {
    expect(
      _code(delegate),
      contains(
        'override func application(_ application: NSApplication, '
        'open urls: [URL])',
      ),
      reason:
          'AppDelegate.swift does not override application(_:open:), so a '
          'double-clicked file is dropped and the app opens empty.',
    );
    expect(_code(delegate), contains('IncomingFilePlugin.shared.handle'));
  });

  test('the main window registers the channels Dart listens on', () {
    expect(
      _code(window),
      contains('IncomingFilePlugin.shared.register(with:'),
      reason:
          'MainFlutterWindow.swift does not register IncomingFilePlugin, so '
          'Dart asks for the opened file on a channel nobody answers.',
    );
  });

  test('both sides name the same channels', () {
    final swift = delegate.readAsStringSync();
    final names = RegExp(
      r"'(com\.simcrux/incoming_file(?:_stream)?)'",
    ).allMatches(dart.readAsStringSync()).map((m) => m.group(1)!).toSet();
    expect(names, hasLength(2), reason: 'the Dart side names two channels');
    for (final name in names) {
      expect(
        swift,
        contains('"$name"'),
        reason: 'AppDelegate.swift does not name the channel $name.',
      );
    }
  });
}

/// [file]'s Swift with line comments removed, so a commented-out handler
/// does not count as one.
String _code(File file) => file
    .readAsLinesSync()
    .where((line) => !line.trimLeft().startsWith('//'))
    .join('\n');

/// Every content type named under a document type's `LSItemContentTypes`.
List<String> _contentTypeClaims(String plist) {
  final out = <String>[];
  for (final match in RegExp(
    r'<key>LSItemContentTypes</key>\s*<array>(.*?)</array>',
    dotAll: true,
  ).allMatches(plist)) {
    out.addAll(
      RegExp(
        '<string>([^<]+)</string>',
      ).allMatches(match.group(1)!).map((m) => m.group(1)!),
    );
  }
  return out;
}

/// Extensions SimCrux shares: `.yaml`/`.yml` with every other tool that
/// reads them, and `.crux-project` with the three sibling products that open
/// the same design manifest.
const _sharedExtensions = {'yaml', 'yml', 'crux-project'};

/// Extensions SimCrux invented, and may own.
const _ownExtensions = {'simcrux-session', 'simcrux-workspace'};

/// Each `CFBundleDocumentTypes` entry: the extensions it registers and the
/// `LSHandlerRank` it asks for (`Owner` when the key is absent, which is
/// what Launch Services assumes for an app that declares the type).
List<({List<String> extensions, String rank})> _documentTypes(String plist) {
  final types = <({List<String> extensions, String rank})>[];
  final start = plist.indexOf('<key>CFBundleDocumentTypes</key>');
  if (start == -1) return types;
  final region = _firstArrayAfter(plist, start);
  for (final entry in RegExp(
    '<dict>(.*?)</dict>',
    dotAll: true,
  ).allMatches(region)) {
    final body = entry.group(1)!;
    final extensions = <String>[];
    final extensionsAt = body.indexOf('<key>CFBundleTypeExtensions</key>');
    if (extensionsAt != -1) {
      extensions.addAll(
        RegExp('<string>([^<]+)</string>')
            .allMatches(_firstArrayAfter(body, extensionsAt))
            .map((m) => m.group(1)!),
      );
    }
    final rank = RegExp(
      r'<key>LSHandlerRank</key>\s*<string>([^<]+)</string>',
    ).firstMatch(body)?.group(1);
    types.add((extensions: extensions, rank: rank ?? 'Owner'));
  }
  return types;
}

/// The first `<array>...</array>` after [at], nesting-aware, so a nested
/// array inside a document type does not end the outer one early.
String _firstArrayAfter(String source, int at) {
  var i = source.indexOf('<array>', at);
  if (i == -1) return '';
  final from = i;
  var depth = 0;
  while (i < source.length) {
    final open = source.indexOf('<array>', i);
    final close = source.indexOf('</array>', i);
    if (close == -1) return source.substring(from);
    if (open != -1 && open < close) {
      depth++;
      i = open + '<array>'.length;
    } else {
      depth--;
      i = close + '</array>'.length;
      if (depth == 0) break;
    }
  }
  return source.substring(from, i);
}
