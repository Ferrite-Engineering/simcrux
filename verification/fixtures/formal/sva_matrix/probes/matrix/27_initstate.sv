module m(input logic clk, input logic rst, input logic a, input logic b, input logic c);
 always @(*) if ($initstate) assume (rst);
endmodule
