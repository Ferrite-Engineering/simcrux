// Same handshake, idiomatic open-source formal style: immediate assertions under `ifdef FORMAL.
module handshake_imm (
  input  wire clk,
  input  wire rst,
  input  wire start,
  output reg  req,
  output reg  ack
);
  reg [2:0] cnt;
`ifdef BUG_ACK_LATE
  localparam [2:0] DELAY = 3'd4;
`else
  localparam [2:0] DELAY = 3'd2;
`endif
  always @(posedge clk) begin
    if (rst) begin
      req <= 1'b0; ack <= 1'b0; cnt <= 3'd0;
    end else begin
      ack <= 1'b0;
      if (!req && start) begin
        req <= 1'b1; cnt <= 3'd0;
      end else if (req) begin
        cnt <= cnt + 3'd1;
        if (cnt + 3'd1 == DELAY) begin
          ack <= 1'b1; req <= 1'b0;
        end
      end
    end
  end

`ifdef FORMAL
  reg f_past_valid = 1'b0;
  reg [2:0] f_wait = 3'd0;
  always @(posedge clk) f_past_valid <= 1'b1;
  initial assume (rst);
  always @(posedge clk) begin
    if (rst || ack || !req) f_wait <= 3'd0;
    else f_wait <= f_wait + 3'd1;
  end
  always @(posedge clk) begin
    if (f_past_valid && !$past(rst) && !rst) begin
      if ($past(ack)) assert (!ack);
      if (ack) assert ($past(req));
    end
    if (!rst) assert (f_wait <= 3'd2);
    cover (f_past_valid && !rst && ack);
  end
`endif
endmodule
