// The same netlist with its output port renamed: plain identifiers, so the
// port list is usable, but the testbench connects .q(q) and the dump names
// uut.qq, so neither simulator run can bind it.
module rl (clk,
    d,
    qq);
 input clk;
 input d;
 output qq;

 sky130_fd_sc_hd__dfxtp_1 _0_ (.CLK(clk),
    .D(d),
    .Q(qq));
endmodule
