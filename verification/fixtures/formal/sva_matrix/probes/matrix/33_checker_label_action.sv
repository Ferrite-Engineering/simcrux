module m(input logic clk, input logic rst, input logic a, input logic b, input logic c);
 a_lbl: assert property (@(posedge clk) a |-> b) else $error("boom");
endmodule
