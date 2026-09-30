// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/golden_compare_profile.dart';
import 'package:simcrux/domain/models/pass_fail_config_codec.dart';
import 'package:simcrux/features/settings/widgets/detector_spec_editor.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// Drives [DetectorSpecEditor] from the outside: the widget itself is
/// stateless, so this harness owns the current [DetectorSpec] value,
/// rebuilds on every `onChanged`, and exposes the latest value back
/// to the test via [onSpec].
class _EditorHarness extends StatefulWidget {
  const _EditorHarness({
    required this.initial,
    required this.onSpec,
    this.existingNames = const <String>{},
  });

  final DetectorSpec initial;
  final ValueChanged<DetectorSpec> onSpec;
  final Set<String> existingNames;

  @override
  State<_EditorHarness> createState() => _EditorHarnessState();
}

class _EditorHarnessState extends State<_EditorHarness> {
  late DetectorSpec _spec = widget.initial;

  @override
  Widget build(BuildContext context) {
    return DetectorSpecEditor(
      spec: _spec,
      existingNames: widget.existingNames,
      onChanged: (next) {
        setState(() => _spec = next);
        widget.onSpec(next);
      },
    );
  }
}

Widget _wrap(Widget child, {Locale? locale}) {
  return MaterialApp(
    locale: locale,
    localizationsDelegates: const [
      L10N.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: L10N.supportedLocales,
    home: Scaffold(
      body: Material(
        child: SingleChildScrollView(child: child),
      ),
    ),
  );
}

void main() {
  group('DetectorSpecEditor — kind chips', () {
    testWidgets('renders one ChoiceChip per detector kind, selected marks '
        'the active one', (tester) async {
      await tester.pumpWidget(
        _wrap(
          _EditorHarness(initial: const ExitCodeSpec(), onSpec: (_) {}),
        ),
      );
      await tester.pumpAndSettle();

      // Eight kinds: exit_code, string_match, regex, uvm_report, cocotb,
      // golden_compare, composite, use.
      expect(find.byType(ChoiceChip), findsNWidgets(8));
      final exitChip = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, 'Exit code'),
      );
      expect(exitChip.selected, isTrue);
      final regexChip = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, 'Regex'),
      );
      expect(regexChip.selected, isFalse);
    });

    testWidgets("selecting a different kind swaps to that kind's default "
        'spec and fields', (tester) async {
      DetectorSpec? latest;
      await tester.pumpWidget(
        _wrap(
          _EditorHarness(
            initial: const ExitCodeSpec(),
            onSpec: (s) => latest = s,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(ChoiceChip, 'String match'));
      await tester.pumpAndSettle();

      expect(
        latest,
        const StringMatchSpec(passString: 'ALL TESTS PASSED'),
      );
      expect(find.text('Pass substring'), findsOneWidget);
      expect(find.text('Fail substring'), findsOneWidget);
    });
  });

  group('DetectorSpecEditor — golden compare', () {
    testWidgets('selecting the kind seeds the RISC-V signature profile', (
      tester,
    ) async {
      DetectorSpec? latest;
      await tester.pumpWidget(
        _wrap(
          _EditorHarness(
            initial: const ExitCodeSpec(),
            onSpec: (s) => latest = s,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(ChoiceChip, 'Golden compare'));
      await tester.pumpAndSettle();

      // Seeded with the one profile that has conventional filenames, so
      // the new node is immediately valid rather than starting life as a
      // validation error.
      expect(
        latest,
        GoldenCompareSpec.forProfile(GoldenCompareProfile.riscvSignature),
      );
      expect(find.text('Profile'), findsOneWidget);
      expect(find.text('DUT output file'), findsOneWidget);
      expect(find.text('Golden reference file'), findsOneWidget);
    });

    testWidgets('editing either path reports an updated spec', (tester) async {
      DetectorSpec? latest;
      await tester.pumpWidget(
        _wrap(
          _EditorHarness(
            initial: GoldenCompareSpec.forProfile(
              GoldenCompareProfile.riscvSignature,
            ),
            onSpec: (s) => latest = s,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'DUT output file'),
        'out/mine.sig',
      );
      expect((latest! as GoldenCompareSpec).dutPath, 'out/mine.sig');

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Golden reference file'),
        '/goldens/rv32i.sig',
      );
      final spec = latest! as GoldenCompareSpec;
      expect(spec.referencePath, '/goldens/rv32i.sig');
      expect(spec.dutPath, 'out/mine.sig', reason: 'the other field held');
      expect(spec.profile, GoldenCompareProfile.riscvSignature);
    });

    testWidgets('switching the profile keeps the paths', (tester) async {
      DetectorSpec? latest;
      await tester.pumpWidget(
        _wrap(
          _EditorHarness(
            initial: GoldenCompareSpec.forProfile(
              GoldenCompareProfile.riscvSignature,
            ),
            onSpec: (s) => latest = s,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('RISC-V signature').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Generic').last);
      await tester.pumpAndSettle();

      final spec = latest! as GoldenCompareSpec;
      expect(spec.profile, GoldenCompareProfile.generic);
      expect(spec.dutPath, 'signature.dut.sig');
      expect(spec.referencePath, 'signature.ref.sig');
    });
  });

  group('DetectorSpecEditor — exit code', () {
    testWidgets('has no extra fields beyond the kind chips', (tester) async {
      await tester.pumpWidget(
        _wrap(_EditorHarness(initial: const ExitCodeSpec(), onSpec: (_) {})),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TextFormField), findsNothing);
    });
  });

  group('DetectorSpecEditor — string match', () {
    testWidgets('editing pass/fail substrings reports updated specs', (
      tester,
    ) async {
      DetectorSpec? latest;
      await tester.pumpWidget(
        _wrap(
          _EditorHarness(
            initial: const StringMatchSpec(),
            onSpec: (s) => latest = s,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Pass substring'),
        'ALL PASS',
      );
      expect(latest, const StringMatchSpec(passString: 'ALL PASS'));

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Fail substring'),
        'FAILED',
      );
      expect(
        latest,
        const StringMatchSpec(passString: 'ALL PASS', failString: 'FAILED'),
      );
    });

    testWidgets('clearing a field back to empty nulls that field out', (
      tester,
    ) async {
      DetectorSpec? latest;
      await tester.pumpWidget(
        _wrap(
          _EditorHarness(
            initial: const StringMatchSpec(passString: 'X'),
            onSpec: (s) => latest = s,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Pass substring'),
        '',
      );
      expect(latest, const StringMatchSpec());
    });
  });

  group('DetectorSpecEditor — regex', () {
    testWidgets('editing pass/fail patterns reports updated specs', (
      tester,
    ) async {
      DetectorSpec? latest;
      await tester.pumpWidget(
        _wrap(
          _EditorHarness(
            initial: const RegexSpec(),
            onSpec: (s) => latest = s,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Pass regex'),
        r'^OK$',
      );
      expect(latest, const RegexSpec(passPattern: r'^OK$'));

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Fail regex'),
        'FATAL',
      );
      expect(
        latest,
        const RegexSpec(passPattern: r'^OK$', failPattern: 'FATAL'),
      );
    });
  });

  group('DetectorSpecEditor — UVM report', () {
    testWidgets('renders the three threshold fields with initial values', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          _EditorHarness(
            initial: const UvmReportSpec(
              fatalThreshold: 2,
              errorThreshold: 3,
              warningThreshold: 4,
            ),
            onSpec: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextFormField, '2'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '3'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '4'), findsOneWidget);
    });

    testWidgets('entering a valid integer updates the threshold', (
      tester,
    ) async {
      DetectorSpec? latest;
      await tester.pumpWidget(
        _wrap(
          _EditorHarness(
            initial: const UvmReportSpec(),
            onSpec: (s) => latest = s,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Fatal threshold'),
        '5',
      );
      expect(latest, const UvmReportSpec(fatalThreshold: 5));
    });

    testWidgets('non-numeric text is ignored (onChanged not called)', (
      tester,
    ) async {
      var called = false;
      await tester.pumpWidget(
        _wrap(
          _EditorHarness(
            initial: const UvmReportSpec(),
            onSpec: (_) => called = true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Fatal threshold'),
        'abc',
      );
      expect(called, isFalse);
    });

    testWidgets('a negative value is ignored (onChanged not called)', (
      tester,
    ) async {
      var called = false;
      await tester.pumpWidget(
        _wrap(
          _EditorHarness(
            initial: const UvmReportSpec(),
            onSpec: (_) => called = true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Fatal threshold'),
        '-1',
      );
      expect(called, isFalse);
    });

    testWidgets('clearing the (nullable) warning threshold nulls it out', (
      tester,
    ) async {
      DetectorSpec? latest;
      await tester.pumpWidget(
        _wrap(
          _EditorHarness(
            initial: const UvmReportSpec(warningThreshold: 3),
            onSpec: (s) => latest = s,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Warning threshold'),
        '',
      );
      expect(latest, const UvmReportSpec());
    });

    testWidgets(
      'clearing the (non-nullable) fatal threshold does NOT call onChanged',
      (tester) async {
        var called = false;
        await tester.pumpWidget(
          _wrap(
            _EditorHarness(
              initial: const UvmReportSpec(fatalThreshold: 2),
              onSpec: (_) => called = true,
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.enterText(
          find.widgetWithText(TextFormField, 'Fatal threshold'),
          '',
        );
        expect(called, isFalse);
      },
    );
  });

  group('DetectorSpecEditor — composite (recursive)', () {
    testWidgets('renders both AllOf and AnyOf group headings', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          _EditorHarness(initial: CompositeSpec(), onSpec: (_) {}),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('All of (AND)'), findsOneWidget);
      expect(find.text('Any of (OR)'), findsOneWidget);
    });

    testWidgets('Add child appends an ExitCodeSpec to allOf', (
      tester,
    ) async {
      DetectorSpec? latest;
      await tester.pumpWidget(
        _wrap(
          _EditorHarness(initial: CompositeSpec(), onSpec: (s) => latest = s),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Add child').first);
      await tester.pumpAndSettle();

      final composite = latest! as CompositeSpec;
      expect(composite.allOf, [const ExitCodeSpec()]);
      expect(composite.anyOf, isEmpty);
    });

    testWidgets('nested child editors render recursively and route their '
        'own onChanged back through the parent list', (tester) async {
      DetectorSpec? latest;
      await tester.pumpWidget(
        _wrap(
          _EditorHarness(
            initial: CompositeSpec(allOf: const [StringMatchSpec()]),
            onSpec: (s) => latest = s,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The nested StringMatchSpec's own "Pass substring" field is
      // reachable and reports through the parent CompositeSpec.
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Pass substring'),
        'NESTED PASS',
      );
      final composite = latest! as CompositeSpec;
      expect(
        composite.allOf,
        [const StringMatchSpec(passString: 'NESTED PASS')],
      );
    });

    testWidgets('Remove (the trash icon) deletes that child', (tester) async {
      DetectorSpec? latest;
      await tester.pumpWidget(
        _wrap(
          _EditorHarness(
            initial: CompositeSpec(
              allOf: const [ExitCodeSpec(), StringMatchSpec()],
            ),
            onSpec: (s) => latest = s,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.remove_circle_outline).first);
      await tester.pumpAndSettle();

      final composite = latest! as CompositeSpec;
      expect(composite.allOf, [const StringMatchSpec()]);
    });
  });

  group('DetectorSpecEditor — use (reusable detector reference)', () {
    testWidgets('with no existing names, shows a free-text field', (
      tester,
    ) async {
      DetectorSpec? latest;
      await tester.pumpWidget(
        _wrap(
          _EditorHarness(initial: const UseSpec(''), onSpec: (s) => latest = s),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Referenced detector'),
        'strict-uvm',
      );
      expect(latest, const UseSpec('strict-uvm'));
    });

    testWidgets('with existing names, shows a dropdown and selecting an '
        'entry reports UseSpec(name)', (tester) async {
      DetectorSpec? latest;
      await tester.pumpWidget(
        _wrap(
          _EditorHarness(
            initial: const UseSpec(''),
            existingNames: const {'alpha', 'beta'},
            onSpec: (s) => latest = s,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('beta').last);
      await tester.pumpAndSettle();

      expect(latest, const UseSpec('beta'));
    });
  });

  group('DetectorSpecEditor — locale sweep', () {
    for (final locale in const [
      Locale('en'),
      Locale('zh', 'CN'),
      Locale('ja'),
      Locale('ko'),
    ]) {
      testWidgets('renders every kind without exceptions — '
          '${locale.toLanguageTag()}', (tester) async {
        for (final spec in <DetectorSpec>[
          const ExitCodeSpec(),
          const StringMatchSpec(passString: 'x'),
          const RegexSpec(failPattern: 'y'),
          const UvmReportSpec(warningThreshold: 1),
          GoldenCompareSpec.forProfile(GoldenCompareProfile.riscvSignature),
          const GoldenCompareSpec(dutPath: 'a.bin', referencePath: 'b.bin'),
          CompositeSpec(allOf: const [ExitCodeSpec()]),
          const UseSpec('a'),
        ]) {
          await tester.pumpWidget(
            _wrap(
              _EditorHarness(
                initial: spec,
                existingNames: const {'a', 'b'},
                onSpec: (_) {},
              ),
              locale: locale,
            ),
          );
          await tester.pump();
          expect(
            tester.takeException(),
            isNull,
            reason: 'locale ${locale.toLanguageTag()} / spec $spec threw',
          );
        }
      });
    }
  });
}
