module m(input logic clk, input logic rst, input logic a, input logic b, input logic c);
 property p; @(posedge clk) a |-> b; endproperty
 a_p: assert property (p);
endmodule
