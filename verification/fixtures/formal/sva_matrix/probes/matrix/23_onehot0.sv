module m(input logic clk, input logic rst, input logic a, input logic b, input logic c);
 assert property (@(posedge clk) $onehot0({a,b,c}));
endmodule
