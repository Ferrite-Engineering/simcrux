// Exhaustive gold-versus-gate comparison by simulation: every (op, a, b)
// vector is clocked through the design once, then y and z are printed.
module tb;
  reg clk = 1'b0;
  reg rst = 1'b1;
  reg [1:0] op = 2'd0;
  reg [7:0] a = 8'd0;
  reg [7:0] b = 8'd0;
  wire [7:0] y;
  wire z;
  alu dut(.clk(clk), .rst(rst), .op(op), .a(a), .b(b), .y(y), .z(z));
  integer i;
  integer fd;
  reg [1023:0] out;
  initial begin
    if (!$value$plusargs("out=%s", out)) $finish;
    fd = $fopen(out, "w");
    #1 clk = 1'b1; #1 clk = 1'b0;
    $fdisplay(fd, "R %h %b", y, z);
    rst = 1'b0;
    for (i = 0; i < 262144; i = i + 1) begin
      {op, a, b} = i[17:0];
      #1 clk = 1'b1; #1 clk = 1'b0;
      $fdisplay(fd, "%h %h %b", i[17:0], y, z);
    end
    $fclose(fd);
    $finish;
  end
endmodule
