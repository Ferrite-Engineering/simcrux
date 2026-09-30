// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:simcrux/domain/enums/golden_compare_profile.dart';
import 'package:simcrux/domain/models/pass_fail_config_codec.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// Recursive editor for a single [DetectorSpec] node. Children of a
/// [CompositeSpec] are rendered by the same editor recursively.
class DetectorSpecEditor extends StatelessWidget {
  /// Creates a [DetectorSpecEditor].
  const DetectorSpecEditor({
    required this.spec,
    required this.onChanged,
    required this.existingNames,
    super.key,
  });

  /// The current node value.
  final DetectorSpec spec;

  /// Called whenever the user mutates the node.
  final ValueChanged<DetectorSpec> onChanged;

  /// Other reusable detector names available for `use:` references.
  final Set<String> existingNames;

  static const List<_DetectorKind> _kinds = [
    _DetectorKind.exitCode,
    _DetectorKind.stringMatch,
    _DetectorKind.regex,
    _DetectorKind.uvmReport,
    _DetectorKind.cocotb,
    _DetectorKind.goldenCompare,
    _DetectorKind.composite,
    _DetectorKind.use,
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = L10N.of(context);
    final activeKind = _kindOf(spec);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.settingsDetectorKindLabel,
          style: Theme.of(context).textTheme.labelLarge,
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          children: [
            for (final kind in _kinds)
              ChoiceChip(
                label: Text(_labelFor(kind, l10n)),
                selected: kind == activeKind,
                onSelected: (_) => onChanged(_defaultSpecFor(kind)),
              ),
          ],
        ),
        const SizedBox(height: 12),
        _DetectorFieldsForKind(
          spec: spec,
          onChanged: onChanged,
          existingNames: existingNames,
        ),
      ],
    );
  }

  static _DetectorKind _kindOf(DetectorSpec spec) {
    return switch (spec) {
      ExitCodeSpec() => _DetectorKind.exitCode,
      StringMatchSpec() => _DetectorKind.stringMatch,
      RegexSpec() => _DetectorKind.regex,
      UvmReportSpec() => _DetectorKind.uvmReport,
      CocotbSpec() => _DetectorKind.cocotb,
      GoldenCompareSpec() => _DetectorKind.goldenCompare,
      CompositeSpec() => _DetectorKind.composite,
      UseSpec() => _DetectorKind.use,
    };
  }

  static DetectorSpec _defaultSpecFor(_DetectorKind kind) {
    return switch (kind) {
      _DetectorKind.exitCode => const ExitCodeSpec(),
      _DetectorKind.stringMatch => const StringMatchSpec(
        passString: 'ALL TESTS PASSED',
      ),
      _DetectorKind.regex => const RegexSpec(failPattern: 'FATAL|Error'),
      _DetectorKind.uvmReport => const UvmReportSpec(),
      _DetectorKind.cocotb => const CocotbSpec(),
      // Seeded with the RISC-V signature profile: it is the one profile
      // with conventional filenames, so the new node is immediately
      // valid instead of starting life as a validation error.
      _DetectorKind.goldenCompare => GoldenCompareSpec.forProfile(
        GoldenCompareProfile.riscvSignature,
      ),
      _DetectorKind.composite => CompositeSpec(
        allOf: const [ExitCodeSpec()],
      ),
      _DetectorKind.use => const UseSpec(''),
    };
  }

  static String _labelFor(_DetectorKind kind, L10N l10n) {
    return switch (kind) {
      _DetectorKind.exitCode => l10n.settingsDetectorKindExitCode,
      _DetectorKind.stringMatch => l10n.settingsDetectorKindStringMatch,
      _DetectorKind.regex => l10n.settingsDetectorKindRegex,
      _DetectorKind.uvmReport => l10n.settingsDetectorKindUvmReport,
      _DetectorKind.cocotb => l10n.settingsDetectorKindCocotb,
      _DetectorKind.goldenCompare => l10n.settingsDetectorKindGoldenCompare,
      _DetectorKind.composite => l10n.settingsDetectorKindComposite,
      _DetectorKind.use => l10n.settingsDetectorKindUse,
    };
  }
}

enum _DetectorKind {
  exitCode,
  stringMatch,
  regex,
  uvmReport,
  cocotb,
  goldenCompare,
  composite,
  use,
}

class _DetectorFieldsForKind extends StatelessWidget {
  const _DetectorFieldsForKind({
    required this.spec,
    required this.onChanged,
    required this.existingNames,
  });

  final DetectorSpec spec;
  final ValueChanged<DetectorSpec> onChanged;
  final Set<String> existingNames;

