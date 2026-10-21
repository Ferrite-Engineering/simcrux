// FIFO with properties in the yosys-slang concurrent subset. BUG_FULL lets a write through when full.
// a_dis_ok / a_dis_bad check that `disable iff` is honoured, not dropped.
module fifo_slang #(parameter int W = 8, parameter int D = 4) (
  input  logic         clk,
  input  logic         rst,
  input  logic         wr,
  input  logic [W-1:0] wdata,
  input  logic         rd,
  output logic [W-1:0] rdata,
  output logic         full,
  output logic         empty
);
  logic [W-1:0] mem [D];
  logic [$clog2(D):0] count;
  logic [$clog2(D)-1:0] wp, rp;
`ifdef BUG_FULL
  wire do_wr = wr;
`else
  wire do_wr = wr && !full;
`endif
  wire do_rd = rd && !empty;
  assign full  = (count == D);
  assign empty = (count == 0);
  assign rdata = mem[rp];
  always_ff @(posedge clk) begin
    if (rst) begin
      count <= '0; wp <= '0; rp <= '0;
    end else begin
      if (do_wr) begin mem[wp] <= wdata; wp <= wp + 1'b1; end
      if (do_rd) rp <= rp + 1'b1;
      count <= count + (do_wr ? 1 : 0) - (do_rd ? 1 : 0);
    end
  end

  logic f_init = 1'b1;
  always_ff @(posedge clk) f_init <= 1'b0;
  m_rst:        assume property (@(posedge clk) !f_init || rst);
  a_never_over: assert property (@(posedge clk) disable iff (rst) count <= D);
  a_full_empty: assert property (@(posedge clk) disable iff (rst) !(full && empty));
  a_cnt_up:     assert property (@(posedge clk) disable iff (rst) !($past(wr && !full && !rd) && !$past(rst)) || count == $past(count) + 1);
  a_rose_full:  assert property (@(posedge clk) disable iff (rst) !$rose(full) || $past(wr));
  a_dis_ok:     assert property (@(posedge clk) disable iff (rst) !rst);
`ifdef CHECK_DISABLE
  a_dis_bad:    assert property (@(posedge clk) !rst);
`endif
  c_full:       cover property  (@(posedge clk) disable iff (rst) full);
  c_drain:      cover property  (@(posedge clk) disable iff (rst) $past(full, 4) && empty);
endmodule
