# Copyright 2026 Ferrite Engineering LLC
# SPDX-License-Identifier: Apache-2.0

"""Stub Cocotb testbench module for the mixed-language fixture.

Not exercised live in the config-load + routing fixture tests;
it's here so the fixture's source list legitimately includes a Python
testbench alongside its Verilog and VHDL files.
"""

import cocotb  # type: ignore


@cocotb.test()
async def test_mixed(dut):
    """Asserts the design under test exists, prints the pass sentinel."""
    assert dut is not None
    dut._log.info("TEST PASSED")
