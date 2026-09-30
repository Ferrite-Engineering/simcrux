// -----------------------------------------------------------------------
// Abbreviated stub in the riscv-arch-test house style. Not a runnable
// architectural test — see ../../../../README.md. Nothing in SimCrux parses
// this file; the importer reads only the path and the base name.
// -----------------------------------------------------------------------

#include "model_test.h"
#include "arch_test.h"

RVTEST_ISA("RV32IC")

.section .text.init
.globl rvtest_entry_point
rvtest_entry_point:
RVTEST_CODE_BEGIN

    RVTEST_SIGBASE(x1, signature_x1_1)

    TEST_RR_OP(c.add, x11, x11, x9, 0x00000005, 0x00000002, 0x00000003, x1, 0, x2)

RVTEST_CODE_END
RVTEST_DATA_BEGIN
RVTEST_DATA_END

.section .data
signature_x1_1:
    .fill 8, 4, 0xdeadbeef
