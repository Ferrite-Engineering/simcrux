// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:crux_settings_ui/crux_settings_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';

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
/// removes the override, so the engine is found on `PATH` again.
class SettingsBinaryPathRow extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(width: 120, child: Text(engineId)),
          Expanded(
            child: _BinaryPathField(
              initial: settings.simulatorBinaryOverrides[engineId] ?? '',
              onSubmit: (value) {
                final next = Map<String, String>.from(
                  settings.simulatorBinaryOverrides,
                );
                if (value.isEmpty) {
                  next.remove(engineId);
                } else {
                  next[engineId] = value;
                }
                unawaited(
                  ref
                      .read(appSettingsProvider.notifier)
                      .updateSimulatorBinaryOverrides(next),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _BinaryPathField extends StatefulWidget {
  const _BinaryPathField({required this.initial, required this.onSubmit});

  final String initial;
  final ValueChanged<String> onSubmit;

  @override
  State<_BinaryPathField> createState() => _BinaryPathFieldState();
}

class _BinaryPathFieldState extends State<_BinaryPathField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      decoration: const InputDecoration(
        isDense: true,
        hintText: r'/usr/local/bin (leave empty to use $PATH)',
      ),
      onSubmitted: widget.onSubmit,
    );
  }
}
