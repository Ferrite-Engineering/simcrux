// req/ack handshake with concurrent SVA. BUG_ACK_LATE makes ack arrive 4 cycles after req.
module handshake (
  input  logic clk,
  input  logic rst,
  input  logic start,
  output logic req,
  output logic ack
);
  logic [2:0] cnt;
`ifdef BUG_ACK_LATE
  localparam logic [2:0] DELAY = 3'd4;
`else
  localparam logic [2:0] DELAY = 3'd2;
`endif

  always_ff @(posedge clk) begin
    if (rst) begin
      req <= 1'b0; ack <= 1'b0; cnt <= '0;
    end else begin
      ack <= 1'b0;
      if (!req && start) begin
        req <= 1'b1; cnt <= '0;
      end else if (req) begin
        cnt <= cnt + 3'd1;
        if (cnt + 3'd1 == DELAY) begin
          ack <= 1'b1; req <= 1'b0;
        end
      end
    end
  end

  // ---- concurrent SVA ----
  sequence s_req_rise;
    $rose(req);
  endsequence

  // bounded response
  a_resp: assert property (@(posedge clk) disable iff (rst) s_req_rise |-> ##[1:3] ack);
  // ack is a one-cycle pulse
  a_pulse: assert property (@(posedge clk) disable iff (rst) ack |=> !ack);
  // req holds until ack
  a_hold: assert property (@(posedge clk) disable iff (rst) (req && !ack) |=> (req || ack));
  // $past / $stable
  a_past: assert property (@(posedge clk) disable iff (rst) ack |-> $past(req));
  a_stable: assert property (@(posedge clk) disable iff (rst) (req && $past(req) && !ack) |-> $stable(req));
  // liveness
  a_live: assert property (@(posedge clk) disable iff (rst) req |-> s_eventually ack);
  // environment
  m_rst: assume property (@(posedge clk) $initstate |-> rst);
  // covers
  c_ack: cover property (@(posedge clk) disable iff (rst) s_req_rise ##[1:3] ack);
  c_b2b: cover property (@(posedge clk) disable iff (rst) ack ##1 $rose(req));
endmodule
