module m(input logic clk, input logic rst, input logic a, input logic b, input logic c);
 sequence s; a ##1 b; endsequence
 a_s: assert property (@(posedge clk) s |-> c);
endmodule
