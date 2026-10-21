module m(input logic clk, input logic rst, input logic a, input logic b, input logic c);
 assert property (@(posedge clk) (a ##1 b) and (c ##1 b) |-> c);
endmodule
