`timescale 1ns/1ps
// Self-checking: after each clock edge q must equal the d that edge captured.
// It checks nothing before the first edge, so it passes on the RTL and on the
// gates; only the port comparison sees the register's first sample.
module tb;
  reg clk = 0;
  reg d = 0;
  wire q;
  integer i, errors = 0;
  reg expect_q;
  rl uut (.clk(clk), .d(d), .q(q));
  always #10 clk = ~clk;
  initial begin
    for (i = 0; i < 8; i = i + 1) begin
      @(negedge clk);
      d = i[0];
      expect_q = i[0];
      @(posedge clk);
      #5;
      if (q !== expect_q) begin
        errors = errors + 1;
        $display("ERROR: cycle %0d q=%b expected %b", i, q, expect_q);
      end
    end
    if (errors == 0) $display("PASS");
    $finish;
  end
endmodule
