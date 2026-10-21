module m(input logic clk, input logic rst, input logic a, input logic b, input logic c);
 cover property (@(posedge clk) a && b);
endmodule
