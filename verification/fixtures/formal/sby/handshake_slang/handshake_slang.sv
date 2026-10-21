// Handshake rewritten into the concurrent subset yosys-slang accepts (Oct 2026):
// clocked, disable iff, boolean bodies with $past/$rose/$stable; no |->, ##, sequences.
module handshake_slang (
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

  // auxiliary wait counter replaces ##[1:3]
  logic [2:0] f_wait;
  always_ff @(posedge clk)
    if (rst || !req) f_wait <= '0; else f_wait <= f_wait + 3'd1;

  // slang rejects `initial assume` and $initstate; an initialised flag stands in
  logic f_init = 1'b1;
  always_ff @(posedge clk) f_init <= 1'b0;
  m_rst:    assume property (@(posedge clk) !f_init || rst);

  a_resp:   assert property (@(posedge clk) disable iff (rst) f_wait <= 3'd2);
  a_pulse:  assert property (@(posedge clk) disable iff (rst) !($past(ack) && ack));
  a_past:   assert property (@(posedge clk) disable iff (rst) !ack || $past(req));
  a_rose:   assert property (@(posedge clk) disable iff (rst) !$rose(ack) || $fell(req));
  a_stable: assert property (@(posedge clk) disable iff (rst) !(req && $past(req) && !ack) || $stable(req));
  c_ack:    cover property  (@(posedge clk) disable iff (rst) ack && $past(req));
  c_b2b:    cover property  (@(posedge clk) disable iff (rst) $past(ack) && $rose(req));
endmodule