  @override
  Widget build(BuildContext context) {
    return switch (spec) {
      ExitCodeSpec() => const SizedBox.shrink(),
      StringMatchSpec() => _StringMatchFields(
        spec: spec as StringMatchSpec,
        onChanged: onChanged,
      ),
      RegexSpec() => _RegexFields(
        spec: spec as RegexSpec,
        onChanged: onChanged,
      ),
      CocotbSpec() => _CocotbFields(
        spec: spec as CocotbSpec,
        onChanged: onChanged,
      ),
      UvmReportSpec() => _UvmReportFields(
        spec: spec as UvmReportSpec,
        onChanged: onChanged,
      ),
      GoldenCompareSpec() => _GoldenCompareFields(
        spec: spec as GoldenCompareSpec,
        onChanged: onChanged,
      ),
      CompositeSpec() => _CompositeFields(
        spec: spec as CompositeSpec,
        onChanged: onChanged,
        existingNames: existingNames,
      ),
      UseSpec() => _UseFields(
        spec: spec as UseSpec,
        onChanged: onChanged,
        existingNames: existingNames,
      ),
    };
  }
}

class _StringMatchFields extends StatelessWidget {
  const _StringMatchFields({required this.spec, required this.onChanged});

  final StringMatchSpec spec;
  final ValueChanged<DetectorSpec> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = L10N.of(context);
    return Column(
      children: [
        TextFormField(
          initialValue: spec.passString,
          decoration: InputDecoration(
            labelText: l10n.settingsDetectorFieldPassString,
          ),
          onChanged: (value) => onChanged(
            StringMatchSpec(
              passString: value.isEmpty ? null : value,
              failString: spec.failString,
            ),
          ),
        ),
        TextFormField(
          initialValue: spec.failString,
          decoration: InputDecoration(
            labelText: l10n.settingsDetectorFieldFailString,
          ),
          onChanged: (value) => onChanged(
            StringMatchSpec(
              passString: spec.passString,
              failString: value.isEmpty ? null : value,
            ),
          ),
        ),
      ],
    );
  }
}

class _RegexFields extends StatelessWidget {
  const _RegexFields({required this.spec, required this.onChanged});

  final RegexSpec spec;
  final ValueChanged<DetectorSpec> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = L10N.of(context);
    return Column(
      children: [
        TextFormField(
          initialValue: spec.passPattern,
          decoration: InputDecoration(
            labelText: l10n.settingsDetectorFieldPassPattern,
          ),
          onChanged: (value) => onChanged(
            RegexSpec(
              passPattern: value.isEmpty ? null : value,
              failPattern: spec.failPattern,
            ),
          ),
        ),
        TextFormField(
          initialValue: spec.failPattern,
          decoration: InputDecoration(
            labelText: l10n.settingsDetectorFieldFailPattern,
          ),
          onChanged: (value) => onChanged(
            RegexSpec(
              passPattern: spec.passPattern,
              failPattern: value.isEmpty ? null : value,
            ),
          ),
        ),
      ],
    );
  }
}

/// The single option a Cocotb detector carries.
///
/// Everything else about the verdict is dictated by the summary line Cocotb
/// prints, so there is nothing else to offer: exposing thresholds it does not
/// report would be configuration that cannot be honoured.
class _CocotbFields extends StatelessWidget {
  const _CocotbFields({required this.spec, required this.onChanged});

  final CocotbSpec spec;
  final ValueChanged<DetectorSpec> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = L10N.of(context);
    return CheckboxListTile(
      value: spec.allowNoTests,
      onChanged: (v) => onChanged(CocotbSpec(allowNoTests: v ?? false)),
      title: Text(l10n.settingsDetectorFieldAllowNoTests),
      subtitle: Text(l10n.settingsDetectorFieldAllowNoTestsHint),
      controlAffinity: ListTileControlAffinity.leading,
      contentPadding: EdgeInsets.zero,
    );
  }
}

class _UvmReportFields extends StatelessWidget {
  const _UvmReportFields({required this.spec, required this.onChanged});

  final UvmReportSpec spec;
  final ValueChanged<DetectorSpec> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = L10N.of(context);
    return Column(
      children: [
        _IntField(
          label: l10n.settingsDetectorFieldFatalThreshold,
          value: spec.fatalThreshold,
          onChanged: (v) => onChanged(
            UvmReportSpec(
              fatalThreshold: v ?? 1,
              errorThreshold: spec.errorThreshold,
              warningThreshold: spec.warningThreshold,
            ),
          ),
        ),
        _IntField(
          label: l10n.settingsDetectorFieldErrorThreshold,
          value: spec.errorThreshold,
          onChanged: (v) => onChanged(
            UvmReportSpec(
              fatalThreshold: spec.fatalThreshold,
              errorThreshold: v ?? 1,
              warningThreshold: spec.warningThreshold,
            ),
          ),
        ),
        _IntField(
          label: l10n.settingsDetectorFieldWarningThreshold,
          value: spec.warningThreshold,
          allowNull: true,
          onChanged: (v) => onChanged(
            UvmReportSpec(
              fatalThreshold: spec.fatalThreshold,
              errorThreshold: spec.errorThreshold,
              warningThreshold: v,
            ),
          ),
        ),
      ],
    );
  }
}

class _GoldenCompareFields extends StatelessWidget {
  const _GoldenCompareFields({required this.spec, required this.onChanged});

  final GoldenCompareSpec spec;
  final ValueChanged<DetectorSpec> onChanged;

