// A register whose RTL gives it an initial value and whose gate-level cell
// has no reset: before the first clock edge the RTL says 0 and the gates say
// x. The one case where the netlist behaves differently from the RTL without
// the testbench noticing.
module rl (
  input  wire clk,
  input  wire d,
  output wire q
);
  reg q_r = 1'b0;
  always @(posedge clk) q_r <= d;
  assign q = q_r;
endmodule
