// Small sequential design: MAC + counter + a reset-less pipeline register (X-pessimism probe)
module dut (
  input  wire        clk,
  input  wire        rst_n,
  input  wire        en,
  input  wire [7:0]  a,
  input  wire [7:0]  b,
  output reg  [15:0] acc,
  output reg  [3:0]  cnt,
  output wire        parity
);
  reg [7:0] a_q;          // no reset: X until first load
  always @(posedge clk) a_q <= a;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      acc <= 16'd0;
      cnt <= 4'd0;
    end else if (en) begin
      acc <= acc + a_q * b;
      cnt <= cnt + 4'd1;
    end
  end
  assign parity = ^acc;
endmodule
