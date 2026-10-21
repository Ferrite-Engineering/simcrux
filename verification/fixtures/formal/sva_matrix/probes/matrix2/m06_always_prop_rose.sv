module m(input logic clk, input logic rst, input logic a, input logic b, input logic c);
 always @(posedge clk) if (!rst) assert property ($rose(a) |-> b);
endmodule