  String _profileLabel(GoldenCompareProfile profile, L10N l10n) {
    return switch (profile) {
      GoldenCompareProfile.generic => l10n.settingsDetectorProfileGeneric,
      GoldenCompareProfile.riscvSignature =>
        l10n.settingsDetectorProfileRiscvSignature,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10N.of(context);
    return Column(
      children: [
        DropdownButtonFormField<GoldenCompareProfile>(
          initialValue: spec.profile,
          decoration: InputDecoration(
            labelText: l10n.settingsDetectorFieldGoldenProfile,
          ),
          items: [
            for (final profile in GoldenCompareProfile.values)
              DropdownMenuItem<GoldenCompareProfile>(
                value: profile,
                child: Text(_profileLabel(profile, l10n)),
              ),
          ],
          onChanged: (value) {
            if (value == null) return;
            onChanged(spec.copyWith(profile: value));
          },
        ),
        TextFormField(
          initialValue: spec.dutPath,
          decoration: InputDecoration(
            labelText: l10n.settingsDetectorFieldGoldenDut,
          ),
          onChanged: (value) => onChanged(spec.copyWith(dutPath: value)),
        ),
        TextFormField(
          initialValue: spec.referencePath,
          decoration: InputDecoration(
            labelText: l10n.settingsDetectorFieldGoldenReference,
          ),
          onChanged: (value) => onChanged(spec.copyWith(referencePath: value)),
        ),
      ],
    );
  }
}

class _IntField extends StatelessWidget {
  const _IntField({
    required this.label,
    required this.value,
    required this.onChanged,
    this.allowNull = false,
  });

  final String label;
  final int? value;
  final ValueChanged<int?> onChanged;
  final bool allowNull;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      initialValue: value?.toString() ?? '',
      decoration: InputDecoration(labelText: label),
      keyboardType: TextInputType.number,
      onChanged: (text) {
        if (text.isEmpty) {
          if (allowNull) onChanged(null);
          return;
        }
        final parsed = int.tryParse(text);
        if (parsed != null && parsed >= 0) onChanged(parsed);
      },
    );
  }
}

class _CompositeFields extends StatelessWidget {
  const _CompositeFields({
    required this.spec,
    required this.onChanged,
    required this.existingNames,
  });

  final CompositeSpec spec;
  final ValueChanged<DetectorSpec> onChanged;
  final Set<String> existingNames;

  @override
  Widget build(BuildContext context) {
    final l10n = L10N.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _CompositeGroup(
          heading: l10n.settingsDetectorCompositeAllOfHeading,
          children: spec.allOf,
          existingNames: existingNames,
          onChanged: (next) => onChanged(spec.copyWith(allOf: next)),
        ),
        const SizedBox(height: 12),
        _CompositeGroup(
          heading: l10n.settingsDetectorCompositeAnyOfHeading,
          children: spec.anyOf,
          existingNames: existingNames,
          onChanged: (next) => onChanged(spec.copyWith(anyOf: next)),
        ),
      ],
    );
  }
}

class _CompositeGroup extends StatelessWidget {
  const _CompositeGroup({
    required this.heading,
    required this.children,
    required this.onChanged,
    required this.existingNames,
  });

  final String heading;
  final List<DetectorSpec> children;
  final ValueChanged<List<DetectorSpec>> onChanged;
  final Set<String> existingNames;

  @override
  Widget build(BuildContext context) {
    final l10n = L10N.of(context);
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(heading, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          for (var i = 0; i < children.length; i++) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: DetectorSpecEditor(
                    spec: children[i],
                    existingNames: existingNames,
                    onChanged: (next) {
                      final list = [...children]..[i] = next;
                      onChanged(list);
                    },
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.remove_circle_outline),
                  tooltip: l10n.settingsDetectorRemoveChild,
                  onPressed: () {
                    final list = [...children]..removeAt(i);
                    onChanged(list);
                  },
                ),
              ],
            ),
            const Divider(),
          ],
          TextButton.icon(
            icon: const Icon(Icons.add),
            label: Text(l10n.settingsDetectorAddChild),
            onPressed: () {
              onChanged([...children, const ExitCodeSpec()]);
            },
          ),
        ],
      ),
    );
  }
}

class _UseFields extends StatelessWidget {
  const _UseFields({
    required this.spec,
    required this.onChanged,
    required this.existingNames,
  });

  final UseSpec spec;
  final ValueChanged<DetectorSpec> onChanged;
  final Set<String> existingNames;

  @override
  Widget build(BuildContext context) {
    final l10n = L10N.of(context);
    final names = existingNames.toList()..sort();
    if (names.isEmpty) {
      return TextFormField(
        initialValue: spec.name,
        decoration: InputDecoration(
          labelText: l10n.settingsDetectorFieldUseName,
          hintText: l10n.settingsDetectorNameHint,
        ),
        onChanged: (v) => onChanged(UseSpec(v)),
      );
    }
    return DropdownButtonFormField<String>(
      initialValue: names.contains(spec.name) ? spec.name : null,
      decoration: InputDecoration(
        labelText: l10n.settingsDetectorFieldUseName,
      ),
      items: [
        for (final n in names)
          DropdownMenuItem<String>(value: n, child: Text(n)),
      ],
      onChanged: (v) {
        if (v != null) onChanged(UseSpec(v));
      },
    );
  }
}
