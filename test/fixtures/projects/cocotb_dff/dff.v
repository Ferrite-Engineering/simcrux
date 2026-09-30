// Minimal D-flip-flop used by the Cocotb fixture testbench. Tiny on
// purpose — the point of the fixture is to exercise the
// SimCrux ↔ Cocotb ↔ underlying-simulator wiring, not to verify DFF
// semantics.
module dff (
    input  wire clk,
    input  wire d,
    output reg  q
);
  always @(posedge clk) q <= d;
endmodule
