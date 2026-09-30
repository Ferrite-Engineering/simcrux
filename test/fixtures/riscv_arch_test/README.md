# `riscv-arch-test` importer fixture

A **miniature** checkout of the [`riscv-arch-test`][suite] repository, laid
out exactly the way the real one is:

```text
riscv-test-suite/<arch>/<EXT>/src/<name>.S
```

Four tests across three extension directories (`I`, `M`, `C`) under one
`rv32i_m/` arch directory. That is enough to exercise everything
`RiscvArchTestImporter.importSuite` does — the `riscv-test-suite/`
subdirectory detection, the depth-limited `src/` walk, the
`p.basename(p.dirname(srcDir))` extension tag, the `--extensions` filter,
per-extension suite emission, and the deterministic sort — without
vendoring the upstream repository.

## Why not the real checkout

`riscv-arch-test` is thousands of files and tens of megabytes, most of it
`.reference_output` signature data this importer never reads. The importer
only ever looks at the *directory layout* and the `.S` filenames; it never
opens a test source. So a fixture that reproduces the layout tests exactly
what the real checkout would, and a vendored copy would only make the repo
bigger and the licence story more complicated.

The `.S` bodies below are therefore **abbreviated stubs** in the upstream
house style, not runnable architectural tests. They exist so the files are
non-empty and recognizably RISC-V assembly; nothing in SimCrux parses them.

## Deliberate contents

- `I/src/add-01.S`, `I/src/addi-01.S` — two tests in one extension, so the
  emitted `I` suite has more than one entry and the name sort is
  observable.
- `M/src/mul-01.S`, `C/src/cadd-01.S` — two more extensions, so the
  `--extensions` filter has something to exclude and the per-extension
  rollup has more than one group.
- No `.reference_output`, `.elf` or `Makefrag` files: the importer must not
  need them, and their absence is part of the assertion.

[suite]: https://github.com/riscv-non-isa/riscv-arch-test
