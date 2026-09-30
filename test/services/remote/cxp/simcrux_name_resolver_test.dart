// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_cxp/crux_cxp.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/services/remote/cxp/simcrux_name_resolver.dart';

void main() {
  group('SimCruxNameResolver — toCanonical / toLocal round-trips', () {
    const resolver = SimCruxNameResolver();

    for (final kind in ElementKind.values) {
      test('round-trips ${kind.name}', () {
        final id = resolver.toCanonical(
          kind: kind,
          local: 'top.cpu.alu/test_alu_basic',
        );
        expect(id, isNotNull);
        expect(id!.kind, kind);
        expect(id.path, 'top.cpu.alu/test_alu_basic');
        expect(resolver.toLocal(id), 'top.cpu.alu/test_alu_basic');
      });
    }
  });

  group('SimCruxNameResolver — test ids', () {
    const resolver = SimCruxNameResolver();

    test('canonicalises a simple suite/name id', () {
      final id = resolver.toCanonical(
        kind: ElementKind.test,
        local: 'cpu_unit/test_alu_basic',
      );
      expect(id, isNotNull);
      expect(id!.path, 'cpu_unit/test_alu_basic');
    });

    test('preserves parameter and seed suffixes', () {
      final id = resolver.toCanonical(
        kind: ElementKind.test,
        local: 'cpu_unit/test_random+seed=42+MEM_SIZE=4096',
      );
      expect(id, isNotNull);
      expect(id!.path, 'cpu_unit/test_random+seed=42+MEM_SIZE=4096');
    });

    test('test ids with slashes in suite names round-trip', () {
      // SimCrux suites typically do not contain slashes but the resolver
      // is opaque — the canonical id is whatever the producer supplied.
      final id = resolver.toCanonical(
        kind: ElementKind.test,
        local: 'verif/cpu/alu/test_x',
      );
      expect(id, isNotNull);
      expect(resolver.toLocal(id!), 'verif/cpu/alu/test_x');
    });
  });

  group('SimCruxNameResolver — breakpoints', () {
    const resolver = SimCruxNameResolver();

    test('canonicalises a file:line breakpoint', () {
      final id = resolver.toCanonical(
        kind: ElementKind.breakpoint,
        local: '/abs/path/tb_alu.v:42',
      );
      expect(id, isNotNull);
      expect(id!.kind, ElementKind.breakpoint);
      expect(id.path, '/abs/path/tb_alu.v:42');
    });

    test('canonicalises file:line:col with optional condition', () {
      // Breakpoints carry an opaque path; SimCrux's future breakpoint
      // editor decides the suffix grammar. The resolver is happy with
      // any non-empty string.
      final id = resolver.toCanonical(
        kind: ElementKind.breakpoint,
        local: '/abs/tb_alu.v:42:6?cond=err==1',
      );
      expect(id, isNotNull);
      expect(resolver.toLocal(id!), '/abs/tb_alu.v:42:6?cond=err==1');
    });
  });

  group('SimCruxNameResolver — source / waveform paths', () {
    const resolver = SimCruxNameResolver();

    test('canonicalises an absolute source path', () {
      final id = resolver.toCanonical(
        kind: ElementKind.source,
        local: '/abs/rtl/alu.sv',
      );
      expect(id, isNotNull);
      expect(id!.path, '/abs/rtl/alu.sv');
    });

    test('canonicalises a workspace-relative source path', () {
      final id = resolver.toCanonical(
        kind: ElementKind.source,
        local: 'rtl/alu.sv',
      );
      expect(id, isNotNull);
      expect(id!.path, 'rtl/alu.sv');
    });

    test('canonicalises a source path with line suffix', () {
      final id = resolver.toCanonical(
        kind: ElementKind.source,
        local: '/abs/rtl/alu.sv:120',
      );
      expect(id, isNotNull);
      expect(id!.path, '/abs/rtl/alu.sv:120');
    });

    test('canonicalises a waveform file path as ElementKind.source', () {
      // Waveform files ride v1 ElementKind.source per the resolver
      // contract; receivers disambiguate via file extension.
      final id = resolver.toCanonical(
        kind: ElementKind.source,
        local: '/abs/run/dump.vcd',
      );
      expect(id, isNotNull);
      expect(id!.kind, ElementKind.source);
      expect(SimCruxNameResolver.looksLikeWaveformPath(id.path), isTrue);
    });
  });

  group('SimCruxNameResolver — looksLikeWaveformPath', () {
    test('detects .vcd / .fst / .ghw / .wavecrux extensions', () {
      expect(
        SimCruxNameResolver.looksLikeWaveformPath('/x/y.vcd'),
        isTrue,
      );
      expect(
        SimCruxNameResolver.looksLikeWaveformPath('/x/y.fst'),
        isTrue,
      );
      expect(
        SimCruxNameResolver.looksLikeWaveformPath('/x/y.ghw'),
        isTrue,
      );
      expect(
        SimCruxNameResolver.looksLikeWaveformPath('/x/y.wavecrux'),
        isTrue,
      );
    });

    test('detects extensions case-insensitively', () {
      expect(
        SimCruxNameResolver.looksLikeWaveformPath('/x/y.VCD'),
        isTrue,
      );
      expect(
        SimCruxNameResolver.looksLikeWaveformPath('/x/y.Fst'),
        isTrue,
      );
    });

    test('rejects source files and unknown extensions', () {
      expect(
        SimCruxNameResolver.looksLikeWaveformPath('/x/y.sv'),
        isFalse,
      );
      expect(
        SimCruxNameResolver.looksLikeWaveformPath('/x/y.v'),
        isFalse,
      );
      expect(
        SimCruxNameResolver.looksLikeWaveformPath('/x/y.txt'),
        isFalse,
      );
      expect(
        SimCruxNameResolver.looksLikeWaveformPath(''),
        isFalse,
      );
    });
  });

  group('SimCruxNameResolver — edge cases', () {
    const resolver = SimCruxNameResolver();

    test('empty local string returns null', () {
      expect(
        resolver.toCanonical(kind: ElementKind.test, local: ''),
        isNull,
      );
    });

    test('empty path on ElementId returns null', () {
      expect(
        resolver.toLocal(
          const ElementId(kind: ElementKind.source, path: ''),
        ),
        isNull,
      );
    });

    test('paths containing whitespace, dots, and special chars survive', () {
      final id = resolver.toCanonical(
        kind: ElementKind.test,
        local: 'suite with spaces/test.with.dots+seed=1',
      );
      expect(id, isNotNull);
      expect(id!.path, 'suite with spaces/test.with.dots+seed=1');
    });

    test('whitespace-only local string is treated as a valid path', () {
      // We intentionally pass through whitespace-only ids because the
      // canonical form is opaque; SimCrux producers are responsible
      // for not generating such ids.
      final id = resolver.toCanonical(
        kind: ElementKind.source,
        local: '  ',
      );
      expect(id, isNotNull);
      expect(id!.path, '  ');
    });

    test('unknown ElementKind declines instead of throwing', () {
      // Open wire type — a peer on a later protocol revision may send a
      // kind this build does not model. The resolver has no local
      // vocabulary for it, so it returns null rather than crashing.
      final kind = ElementKind('assertion_coverpoint');
      expect(kind.known, isNull);
      expect(resolver.toCanonical(kind: kind, local: 'top.a'), isNull);
      expect(resolver.toLocal(ElementId(kind: kind, path: 'top.a')), isNull);
    });
  });
}
