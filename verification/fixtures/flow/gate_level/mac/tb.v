`timescale 1ns/1ps
module tb;
  reg clk = 0, rst_n = 0, en = 0;
  reg [7:0] a = 0, b = 0;
  wire [15:0] acc; wire [3:0] cnt; wire parity;
`ifndef PERIOD
  `define PERIOD 20.0
`endif
  dut uut (.clk(clk), .rst_n(rst_n), .en(en), .a(a), .b(b), .acc(acc), .cnt(cnt), .parity(parity));
  always #(`PERIOD/2) clk = ~clk;
  integer i, seed = 1;
  integer f;
  initial begin
`ifdef SDF
    $sdf_annotate(`SDF, uut);
`endif
    f = $fopen(`OUT);
    #(`PERIOD*2.25) rst_n = 1;
    for (i = 0; i < 200; i = i + 1) begin
      @(negedge clk);
      a = $random(seed); b = $random(seed); en = (i % 7) != 3;
`ifdef XPROBE
      if (i < 3) begin a = 8'bx; b = 8'd0; end
`endif
      @(posedge clk); #(`PERIOD*0.45);   // sample late in the cycle, before next negedge
      $fdisplay(f, "%0d acc=%h cnt=%h parity=%b", i, acc, cnt, parity);
    end
    $fclose(f);
    $finish;
  end
endmodule
