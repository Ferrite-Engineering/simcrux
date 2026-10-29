// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_flow/crux_flow.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/models/flow_config.dart';
import 'package:simcrux/features/flow/flow_labels.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/flow/librelane_path_check.dart';

/// The design directories LibreLane cannot run from, the real path checked
/// rather than the configured one, and the refusal said in every locale.
void main() {
  group('check', () {
    test('a space, a tab, a carriage return and a line feed are refused', () {
      for (final (dir, char) in [
        ('/home/u/Getting Started/proj', ' '),
        ('/home/u/a\tb/proj', '\t'),
        ('/home/u/a\rb/proj', '\r'),
        ('/home/u/a\nb/proj', '\n'),
      ]) {
        final refusal = LibreLanePathCheck.check(dir);
        expect(refusal, isNotNull, reason: dir);
        expect(refusal!.character, char);
        expect(refusal.path, dir);
      }
    });

    test('a space is named in words; other characters by code point', () {
      final space = LibreLanePathCheck.check('/a b')!;
      expect(space.isSpace, isTrue);
      expect(space.message, contains('contains a space'));
      expect(space.message, contains('run it from a path without spaces'));
      expect(space.message, endsWith('Path: /a b'));
      expect(LibreLanePathCheck.check('/a\tb')!.characterLabel, 'U+0009');
      expect(LibreLanePathCheck.check('/a"b')!.characterLabel, 'U+0022 (")');
      expect(
        LibreLanePathCheck.check('/a"b')!.message,
        contains('the character U+0022 (")'),
      );
    });

    test('a double quote is refused, and a backslash in a name', () {
      expect(LibreLanePathCheck.check('/home/u/say"hi/proj'), isNotNull);
      expect(
        LibreLanePathCheck.check(r'/home/u/back\slash/proj')?.character,
        r'\',
      );
    }, testOn: '!windows');

    test('other punctuation, non-ASCII letters and a no-break space run', () {
      for (final dir in [
        '/home/u/proj',
        r"/home/u/café-#1_(a,b);x'y$z{w}[v]:u/proj",
        '/home/u/a${String.fromCharCode(0xA0)}b/proj',
        '/home/u/設計/proj',
      ]) {
        expect(LibreLanePathCheck.check(dir), isNull, reason: dir);
      }
    }, testOn: '!windows');

    test('the root prefix and separators are not names', () {
      expect(LibreLanePathCheck.check(p.join(p.separator, 'a', 'b')), isNull);
    });
  });

  group('forEntry', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('ll_path_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    FlowEntry entry(String root, {FlowKind kind = FlowKind.librelane}) =>
        FlowEntry(
          name: 'c',
          kind: kind,
          config: p.join(root, 'librelane', 'config.yaml'),
          projectRoot: root,
        );

    String project(String parent) {
      final root = p.join(tmp.resolveSymbolicLinksSync(), parent, 'proj');
      Directory(p.join(root, 'librelane')).createSync(recursive: true);
      File(
        p.join(root, 'librelane', 'config.yaml'),
      ).writeAsStringSync('DESIGN_NAME: c\n');
      return root;
    }

    test('names the design directory LibreLane would be handed', () {
      final root = project('Getting Started');
      expect(
        LibreLanePathCheck.forEntry(entry(root))?.path,
        p.join(root, 'librelane'),
      );
    });

    test('resolves symlinks: a link without a space into a folder with one '
        'is refused at its real path', () {
      final root = project('Getting Started');
      final link = Link(p.join(tmp.path, 'proj-link'))..createSync(root);
      final refusal = LibreLanePathCheck.forEntry(entry(link.path));
      expect(refusal?.path, p.join(root, 'librelane'));
    }, testOn: '!windows');

    test('a path without one runs; a nextpnr entry is never checked', () {
      expect(LibreLanePathCheck.forEntry(entry(project('plain'))), isNull);
      final spaced = project('Getting Started');
      expect(
        LibreLanePathCheck.forEntry(entry(spaced, kind: FlowKind.nextpnr)),
        isNull,
      );
    });
  });

  test('the refusal is said in every locale the app ships, naming the '
      'path', () {
    const space = LibreLaneUnsupportedPath(
      path: '/home/u/Getting Started/proj/librelane',
      character: ' ',
    );
    const quote = LibreLaneUnsupportedPath(
      path: '/home/u/say"hi/proj/librelane',
      character: '"',
    );
    final seen = <String>{};
    for (final locale in L10N.supportedLocales) {
      final l10n = lookupL10N(locale);
      final spaceText = FlowLabels.unsupportedPath(l10n, space);
      final quoteText = FlowLabels.unsupportedPath(l10n, quote);
      expect(spaceText, contains(space.path), reason: '$locale');
      expect(spaceText, contains('LibreLane'), reason: '$locale');
      expect(quoteText, contains(quote.path), reason: '$locale');
      expect(quoteText, contains('U+0022 (")'), reason: '$locale');
      for (final text in [spaceText, quoteText]) {
        for (final dash in const [0x2013, 0x2014]) {
          expect(
            text,
            isNot(contains(String.fromCharCode(dash))),
            reason: '$locale',
          );
        }
      }
      if (locale != const Locale('zh', 'CN')) seen.add(spaceText);
    }
    // en, ja, ko and zh each say it in their own words.
    expect(seen, hasLength(4));
    expect(
      FlowLabels.unsupportedPath(lookupL10N(const Locale('en')), space),
      space.message,
      reason: 'the GUI and the CLI say the same thing in English',
    );
  });
}
