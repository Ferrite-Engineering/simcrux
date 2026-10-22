// Self-checking testbench for path_adder.
//
// The design has no reset: src_a, src_b and sum_q start unknown, src_a
// fills from d within 24 clocks, and src_b feeds back on itself
// (src_b[0] <= d ^ src_b[23]), so in a four-state simulator src_b, sum_q
// and q stay x for ever, while a two-state simulator starts every register
// at zero. The reference model below restates the RTL's meaning with the
// same uninitialised registers, so it carries the same start state as the
// simulator it runs in, and the check uses !== (an x expectation needs an x
// result). d comes from a 16-bit maximal-length LFSR (x^16 + x^14 + x^13 +
// x^11 + 1), the same sequence in every simulator.
`timescale 1ns/1ps
module tb;
  reg clk = 1'b0;
  reg d = 1'b0;
  wire q;

  path_adder uut (.clk(clk), .d(d), .q(q));

  always #5 clk = ~clk;  // 10 ns, the run's CLOCK_PERIOD

  reg [15:0] lfsr = 16'hace1;
  reg [23:0] m_a;
  reg [23:0] m_b;
  reg [24:0] m_sum;
  integer i;
  integer errors = 0;
  integer known = 0;

  always @(posedge clk) begin
    m_a <= {m_a[22:0], d};
    m_b <= {m_b[22:0], d ^ m_b[23]};
    m_sum <= m_a + m_b;
  end

  initial begin
    for (i = 0; i < 200; i = i + 1) begin
      @(negedge clk);
      d <= lfsr[0];
      lfsr <= {lfsr[0] ^ lfsr[2] ^ lfsr[3] ^ lfsr[5], lfsr[15:1]};
      @(posedge clk);
      #4;  // late in the cycle, before the next negedge
      if (q !== ^m_sum) begin
        errors = errors + 1;
        $display("MISMATCH cycle %0d: q=%b expected %b", i, q, ^m_sum);
      end
      if (^m_sum !== 1'bx) known = known + 1;
    end
    $display("cycles=200 known_expectations=%0d errors=%0d", known, errors);
    if (errors == 0) begin
      $display("TEST PASSED");
      $finish;
    end else begin
      $display("TEST FAILED");
      $fatal(1);
    end
  end
endmodule
