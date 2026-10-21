module m(input logic clk, input logic rst, input logic a, input logic b, input logic c);
 assume property (@(posedge clk) !(a && c));
endmodule
