// The pre-trace $past trap, on both open frontends. cnt counts 0, 1, 2, ...
// (mod 8) from its initial value and top is cnt == 7, so on a real trace
// $past(top, 3) is 1 exactly when cnt is 2 (mod 8), first at step 10. Before
// step 3 the three $past registers still hold state from before the trace
// began, which nothing constrains.
module pretrace (input logic clk);
  logic [2:0] cnt = 3'd0;
  logic [1:0] f_age = 2'd0;
  always @(posedge clk) begin
    cnt <= cnt + 3'd1;
    if (f_age != 2'd3) f_age <= f_age + 2'd1;
  end
  wire top = (cnt == 3'd7);
`ifdef SLANG
  c_footgun:   cover property (@(posedge clk) $past(top, 3) && cnt == 3'd1);
  c_unguarded: cover property (@(posedge clk) $past(top, 3) && cnt == 3'd2);
  c_guarded:   cover property (@(posedge clk) f_age == 2'd3 && $past(top, 3) && cnt == 3'd2);
`ifdef WITH_ASSERT
  a_footgun:   assert property (@(posedge clk) !($past(top, 3) && cnt == 3'd1));
`endif
`else
  always @(posedge clk) begin
    c_footgun: cover ($past(top, 3) && cnt == 3'd1);
    c_unguarded: cover ($past(top, 3) && cnt == 3'd2);
    c_guarded: cover (f_age == 2'd3 && $past(top, 3) && cnt == 3'd2);
  end
`endif
endmodule
