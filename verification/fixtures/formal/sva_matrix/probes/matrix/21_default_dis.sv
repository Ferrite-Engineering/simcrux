module m(input logic clk, input logic rst, input logic a, input logic b, input logic c);
 default clocking cb @(posedge clk); endclocking
 default disable iff (rst);
 assert property (a |-> ##1 b);
endmodule
