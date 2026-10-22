// Port dump added beside the testbench as a second top; the testbench is not edited.
module gls_portdump;
  initial begin
    $dumpfile(`GLS_VCD);
    $dumpvars(0, tb.uut.clk, tb.uut.resetn, tb.uut.trap, tb.uut.mem_valid,
      tb.uut.mem_instr, tb.uut.mem_ready, tb.uut.mem_addr, tb.uut.mem_wdata,
      tb.uut.mem_wstrb, tb.uut.mem_rdata, tb.uut.mem_la_read,
      tb.uut.mem_la_write, tb.uut.mem_la_addr, tb.uut.mem_la_wdata,
      tb.uut.mem_la_wstrb, tb.uut.pcpi_valid, tb.uut.pcpi_insn,
      tb.uut.pcpi_rs1, tb.uut.pcpi_rs2, tb.uut.pcpi_wr, tb.uut.pcpi_rd,
      tb.uut.pcpi_wait, tb.uut.pcpi_ready, tb.uut.irq, tb.uut.eoi,
      tb.uut.trace_valid, tb.uut.trace_data);
  end
endmodule
