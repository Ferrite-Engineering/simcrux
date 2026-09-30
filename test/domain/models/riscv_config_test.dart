// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/riscv_reference_model.dart';
import 'package:simcrux/domain/enums/riscv_run_mode.dart';
import 'package:simcrux/domain/models/riscv_config.dart';

// Unit coverage for the `riscv:` value object: the merge step that the
// loader applies FOUR times (include → project defaults → suite → test),
// the completeness rules that run on the flattened result, and the argv
// placeholder expansion.
//
// MUTATION: make `mergeOnto` return `this` for a nested block instead of
// recursing and "a lower level that sets only word_size keeps the parent's
// dut path" fails — which is the exact silent-drop bug four-level
// inheritance invites.

void main() {
  group('mergeOnto', () {
    test('an unset field falls through to the parent', () {
      const parent = RiscvConfig(isa: 'rv32imc', demoSignatures: 'corpus');
      const child = RiscvConfig(extension: 'M');
      final merged = child.mergeOnto(parent);
      expect(merged.isa, 'rv32imc');
      expect(merged.demoSignatures, 'corpus');
      expect(merged.extension, 'M');
    });

    test('a set field wins over the parent', () {
      const parent = RiscvConfig(isa: 'rv32i');
      const child = RiscvConfig(isa: 'rv64imafdc');
      expect(child.mergeOnto(parent).isa, 'rv64imafdc');
    });

    test('a null parent is the identity', () {
      const child = RiscvConfig(isa: 'rv32i');
      expect(child.mergeOnto(null), child);
    });

    test('nested blocks merge field-by-field, not wholesale', () {
      const parent = RiscvConfig(
        signature: RiscvSignatureConfig(dut: 'dut.bin', wordSize: 8),
        reference: RiscvReferenceConfig(
          model: RiscvReferenceModel.sail,
          path: '/opt/sail',
        ),
      );
      const child = RiscvConfig(
        signature: RiscvSignatureConfig(wordSize: 4),
        reference: RiscvReferenceConfig(model: RiscvReferenceModel.spike),
      );
      final merged = child.mergeOnto(parent);
      // The child set only word_size; the parent's dut path survives.
      expect(merged.signature!.dut, 'dut.bin');
      expect(merged.signature!.wordSize, 4);
      // The child switched models; the parent's path survives, which is
      // what makes "switch model at the suite level" usable.
      expect(merged.reference!.model, RiscvReferenceModel.spike);
      expect(merged.reference!.path, '/opt/sail');
    });

    test('four chained merges behave as four inheritance levels', () {
      // include file → project defaults → suite → test
      const include = RiscvConfig(isa: 'rv32imc', demoSignatures: 'corpus');
      const projectDefaults = RiscvConfig(
        signature: RiscvSignatureConfig(wordSize: 4),
      );
      const suite = RiscvConfig(extension: 'I');
      const test = RiscvConfig(testPath: 'I/src/add-01.S');

      final flattened = test.mergeOnto(
        suite.mergeOnto(projectDefaults.mergeOnto(include)),
      );

      expect(flattened.isa, 'rv32imc', reason: 'level 1 survived');
      expect(flattened.signature!.wordSize, 4, reason: 'level 2 survived');
      expect(flattened.extension, 'I', reason: 'level 3 survived');
      expect(flattened.testPath, 'I/src/add-01.S', reason: 'level 4 survived');
      expect(flattened.demoSignatures, 'corpus');
    });
  });

  group('defaults', () {
    test('signature paths default to the riscv_signature convention', () {
      const cfg = RiscvConfig();
      // These are exactly what `pass_fail: {type: golden_compare,
      // profile: riscv_signature}` with no explicit paths resolves to, so
      // the driver writes what the detector reads.
      expect(cfg.effectiveSignature.effectiveDut, 'signature.dut.sig');
      expect(cfg.effectiveSignature.effectiveReference, 'signature.ref.sig');
      expect(cfg.effectiveSignature.effectiveWordSize, 4);
    });

    test('declared paths stay null so merge can tell them apart', () {
      const cfg = RiscvSignatureConfig();
      expect(cfg.dut, isNull);
      expect(cfg.reference, isNull);
      expect(cfg.effectiveDut, 'signature.dut.sig');
    });

    test('mode defaults to normal', () {
      expect(const RiscvConfig().effectiveMode, RiscvRunMode.normal);
    });

    test('xlen and abi derive from the ISA string', () {
      expect(const RiscvConfig(isa: 'rv32imc').xlen, 32);
      expect(const RiscvConfig(isa: 'rv32imc').abi, 'ilp32');
      expect(const RiscvConfig(isa: 'rv64imafdc').xlen, 64);
      expect(const RiscvConfig(isa: 'rv64imafdc').abi, 'lp64');
      expect(const RiscvConfig(isa: 'RV64I').xlen, 64, reason: 'case-folded');
      expect(const RiscvConfig().xlen, 32, reason: 'no ISA ⇒ RV32');
    });
  });

  group('validateForRun', () {
    test('normal mode needs a target command and a test', () {
      final problems = const RiscvConfig().validateForRun();
      expect(problems, hasLength(2));
      expect(problems.first, contains('riscv.target.command'));
      expect(problems.last, contains('riscv.test'));
    });

    test('normal mode is satisfied by a target command and a test', () {
      const cfg = RiscvConfig(
        target: RiscvTargetConfig(command: ['./core', '{elf}']),
        testPath: 'I/src/add-01.S',
      );
      expect(cfg.validateForRun(), isEmpty);
    });

    test('demo mode needs only the corpus path', () {
      expect(
        const RiscvConfig(mode: RiscvRunMode.demo).validateForRun(),
        hasLength(1),
      );
      expect(
        const RiscvConfig(
          mode: RiscvRunMode.demo,
          demoSignatures: 'verification/fixtures/golden_compare',
        ).validateForRun(),
        isEmpty,
        reason:
            'demo mode spawns nothing, so it must not require any toolchain '
            'plumbing at all',
      );
    });

    test('riscof passthrough needs its command', () {
      expect(
        const RiscvConfig(
          mode: RiscvRunMode.riscofPassthrough,
        ).validateForRun().single,
        contains('riscv.riscof.command'),
      );
      expect(
        const RiscvConfig(
          mode: RiscvRunMode.riscofPassthrough,
          riscof: RiscvRiscofConfig(command: ['riscof', 'run']),
        ).validateForRun(),
        isEmpty,
      );
    });

    test('the passthrough message warns about the once-per-test spawn', () {
      expect(
        const RiscvConfig(
          mode: RiscvRunMode.riscofPassthrough,
        ).validateForRun().single,
        contains('once per test'),
      );
    });
  });

  group('value semantics', () {
    test('== and hashCode cover every field', () {
      const a = RiscvConfig(
        isa: 'rv32imc',
        extensions: ['I', 'M'],
        mode: RiscvRunMode.demo,
        signature: RiscvSignatureConfig(wordSize: 8),
      );
      const b = RiscvConfig(
        isa: 'rv32imc',
        extensions: ['I', 'M'],
        mode: RiscvRunMode.demo,
        signature: RiscvSignatureConfig(wordSize: 8),
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(b.copyWith(extension: 'C')));
      expect(a, isNot(b.copyWith(isa: 'rv64i')));
      expect(
        a,
        isNot(b.copyWith(signature: const RiscvSignatureConfig(wordSize: 4))),
      );
    });

    test('list fields compare by value, not identity', () {
      expect(
        const RiscvConfig(extensions: ['I']),
        const RiscvConfig(extensions: ['I']),
      );
      expect(
        const RiscvConfig(extensions: ['I']),
        isNot(const RiscvConfig(extensions: ['M'])),
      );
    });

    test('copyWith leaves unnamed fields alone', () {
      const cfg = RiscvConfig(isa: 'rv32i', extension: 'I');
      expect(cfg.copyWith(extension: 'M').isa, 'rv32i');
    });
  });

  group('expandRiscvPlaceholders', () {
    const values = {'elf': '/wd/test.elf', 'signature': '/wd/dut.sig'};

    test('substitutes known placeholders', () {
      expect(expandRiscvPlaceholders('{elf}', values), '/wd/test.elf');
      expect(
        expandRiscvPlaceholders('--sig={signature}', values),
        '--sig=/wd/dut.sig',
      );
    });

    test('leaves an unknown placeholder verbatim rather than blanking it', () {
      // A typo has to be visible in the spawned command line and the log,
      // not silently become an empty argument.
      expect(expandRiscvPlaceholders('{elff}', values), '{elff}');
    });

    test('passes plain text through', () {
      expect(expandRiscvPlaceholders('--verbose', values), '--verbose');
    });
  });

  group('reference-model invocations', () {
    test('spike takes the ISA, the signature and its granularity', () {
      final args = RiscvReferenceModel.spike.signatureArgs(
        isa: 'rv32imc',
        elf: '/wd/test.elf',
        signaturePath: '/wd/ref.sig',
        wordSize: 4,
      );
      expect(args, [
        '--isa=rv32imc',
        '+signature=/wd/ref.sig',
        '+signature-granularity=4',
        '/wd/test.elf',
      ]);
    });

    test('sail takes --test-signature and the ELF last', () {
      final args = RiscvReferenceModel.sail.signatureArgs(
        isa: 'rv32imc',
        elf: '/wd/test.elf',
        signaturePath: '/wd/ref.sig',
        wordSize: 4,
      );
      expect(args, ['--test-signature', '/wd/ref.sig', '/wd/test.elf']);
      expect(args.last, '/wd/test.elf');
    });

    test('sail picks its per-width emulator; spike is one binary', () {
      expect(
        RiscvReferenceModel.sail.defaultBinary(xlen: 32),
        'riscv_sim_RV32',
      );
      expect(
        RiscvReferenceModel.sail.defaultBinary(xlen: 64),
        'riscv_sim_RV64',
      );
      expect(RiscvReferenceModel.spike.defaultBinary(xlen: 32), 'spike');
      expect(RiscvReferenceModel.spike.defaultBinary(xlen: 64), 'spike');
    });
  });

  group('wire names', () {
    test('mode tokens round-trip and reject junk', () {
      for (final mode in RiscvRunMode.values) {
        expect(RiscvRunMode.fromWireName(mode.wireName), mode);
      }
      expect(RiscvRunMode.fromWireName('demo_mode'), isNull);
      expect(RiscvRunMode.fromWireName(7), isNull);
    });

    test('reference-model tokens round-trip and reject junk', () {
      for (final model in RiscvReferenceModel.values) {
        expect(RiscvReferenceModel.fromWireName(model.wireName), model);
      }
      expect(RiscvReferenceModel.fromWireName('qemu'), isNull);
    });

    test('the simulator id is the bare open-core convention', () {
      expect(RiscvConfig.kSimulatorId, 'riscv_arch');
    });
  });
}
