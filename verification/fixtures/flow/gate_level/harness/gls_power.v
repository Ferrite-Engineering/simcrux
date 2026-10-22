// Ties the power-aware netlist's supply ports from outside; neither the
// testbench nor the netlist is edited. A second top, like the port dump.
module gls_power;
  initial begin
    force tb.uut.VPWR = 1'b1;
    force tb.uut.VGND = 1'b0;
  end
endmodule
