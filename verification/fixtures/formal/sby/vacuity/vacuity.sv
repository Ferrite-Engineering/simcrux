// Vacuity: an assumption that holds the design in reset, so the check that
// is disabled in reset is never exercised and passes without being checked.
module vacuity (input logic clk, input logic rst);
  logic [3:0] cnt = 4'd0;
  always @(posedge clk) begin
    if (rst) cnt <= 4'd0;
    else cnt <= cnt + 4'd1;
  end
`ifdef SLANG
  m_reset:    assume property (@(posedge clk) rst);
  a_vacuous:  assert property (@(posedge clk) disable iff (rst) cnt != 4'd9);
  a_live:     assert property (@(posedge clk) cnt != 4'd15 || !rst);
`else
  always @(posedge clk) begin
    m_reset: assume (rst);
    if (!rst) begin
      a_vacuous: assert (cnt != 4'd9);
    end
    a_live: assert (cnt != 4'd15 || !rst);
  end
`endif
endmodule
