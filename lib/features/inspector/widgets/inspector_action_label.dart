// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';

/// The label of an inspector action button: one line, ellipsized when the
/// inspector is too narrow for it, with the whole label as a tooltip then.
///
/// A button label that wraps onto a second line makes the button taller than
/// its neighbours and reads as broken; a tooltip only appears when the text
/// is cut, so a roomy panel shows no hover noise.
class InspectorActionLabel extends StatelessWidget {
  /// Creates a label showing [text].
  const InspectorActionLabel(this.text, {super.key});

  /// The label.
  final String text;

  @override
  Widget build(BuildContext context) {
    final label = Text(
      text,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: text, style: DefaultTextStyle.of(context).style),
          maxLines: 1,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        final cut = painter.width > constraints.maxWidth;
        painter.dispose();
        return cut ? Tooltip(message: text, child: label) : label;
      },
    );
  }
}
