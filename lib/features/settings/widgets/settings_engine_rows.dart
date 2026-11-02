// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:crux_settings_ui/crux_settings_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/settings/providers/binary_path_drafts_provider.dart';

/// One titled group in Settings > Engines: Simulators, Formal tools or
/// Implementation flow.
///
/// Renders nothing when [rows] is empty, so a group whose engines are not
/// registered in this build never shows an empty card.
class SettingsEngineGroup extends StatelessWidget {
  /// Creates a [SettingsEngineGroup].
  const SettingsEngineGroup({
    required this.title,
    required this.rows,
    this.leadingGap = true,
    super.key,
  });

  /// The group's localized heading.
  final String title;

  /// The group's rows, top to bottom.
  final List<Widget> rows;

  /// Whether a gap separates this group's card from the one above it.
  final bool leadingGap;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(top: leadingGap ? 16 : 0),
      child: CruxSettingsSectionCard(
        children: [
          // Spread rows (no label column), as the rest of Settings lays out.
          CruxFormSection(title: title, labelWidth: null, children: rows),
        ],
      ),
    );
  }
}

/// The binary-path override row for one registered engine id.
///
/// Writes `AppSettings.simulatorBinaryOverrides[engineId]`; an empty value
/// removes the override, so the engine is found on `PATH` again. The value is
/// saved on Enter, when the field loses focus and when Settings closes.
class SettingsBinaryPathRow extends StatelessWidget {
  /// Creates a [SettingsBinaryPathRow].
  const SettingsBinaryPathRow({
    required this.engineId,
    required this.settings,
    super.key,
  });

  /// The driver id the row configures, shown as its label.
  final String engineId;

  /// Currently-loaded [AppSettings].
  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(width: 120, child: Text(engineId)),
          Expanded(
            child: _BinaryPathField(
              engineId: engineId,
              initial: settings.simulatorBinaryOverrides[engineId] ?? '',
            ),
          ),
        ],
      ),
    );
  }
}

/// The text field of a [SettingsBinaryPathRow].
///
/// The path is saved when the user presses Enter, when the field loses focus
/// (tabbing away, clicking another control) and when the field goes away with
/// text not yet saved (closing Settings). Until then the text is kept in
/// [binaryPathDraftsProvider], so Check Formal Tools can use it.
class _BinaryPathField extends ConsumerStatefulWidget {
  const _BinaryPathField({required this.engineId, required this.initial});

  final String engineId;
  final String initial;

  @override
  ConsumerState<_BinaryPathField> createState() => _BinaryPathFieldState();
}

class _BinaryPathFieldState extends ConsumerState<_BinaryPathField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );
  final FocusNode _focus = FocusNode();

  // Held so the last save can run while the widget is being removed, when
  // `ref` can no longer be read.
  late ProviderContainer _container;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChange);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _container = ProviderScope.containerOf(context, listen: false);
  }

  void _onFocusChange() {
    if (!_focus.hasFocus) _save(_container, widget.engineId, _controller.text);
  }

  static void _save(ProviderContainer container, String engineId, String text) {
    unawaited(
      _saveAsync(container, engineId, text).catchError((Object _) {
        // The scope was torn down first (app exit); nothing is left to save to.
      }),
    );
  }

  static Future<void> _saveAsync(
    ProviderContainer container,
    String engineId,
    String text,
  ) async {
    await container
        .read(appSettingsProvider.notifier)
        .setSimulatorBinaryOverride(engineId, text);
    container
        .read(binaryPathDraftsProvider.notifier)
        .clear(engineId, ifValue: text);
  }

  @override
  void dispose() {
    _focus
      ..removeListener(_onFocusChange)
      ..dispose();
    final engineId = widget.engineId;
    final text = _controller.text;
    final container = _container;
    var unsaved = false;
    try {
      unsaved = container.read(binaryPathDraftsProvider)[engineId] != null;
    } on Object {
      // The scope is already gone (app exit); there is nowhere to save to.
    }
    _controller.dispose();
    if (unsaved) {
      // Not while the tree is being torn down: providers may not change then.
      scheduleMicrotask(() => _save(container, engineId, text));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      focusNode: _focus,
      decoration: const InputDecoration(
        isDense: true,
        hintText: r'/usr/local/bin (leave empty to use $PATH)',
      ),
      onChanged: (value) => ref
          .read(binaryPathDraftsProvider.notifier)
          .set(widget.engineId, value),
      onSubmitted: (value) => _save(_container, widget.engineId, value),
    );
  }
}
