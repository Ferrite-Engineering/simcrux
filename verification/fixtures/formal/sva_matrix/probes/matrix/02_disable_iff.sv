module m(input logic clk, input logic rst, input logic a, input logic b, input logic c);
 assert property (@(posedge clk) disable iff (rst) a |-> b);
endmodule
