// iCE40 src-attribute gate: a registered MAC-ish datapath with a long carry path.
module top (
  input  wire       clk,
  input  wire       rst,
  input  wire [1:0] op,
  input  wire [7:0] a,
  input  wire [7:0] b,
  output reg  [15:0] acc,
  output reg        z
);
  reg [7:0] ra, rb;
  reg [15:0] prod;
  always @(posedge clk) begin
    ra <= a;
    rb <= b;
    prod <= (op[0] ? ra * rb : {8'd0, ra ^ rb});       // line 16: multiplier path
    if (rst) begin acc <= 16'd0; z <= 1'b1; end
    else begin
      acc <= op[1] ? acc + prod : acc - prod;         // line 19: 16-bit add/sub
      z   <= (acc == 16'd0);
    end
  end
endmodule
