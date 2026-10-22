// Hand-written structural netlist of rl.v on sky130_fd_sc_hd: one flip-flop
// without a reset, as synthesis would write it.
module rl (clk,
    d,
    q);
 input clk;
 input d;
 output q;

 sky130_fd_sc_hd__dfxtp_1 _0_ (.CLK(clk),
    .D(d),
    .Q(q));
endmodule
