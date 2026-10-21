// Small registered ALU used for the EQY gold-vs-gate measurement.
module alu (
  input  wire       clk,
  input  wire       rst,
  input  wire [1:0] op,
  input  wire [7:0] a,
  input  wire [7:0] b,
  output reg  [7:0] y,
  output reg        z
);
  reg [7:0] r;
  always @* begin
    case (op)
      2'd0: r = a + b;
      2'd1: r = a - b;
      2'd2: r = a & b;
      default: r = a ^ b;
    endcase
  end
  always @(posedge clk) begin
    if (rst) begin y <= 8'd0; z <= 1'b1; end
    else begin y <= r; z <= (r == 8'd0); end
  end
endmodule
