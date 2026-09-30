// Tiny mixed-language fixture testbench. Drives a stub VHDL companion
// file (compiled by GHDL in a real cocotb mixed-language run) but
// SimCrux's fixture coverage only exercises the
// config-load + simulator-routing path; this Verilog source is here
// to make the source list legitimately mixed-language.
module tb_pass;
  initial begin
    $display("TEST PASSED");
    $finish;
  end
endmodule
