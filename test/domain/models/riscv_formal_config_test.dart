// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/riscv_run_mode.dart';
import 'package:simcrux/domain/models/riscv_config.dart';

// The `riscv.formal:` value object (VERIFICATION_GUIDE.md §18.3).
//
// Two drivers share one `riscv:` block, so the interesting properties are
// (a) the sub-blocks merge independently, and (b) each driver's
// completeness rules only apply to its own id — `riscv_arch` must never
// demand `formal.sby_file`, and `riscv_formal` must never demand
// `target.command`.

void main() {
  group('group derivation', () {
    test('an instruction check reduces to its family', () {
      expect(RiscvFormalConfig.groupForCheck('insn_add_ch0'), 'insn');
      expect(RiscvFormalConfig.groupForCheck('insn_c_addi4spn_ch1'), 'insn');
    });

    test('a CSR check reduces to its family', () {
      expect(RiscvFormalConfig.groupForCheck('csrw_mcycle_ch0'), 'csrw');
      expect(RiscvFormalConfig.groupForCheck('csrc_misa_ch0'), 'csrc');
    });

    test('a structural check is already its own group', () {
      expect(RiscvFormalConfig.groupForCheck('reg_ch0'), 'reg');
      expect(RiscvFormalConfig.groupForCheck('pc_fwd_ch0'), 'pc_fwd');
      expect(RiscvFormalConfig.groupForCheck('pc_bwd_ch0'), 'pc_bwd');
      expect(RiscvFormalConfig.groupForCheck('liveness_ch0'), 'liveness');
      expect(RiscvFormalConfig.groupForCheck('causal_ch0'), 'causal');
      expect(RiscvFormalConfig.groupForCheck('unique_ch0'), 'unique');
    });

    test('a name with no channel suffix still groups', () {
      expect(RiscvFormalConfig.groupForCheck('cover'), 'cover');
    });

    test('null and empty are null, never an empty-string group', () {
      expect(RiscvFormalConfig.groupForCheck(null), isNull);
      expect(RiscvFormalConfig.groupForCheck(''), isNull);
    });

    test('an explicit group: wins over the derived one', () {
      // The user owns the emitted YAML, so a re-tag has to stick.
      const cfg = RiscvFormalConfig(check: 'insn_add_ch0', group: 'arithmetic');
      expect(cfg.effectiveGroup, 'arithmetic');
    });

    test('the derived group is used when none was declared', () {
      const cfg = RiscvFormalConfig(check: 'insn_add_ch0');
      expect(cfg.effectiveGroup, 'insn');
    });
  });

  group('channel', () {
    test('is read off the check name', () {
      expect(const RiscvFormalConfig(check: 'insn_add_ch2').channel, '2');
    });

    test('is null when the name carries none', () {
      expect(const RiscvFormalConfig(check: 'cover').channel, isNull);
      expect(const RiscvFormalConfig().channel, isNull);
    });
  });

  group('merging', () {
    test('an unset field falls through to the parent', () {
      const parent = RiscvFormalConfig(
        checksDir: '/core/checks',
        sbyBinary: '/opt/oss-cad-suite/bin/sby',
      );
      const child = RiscvFormalConfig(check: 'reg_ch0');
      final merged = child.mergeOnto(parent);
      expect(merged.checksDir, '/core/checks');
      expect(merged.sbyBinary, '/opt/oss-cad-suite/bin/sby');
      expect(merged.check, 'reg_ch0');
    });

    test('a set field wins over the parent', () {
      const parent = RiscvFormalConfig(checksDir: '/a');
      const child = RiscvFormalConfig(checksDir: '/b');
      expect(child.mergeOnto(parent).checksDir, '/b');
    });

    test('the formal sub-block merges independently of the others', () {
      // A suite that switches only `formal.checks_dir` must keep the
      // project's `signature.word_size` and its `target.command`.
      const project = RiscvConfig(
        isa: 'rv32i',
        formal: RiscvFormalConfig(
          checksDir: '/a',
          sbyBinary: '/opt/sby',
        ),
        signature: RiscvSignatureConfig(wordSize: 8),
        target: RiscvTargetConfig(command: ['./core']),
      );
      const suite = RiscvConfig(formal: RiscvFormalConfig(checksDir: '/b'));
      final merged = suite.mergeOnto(project);
      expect(merged.formal!.checksDir, '/b');
      expect(merged.formal!.sbyBinary, '/opt/sby');
      expect(merged.signature!.wordSize, 8);
      expect(merged.target!.command, ['./core']);
      expect(merged.isa, 'rv32i');
    });

    test('copyWith carries the formal block', () {
      const cfg = RiscvConfig(formal: RiscvFormalConfig(check: 'reg_ch0'));
      expect(cfg.copyWith(isa: 'rv64i').formal!.check, 'reg_ch0');
    });

    test('equality and hashCode account for the formal block', () {
      const a = RiscvConfig(formal: RiscvFormalConfig(check: 'a'));
      const b = RiscvConfig(formal: RiscvFormalConfig(check: 'b'));
      expect(a, isNot(b));
      expect(a, const RiscvConfig(formal: RiscvFormalConfig(check: 'a')));
      expect(
        a.hashCode,
        const RiscvConfig(formal: RiscvFormalConfig(check: 'a')).hashCode,
      );
    });
  });

  group('completeness is scoped by driver id', () {
    const formalNormal = RiscvConfig(
      formal: RiscvFormalConfig(
        checksDir: '/core/checks',
        sbyFile: 'insn_add_ch0.sby',
        check: 'insn_add_ch0',
      ),
    );

    test('a complete formal config validates under riscv_formal', () {
      expect(
        formalNormal.validateForRun(
          simulatorId: RiscvConfig.kFormalSimulatorId,
        ),
        isEmpty,
      );
    });

    test('riscv_formal never demands target.command', () {
      final problems = formalNormal.validateForRun(
        simulatorId: RiscvConfig.kFormalSimulatorId,
      );
      expect(problems.join(' '), isNot(contains('target.command')));
    });

    test('riscv_arch never demands formal.sby_file', () {
      const archConfig = RiscvConfig(
        testPath: 'rv32i_m/I/src/add-01.S',
        target: RiscvTargetConfig(command: ['./core', '{elf}']),
      );
      expect(archConfig.validateForRun(), isEmpty);
    });

    test('a missing sby_file is named, with what to do about it', () {
      final problems = const RiscvConfig(
        formal: RiscvFormalConfig(checksDir: '/core/checks'),
      ).validateForRun(simulatorId: RiscvConfig.kFormalSimulatorId);
      expect(problems, hasLength(1));
      expect(problems.single, contains('riscv.formal.sby_file'));
      expect(problems.single, contains('RiscvFormalCheckImporter'));
    });

    test('a relative sby_file with no checks_dir is refused', () {
      // `sby` runs in the checks directory because the generated jobs
      // reference their sources relative to it; without one, a relative
      // job file has no anchor.
      final problems = const RiscvConfig(
        formal: RiscvFormalConfig(sbyFile: 'insn_add_ch0.sby'),
      ).validateForRun(simulatorId: RiscvConfig.kFormalSimulatorId);
      expect(problems.join(' '), contains('riscv.formal.checks_dir'));
    });

    test('an absolute sby_file needs no checks_dir', () {
      expect(
        const RiscvConfig(
          formal: RiscvFormalConfig(sbyFile: '/core/checks/reg_ch0.sby'),
        ).validateForRun(simulatorId: RiscvConfig.kFormalSimulatorId),
        isEmpty,
      );
    });

    test('a command override satisfies both requirements', () {
      expect(
        const RiscvConfig(
          formal: RiscvFormalConfig(command: ['./run-proof.sh', '{check}']),
        ).validateForRun(simulatorId: RiscvConfig.kFormalSimulatorId),
        isEmpty,
      );
    });

    test('demo mode needs a corpus and nothing else', () {
      expect(
        const RiscvConfig(
          mode: RiscvRunMode.demo,
          formal: RiscvFormalConfig(demoOutputs: 'verification/fixtures'),
        ).validateForRun(simulatorId: RiscvConfig.kFormalSimulatorId),
        isEmpty,
      );
      expect(
        const RiscvConfig(
          mode: RiscvRunMode.demo,
        ).validateForRun(simulatorId: RiscvConfig.kFormalSimulatorId).single,
        contains('riscv.formal.demo_outputs'),
      );
    });

    test('riscof_passthrough is refused outright for a bounded proof', () {
      // RISCOF drives architectural compatibility tests. Accepting the
      // mode here would spawn a command that cannot produce a formal
      // verdict, and the run would then have to be classified from
      // whatever it happened to print.
      final problems = const RiscvConfig(
        mode: RiscvRunMode.riscofPassthrough,
        formal: RiscvFormalConfig(sbyFile: '/a/b.sby'),
      ).validateForRun(simulatorId: RiscvConfig.kFormalSimulatorId);
      expect(problems, hasLength(1));
      expect(problems.single, contains('does not apply'));
    });
  });

  group('ids', () {
    test('the two drivers have distinct, bare, lowercase ids', () {
      expect(RiscvConfig.kSimulatorId, 'riscv_arch');
      expect(RiscvConfig.kFormalSimulatorId, 'riscv_formal');
      expect(RiscvConfig.kSimulatorId, isNot(RiscvConfig.kFormalSimulatorId));
    });

    test('the sby binary defaults to PATH lookup', () {
      expect(const RiscvFormalConfig().effectiveSbyBinary, 'sby');
      expect(
        const RiscvFormalConfig(sbyBinary: '/opt/sby').effectiveSbyBinary,
        '/opt/sby',
      );
    });
  });

  group('copyWith', () {
    const full = RiscvFormalConfig(
      checksDir: 'checks',
      sbyBinary: '/opt/sby',
      command: ['sby', '-f'],
      demoOutputs: 'corpus',
      check: 'insn_add_ch0',
      sbyFile: 'insn_add_ch0.sby',
      task: 't',
      group: 'insn',
    );

    test('replaces only the named field', () {
      // The loader rewrites `demoOutputs` alone when it roots the demo
      // corpus at the project directory; every other field must survive
      // that rewrite untouched.
      final copy = full.copyWith(demoOutputs: '/proj/corpus');
      expect(copy.demoOutputs, '/proj/corpus');
      expect(copy, isNot(full));
      expect(copy.copyWith(demoOutputs: 'corpus'), full);
    });

    test('an omitted field is kept, not nulled', () {
      expect(full.copyWith(), full);
      expect(full.copyWith().hashCode, full.hashCode);
    });

    test('covers every field', () {
      final copy = full.copyWith(
        checksDir: 'c2',
        sbyBinary: 's2',
        command: const ['other'],
        demoOutputs: 'd2',
        check: 'reg_ch0',
        sbyFile: 'reg_ch0.sby',
        task: 't2',
        group: 'reg',
      );
      expect(copy.checksDir, 'c2');
      expect(copy.sbyBinary, 's2');
      expect(copy.command, const ['other']);
      expect(copy.demoOutputs, 'd2');
      expect(copy.check, 'reg_ch0');
      expect(copy.sbyFile, 'reg_ch0.sby');
      expect(copy.task, 't2');
      expect(copy.group, 'reg');
    });
  });
}
