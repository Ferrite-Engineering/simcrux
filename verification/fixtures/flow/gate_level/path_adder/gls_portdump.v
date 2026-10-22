// Port dump added beside the testbench as a second top; the testbench is not edited.
module gls_portdump;
  initial begin
    $dumpfile(`GLS_VCD);
    $dumpvars(0, tb.uut.clk, tb.uut.d, tb.uut.q);
  end
endmodule
