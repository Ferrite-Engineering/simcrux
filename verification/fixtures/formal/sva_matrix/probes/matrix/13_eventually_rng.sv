module m(input logic clk, input logic rst, input logic a, input logic b, input logic c);
 assert property (@(posedge clk) a |-> eventually [1:4] b);
endmodule
