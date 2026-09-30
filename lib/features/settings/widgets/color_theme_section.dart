// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:crux_theme/crux_theme.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/core/help_urls.dart';
import 'package:simcrux/core/theme/theme_pack_directory.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// Optional override for the `.crux-theme.json` install directory used
/// by the embedded [ThemePackBrowser]. Defaults to `{appSupportDir}/themes`.
typedef PackDirectoryResolver = Future<Directory> Function();

/// Settings → Appearance: drops `crux_theme`'s [ThemeAppearanceSection]
/// composer into SimCrux. Mirrors the WaveCrux / NetCrux / LintCrux
/// adopter pattern — activation flows through `cruxColorThemeProvider`,
/// whose SimCrux notifier override writes preset / token changes back
/// to `AppSettings.core.activeThemeName` + `core.themeOverrides`.
///
/// Tests may inject [store] (an `InMemoryThemePackStore` keeps the
/// filesystem out of the widget tree entirely), [packDirectoryResolver]
/// (to point the default `DirectoryThemePackStore` at a temp dir), or
/// [pickPackDocument] / [savePackDocument] to keep `path_provider` and
/// the desktop file picker out of the widget tree.
class ColorThemeSection extends ConsumerStatefulWidget {
  /// Creates the Settings → Appearance section.
  const ColorThemeSection({
    this.store,
    this.packDirectoryResolver,
    this.pickPackDocument,
    this.savePackDocument,
    super.key,
  });

  /// Optional pre-built pack store. When supplied, [packDirectoryResolver]
  /// is ignored and the browser renders immediately (no async resolve).
  final ThemePackStore? store;

  /// Resolves the directory backing the default [DirectoryThemePackStore].
  final PackDirectoryResolver? packDirectoryResolver;

  /// Optional override for the import picker. Defaults to a desktop
  /// `file_picker` invocation accepting `.json` files, returning the
  /// picked document's *text*.
  final PickPackDocument? pickPackDocument;

  /// Optional override for the export flow. Defaults to a `file_picker`
  /// save dialog suggesting a `.crux-theme.json` name; returns the path
  /// the document landed at, for the confirmation message.
  final SavePackDocument? savePackDocument;

  @override
  ConsumerState<ColorThemeSection> createState() => _ColorThemeSectionState();
}

class _ColorThemeSectionState extends ConsumerState<ColorThemeSection> {
  ThemePackStore? _store;

  @override
  void initState() {
    super.initState();
    final injected = widget.store;
    if (injected != null) {
      _store = injected;
      return;
    }
    unawaited(_resolveStore());
  }

  Future<void> _resolveStore() async {
    final resolver = widget.packDirectoryResolver ?? simcruxThemePackDirectory;
    Directory dir;
    try {
      dir = await resolver();
    } on Object {
      dir = Directory.systemTemp;
    }
    if (!mounted) return;
    setState(() => _store = DirectoryThemePackStore(directory: dir));
  }

  @override
  Widget build(BuildContext context) {
    final store = _store;
    if (store == null) {
      return const SizedBox(height: 24);
    }
    final theme = Theme.of(context);
    const strings = ThemeAppearanceStringsEn();
    final categories = ThemeRegistry.instance.registeredCategories;

    // Composed from the individual `crux_theme` widgets rather than the
    // bundled ThemeAppearanceSection composer, whose "Appearance" heading
    // would duplicate the Settings → Appearance category title. Preset cards,
    // token swatches, and pack rows are *data*, pinned to the value surface
    // (surfaceContainerHighest) to read distinctly from a section card.
    final dataSurface = theme.copyWith(
      cardTheme: theme.cardTheme.copyWith(
        color: theme.colorScheme.surfaceContainerHighest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
    );

    return Theme(
      data: dataSurface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _SubsectionLabel(strings.presetSectionHeading),
              const SizedBox(width: 4),
              CruxHelpLink(
                url: HelpUrls.appearanceAndThemes,
                tooltip: L10N.of(context).helpLinkLearnMore,
              ),
            ],
          ),
          const SizedBox(height: 8),
          PresetPicker(presets: builtinPresets().values.toList()),
          const SizedBox(height: 20),
          _SubsectionLabel(strings.tokenOverridesSectionHeading),
          const SizedBox(height: 8),
          for (final category in categories)
            TokenCategorySection(category: category),
          const SizedBox(height: 20),
          _SubsectionLabel(strings.themePackBrowserSectionHeading),
          const SizedBox(height: 8),
          ThemePackBrowser(
            store: store,
            pickPackDocument:
                widget.pickPackDocument ?? _defaultPickPackDocument,
            savePackDocument:
                widget.savePackDocument ?? _defaultSavePackDocument,
          ),
        ],
      ),
    );
  }

  /// Picks a `.crux-theme.json` file and returns its *contents* — the
  /// store abstraction exchanges documents, not file handles.
  static Future<String?> _defaultPickPackDocument() async {
    final result = await FilePicker.pickFiles(
      allowedExtensions: ['json'],
      type: FileType.custom,
    );
    final path = result?.files.single.path;
    if (path == null) return null;
    return File(path).readAsString();
  }

  /// Writes [document] to a user-chosen destination and returns the
  /// path for the confirmation snackbar.
  static Future<String?> _defaultSavePackDocument(String document) async {
    final path = await FilePicker.saveFile(
      // file_picker 12 requires bytes & writes the file; pass empty so it
      // only returns the chosen path and we write the document ourselves.
      bytes: Uint8List(0),
      fileName: 'simcrux-theme.crux-theme.json',
      allowedExtensions: ['json'],
      type: FileType.custom,
    );
    if (path == null) return null;
    await File(path).writeAsString(document);
    return path;
  }
}

/// Label for a subsection inside Settings → Appearance (Presets / Color
/// overrides / Theme packs). Lighter than the Settings category title so the
/// hierarchy reads category → subsection → data.
class _SubsectionLabel extends StatelessWidget {
  const _SubsectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      label,
      style: theme.textTheme.titleSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}
